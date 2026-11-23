"""test_rag.py -- the assistant of the teller (db/BK_RAG.sql: RAG in the database): its knowledge (the facts of the
bank as they are now: the products, their rates as ranges, the rules; the guides of BK_DOCS in pieces), a question:
its pieces nearest in meaning, the rate of each product for an amount worked out by the database first, the answer of
the language model when there is one (Ollama: AI_LLM_URL), else its error and the pieces all the same. Needs the model
BK_EMBED (ai/mk_embed_model.sh, db/LOAD_EMBED.sql), else skipped.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests/test_rag.py
"""
import os

import oracledb
import pytest

from test_core import DSN, db  # noqa: F401  (db: the fixture)

pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set')
oracledb.defaults.fetch_lobs = False


@pytest.fixture(scope='module')
def rag(db):
    if db.one('select bk_vec.ready from dual')[0] != 'Y':
        pytest.skip('no model BK_EMBED: ai/mk_embed_model.sh, db/LOAD_EMBED.sql')
    old = db.one("select max(value) from bk_setting where name = 'AI_LLM_URL'")[0]
    assert db.cur.callfunc('bk_rag.refresh', int) > 10
    yield db
    set_url(db, old)


def set_url(db, v):
    db.cur.execute("delete from bk_setting where name = 'AI_LLM_URL'")
    if v is not None:
        db.cur.execute("insert into bk_setting (name, value) values ('AI_LLM_URL', :v)", v=v)
    db.conn.commit()


def ask(db, q):
    i = db.cur.callfunc('bk_rag.ask', int, [q])
    a = db.one('select answer, error, model, ms, asked_by from bk_ai_question where id = :i', i=i)
    db.cur.execute('select n, source, title, text, similarity from bk_ai_question_src where question_id = :i order by n', i=i)
    return a, db.cur.fetchall()


def test_the_knowledge(rag):
    db = rag
    # a rule of a product (BUS: no other test opens it): the knowledge again has it, in a sentence
    db.cur.callfunc('bk_core.set_rule', int, ['BUS', None, 'WDR', 'ATM'],
                    {'p_min_amount': 20, 'p_max_amount': 500, 'p_day_amount': 800, 'p_fee': 0.5, 'p_free_month': 4})
    db.conn.commit()
    db.cur.callfunc('bk_rag.refresh', int)
    facts = dict(db.cur.execute("select title, text from bk_ai_doc where source like 'DB:%'").fetchall())
    assert facts['Κανόνας BUS WDR ATM'] == ('Κανόνας για το προϊόν BUS: ανάληψη από ATM: ελάχιστο ποσό 20,00 €, μέγιστο ποσό '
                                            '500,00 € τη φορά, έως 800,00 € την ημέρα, προμήθεια 0,50 € μετά τις 4 δωρεάν τον μήνα.')
    # the rates as ranges
    sav = facts['Προϊόν SAV Ταμιευτήριο']
    assert 'σε EUR για υπόλοιπο από 5.000,00 έως 19.999,99' in sav and 'φόρο τόκων 15%' in sav
    assert 'Σταθερό επιτόκιο 9,5%' in facts['Προϊόν CONS Καταναλωτικό δάνειο (σταθερό)']
    assert 'EURIBOR3M + ' in facts['Προϊόν HOME Στεγαστικό δάνειο (κυμαινόμενο)']
    assert db.one("select count(*) from bk_ai_doc where vec is null")[0] == 0


def test_a_question_without_a_language_model(rag):
    """no LLM (a port nobody listens to): the error kept, the pieces all the same; the rate for an amount worked out"""
    db = rag
    set_url(db, 'http://127.0.0.1:9/api/generate')
    (answer, error, model, ms, who), src = ask(db, 'Τι επιτόκιο έχει το ταμιευτήριο για 12.000 ευρώ;')
    assert answer is None and error and ms >= 0
    # (the rate of SAV for 12.000 €: its step from 5.000 as the database has it)
    want = db.one("select to_char(max(rate) keep (dense_rank last order by valid_from), 'FM990D9999', "
                  "'NLS_NUMERIC_CHARACTERS='',.''') from bk_rate r, bk_product p where p.id = r.product_id and p.code = 'SAV' "
                  "and r.currency = 'EUR' and r.min_balance = 5000")[0].rstrip('0').rstrip(',')
    assert src[0][1] == 'DB:calc' and 'για υπόλοιπο 12.000,00 EUR' in src[0][3]
    assert 'SAV «Ταμιευτήριο»: %s%%' % want in src[0][3] and 'SAVP «Ταμιευτήριο Plus»: 1%' in src[0][3]
    assert any(s[2] == 'Προϊόν SAV Ταμιευτήριο' for s in src) and len(src) == 5
    (_, _, _, _, _), src = ask(db, 'Πόσα μπορεί να σηκώσει ένας πελάτης από ATM την ημέρα;')
    assert src[0][1] != 'DB:calc' and len(src) == 4 and any('ATM' in (s[2] + s[3]) for s in src)
    with pytest.raises(oracledb.DatabaseError, match='BK-176'):
        ask(db, '   ')


def test_a_question_with_the_language_model(rag):
    """the LLM of this server (BANK_LLM_URL, else localhost:11434), if it answers (else skipped): the answer from the pieces, with their numbers"""
    db = rag
    set_url(db, os.environ.get('BANK_LLM_URL', 'http://localhost:11434/api/generate'))
    # (the rule of BUS of test_the_knowledge: with the demo or without it)
    (answer, error, model, ms, who), src = ask(db, 'Πόσα μπορεί να σηκώσει την ημέρα από ATM ένας πελάτης με λογαριασμό BUS;')
    if answer is None:
        pytest.skip('no language model: ' + (error or '')[:100])
    assert '800' in answer and '[' in answer, answer
