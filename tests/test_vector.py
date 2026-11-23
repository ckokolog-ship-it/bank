"""test_vector.py -- the search by meaning (db/BK_VECTOR.sql, AI Vector Search): the text of a movement as it is
searched, its vector and its category; a question finds the movements of the same meaning with no word in common
("φαγητό έξω": a grill house, not a petrol station), of an account; the category of a question and all its
movements; what an account spent by category; the close of a day gives the new movements their text. Needs the
model BK_EMBED in the database (ai/mk_embed_model.sh, db/LOAD_EMBED.sql), else skipped.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests/test_vector.py
"""
import pytest

from test_core import DSN, close_days, customer, db  # noqa: F401  (db: the fixture)

pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set')


@pytest.fixture(scope='module')
def vec(db):
    if db.one('select bk_vec.ready from dual')[0] != 'Y':
        pytest.skip('no model BK_EMBED: ai/mk_embed_model.sh, db/LOAD_EMBED.sql')
    return db


def acct(db, money):
    a = db.fn('open_account', int, 'CUR', customer(db), 0)
    for op in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC'):
        db.cur.callfunc('bk_core.set_rule', int, [None, a, op, '*'], {'p_allowed': 'Y', 'p_fee': 0})
    db.fn('deposit', int, a, money)
    db.conn.commit()
    return a


def pay(db, a, amount, text):
    return db.fn('transfer_out', int, a, amount, 'GR9608100010000001234567890', text, None, 'WEB')


def texts(db, q, a=None, cat=None):
    db.cur.execute('select descr, similarity, category from table(bk_vec.search(:q, :a, 500, :c))', q=q, a=a, c=cat)
    return db.cur.fetchall()


def test_the_text_of_a_movement(vec):
    db = vec
    for descr, kind, want in (('Αγορά: Ταβέρνα Ο Μπάμπης', 'PUR', 'Ταβέρνα Ο Μπάμπης'),
                              ('Πληρωμή με κάρτα: SHELL πρατήριο Ρίου', 'OUT', 'SHELL πρατήριο Ρίου'),
                              ('Μισθοδοσία 11/2026', 'INC', 'Μισθοδοσία #'),
                              ('Δόση 12 δανείου GR8599900030000000000000089', 'TRF', 'Δόση # δανείου GR#'),
                              (None, 'WDR', 'Ανάληψη')):
        assert db.one('select bk_vec.phrase_of(:d, :k) from dual', d=descr, k=kind)[0] == want


def test_a_question_finds_the_meaning(vec):
    db = vec
    a = acct(db, 3000)
    for amount, text in ((42.5, 'Πληρωμή με κάρτα: Ψητοπωλείο Ο Λευτέρης'), (61, 'Πληρωμή με κάρτα: SHELL πρατήριο Λαμίας'),
                         (55, 'ΔΕΗ λογαριασμός ρεύματος'), (12.99, 'Netflix συνδρομή ταινιών')):
        pay(db, a, amount, text)
    db.conn.commit()
    assert db.cur.callfunc('bk_vec.refresh', int) >= 0
    db.conn.commit()
    # each text once, with its vector and its category
    got = dict(db.cur.execute("select text, category from bk_ai_phrase where text in ('Ψητοπωλείο Ο Λευτέρης', "
                              "'SHELL πρατήριο Λαμίας')").fetchall())
    assert got == {'Ψητοπωλείο Ο Λευτέρης': 'FOOD', 'SHELL πρατήριο Λαμίας': 'FUEL'}
    # no word in common: the grill house for "food out", the petrol station for "fuel"
    food = texts(db, 'φαγητό έξω', a)
    assert food and food[0][0] == 'Πληρωμή με κάρτα: Ψητοπωλείο Ο Λευτέρης' and food[0][2] == 'Φαγητό έξω'
    assert all('SHELL' not in t for t, _, _ in food)
    fuel = texts(db, 'fuel', a)
    assert [t for t, _, _ in fuel] == ['Πληρωμή με κάρτα: SHELL πρατήριο Λαμίας']
    assert [t for t, _, _ in texts(db, 'ταινίες', a)] == ['Netflix συνδρομή ταινιών']
    # the category of a question, and all its movements (of the account)
    code, name = db.cur.var(str), db.cur.var(str)
    db.cur.callproc('bk_vec.category_of', ['ρεύμα και νερό', code, name])
    assert (code.getvalue(), name.getvalue()) == ('BILL', 'Λογαριασμοί σπιτιού')
    assert [t for t, _, _ in texts(db, None, a, 'BILL')] == ['ΔΕΗ λογαριασμός ρεύματος']
    assert texts(db, '   ', a) == []
    # what it spent by category
    spent = dict(db.cur.execute('select category, amount from bk_ai_spend12_v where account_id = :a', a=a).fetchall())
    assert spent['FOOD'] == 42.5 and spent['FUEL'] == 61 and spent['BILL'] == 55 and spent['SUBS'] == 12.99
    # the forms: the hits of a search in BK_AI_HIT
    assert db.cur.callfunc('bk_vec.fill_hits', int, ['βενζίνη', a]) == 1
    assert db.one('select descr from bk_ai_hit')[0] == 'Πληρωμή με κάρτα: SHELL πρατήριο Λαμίας'


def test_the_close_of_a_day_gives_the_text(vec):
    db = vec
    a = acct(db, 500)
    e = pay(db, a, 18.4, 'Πληρωμή με κάρτα: Ζαχαροπλαστείο Η Γλυκιά Ζωή')
    db.conn.commit()
    close_days(db, 1)
    assert db.one('select p.text, p.category from bk_ai_entry_text t, bk_ai_phrase p '
                  'where t.entry_id = :e and p.id = t.phrase_id', e=e) == ('Ζαχαροπλαστείο Η Γλυκιά Ζωή', 'FOOD')
    assert db.one("select count(*) from bk_ai_phrase where vec is null")[0] == 0
