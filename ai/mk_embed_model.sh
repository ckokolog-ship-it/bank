#!/bin/bash
# mk_embed_model.sh -- the model of embeddings for the search by meaning (db/BK_VECTOR.sql): downloads
# intfloat/multilingual-e5-small from Hugging Face and makes ai/models/bk_embed.onnx (build_embed.py: its tokenizer
# in it, as Oracle wants it), in a venv of its own (ai/.venv: onnx, onnxruntime, onnxruntime-extensions, tokenizers).
# As oracle, once; about 1 GB of downloads, a few minutes. Then, once, as SYSTEM: db/GRANT_AI.sql (the directory
# BK_MODELS: this ai/models); then INSTALL.sql (or LOAD_EMBED.sql) loads it.
#
#   ./mk_embed_model.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
py=${PYTHON:-python3}
"$py" -c 'import sys; assert sys.version_info >= (3, 9), "Python 3.9 or newer"'
if [ ! -x "$here/.venv/bin/python" ]; then
  echo "== a venv: $here/.venv"
  "$py" -m venv "$here/.venv"
fi
"$here/.venv/bin/pip" -q install --upgrade pip
"$here/.venv/bin/pip" -q install numpy onnx onnxruntime onnxruntime-extensions tokenizers
"$here/.venv/bin/python" -I "$here/build_embed.py" "$here/models"
chmod -R a+rX "$here/models"
echo "== the database reads it from the directory BK_MODELS: once as SYSTEM db/GRANT_AI.sql $here/models"
