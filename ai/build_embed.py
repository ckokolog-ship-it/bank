#!/usr/bin/env python3
"""build_embed.py -- the model of embeddings of the bank (BK_EMBED, db/BK_VECTOR.sql) as one ONNX file that Oracle
loads (DBMS_VECTOR.LOAD_ONNX_MODEL): intfloat/multilingual-e5-small (Hugging Face, MIT licence; Greek among its
languages), with its tokenizer in it, so the database gets a text and gives a vector:

    input "input" (one text) -> SentencepieceTokenizer (onnxruntime-extensions: the op Oracle runs) -> <s> the
    tokens (at most 127) </s> -> the model -> the mean of its tokens -> L2 -> output "embedding" (384 floats)

The e5 model wants "query: " before a question, "passage: " before a text searched: bk_vec puts them.

    python3 build_embed.py OUT_DIR       (writes OUT_DIR/bk_embed.onnx; checks it against the model as it is)

ai/mk_embed_model.sh runs it in a venv of its own. The files of the model are downloaded, never in the repo.
"""
import os
import sys
import urllib.request

import numpy as np
import onnx
from onnx import TensorProto as T
from onnx import helper as H
from onnx import numpy_helper as N

REPO = 'https://huggingface.co/intfloat/multilingual-e5-small/resolve/main/'
FILES = {'model.onnx': 'onnx/model.onnx', 'sentencepiece.bpe.model': 'onnx/sentencepiece.bpe.model',
         'tokenizer.json': 'tokenizer.json'}
MAXLEN = 128
DIMS = 384


def download(dst):
    os.makedirs(dst, exist_ok=True)
    for name, path in FILES.items():
        f = os.path.join(dst, name)
        if not os.path.exists(f):
            print('== download', path, flush=True)
            urllib.request.urlretrieve(REPO + path, f + '.part')
            os.replace(f + '.part', f)


def build(src, spm, out):
    m = onnx.load(src)
    g = m.graph
    cst = lambda name, arr: N.from_array(np.array(arr), name)  # noqa: E731
    inits = [cst('sp_nbest', np.array(0, np.int64)), cst('sp_alpha', np.array(0.0, np.float32)),
             cst('sp_bos', np.array(True)), cst('sp_eos', np.array(False)), cst('sp_rev', np.array(False)),
             cst('sp_fairseq', np.array(True)), cst('ax0', np.array([0], np.int64)),
             cst('s0', np.array([0], np.int64)), cst('smax1', np.array([MAXLEN - 1], np.int64)),
             cst('eos_id', np.array([2], np.int64))]
    nodes = [
        # (fairseq: the ids of XLM-RoBERTa, as the model has them)
        H.make_node('SentencepieceTokenizer', ['input', 'sp_nbest', 'sp_alpha', 'sp_bos', 'sp_eos', 'sp_rev', 'sp_fairseq'],
                    ['tok32', 'tok_idx'], domain='ai.onnx.contrib', model=open(spm, 'rb').read()),
        H.make_node('Cast', ['tok32'], ['tok64'], to=T.INT64),
        # (the ops of opset 11, as the model has them) <s> and the words, at most MAXLEN - 1; then </s>
        H.make_node('Slice', ['tok64', 's0', 'smax1', 'ax0'], ['tok_cut']),
        H.make_node('Concat', ['tok_cut', 'eos_id'], ['tok_all'], axis=0),
        H.make_node('Unsqueeze', ['tok_all'], ['input_ids'], axes=[0]),
        H.make_node('Shape', ['input_ids'], ['ids_shape']),
        H.make_node('ConstantOfShape', ['ids_shape'], ['attention_mask'], value=H.make_tensor('one', T.INT64, [1], [1])),
        H.make_node('ConstantOfShape', ['ids_shape'], ['token_type_ids'], value=H.make_tensor('zero', T.INT64, [1], [0]))]
    if 'token_type_ids' not in {i.name for i in g.input}:
        nodes = nodes[:-1]
    nodes += list(g.node)
    # the mean of the tokens (one text: all of them), L2 (the cosine of two: their dot product); one dimension: Oracle
    # wants the embedding so
    nodes += [H.make_node('ReduceMean', ['last_hidden_state'], ['pooled'], axes=[1], keepdims=0),
              H.make_node('LpNormalization', ['pooled'], ['pooled_n'], axis=1, p=2),
              H.make_node('Squeeze', ['pooled_n'], ['embedding'], axes=[0])]
    graph = H.make_graph(nodes, 'bk_embed', [H.make_tensor_value_info('input', T.STRING, [1])],
                         [H.make_tensor_value_info('embedding', T.FLOAT, [DIMS])],
                         initializer=list(g.initializer) + inits)
    opset = max(o.version for o in m.opset_import if o.domain in ('', 'ai.onnx'))
    model = H.make_model(graph, opset_imports=[H.make_opsetid('', opset), H.make_opsetid('ai.onnx.contrib', 1)])
    model.ir_version = m.ir_version
    onnx.save(model, out)


def check(dl, out):
    """the same vector as the model as it is, with its own tokenizer (tokenizer.json)"""
    import onnxruntime as ort
    from onnxruntime_extensions import get_library_path
    from tokenizers import Tokenizer
    tok = Tokenizer.from_file(os.path.join(dl, 'tokenizer.json'))
    ref = ort.InferenceSession(os.path.join(dl, 'model.onnx'))
    so = ort.SessionOptions()
    so.register_custom_ops_library(get_library_path())
    mine = ort.InferenceSession(out, so)
    names = [i.name for i in ref.get_inputs()]
    for s in ('query: φαγητό έξω', 'passage: Ταβέρνα Ο Μπάμπης', 'passage: SHELL πρατήριο Ρίου', 'query: fuel'):
        ids = tok.encode(s).ids
        f = {'input_ids': np.array([ids]), 'attention_mask': np.ones((1, len(ids)), np.int64)}
        if 'token_type_ids' in names:
            f['token_type_ids'] = np.zeros((1, len(ids)), np.int64)
        h = ref.run(None, f)[0][0].mean(0)
        h = h / np.linalg.norm(h)
        e = mine.run(None, {'input': np.array([s])})[0]
        assert e.shape == (DIMS,) and float(h @ e) > 0.9999, (s, float(h @ e))
    print('== checked: the same vectors as the model itself')


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'models')
    dl = os.path.join(out_dir, 'download')
    download(dl)
    out = os.path.join(out_dir, 'bk_embed.onnx')
    build(os.path.join(dl, 'model.onnx'), os.path.join(dl, 'sentencepiece.bpe.model'), out + '.part')
    check(dl, out + '.part')
    os.replace(out + '.part', out)
    print('== %s (%d MB)' % (out, os.path.getsize(out) // 2 ** 20))


if __name__ == '__main__':
    main()
