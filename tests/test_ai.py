"""test_ai.py -- the suspicious movements (db/BK_AI.sql, Oracle Machine Learning in the database): the features of
the movements, the model (One-Class SVM) trained from the days closed, the scan of a day (a movement at 03:30, 60
times the usual of its account, scored over the usual ones; an alert with its reasons in Greek, once), the close of
a day scans it too, an alert cleared or a fraud (its account blocked). Needs the privilege CREATE MINING MODEL
(CREATE_USER.sql, GRANT_AI.sql), else skipped.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests/test_ai.py
"""
import pytest

from test_core import DSN, close_days, customer, db  # noqa: F401  (db: the fixture)

pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set')


@pytest.fixture(scope='module')
def ai(db):
    if not db.one("select count(*) from session_privs where privilege = 'CREATE MINING MODEL'")[0]:
        pytest.skip('no CREATE MINING MODEL: db/GRANT_AI.sql')
    old = db.one("select max(value) from bk_setting where name = 'AI_THRESHOLD'")[0]
    yield db
    db.cur.execute("delete from bk_setting where name = 'AI_THRESHOLD'")
    if old is not None:
        db.cur.execute("insert into bk_setting (name, value) values ('AI_THRESHOLD', :v)", v=old)
    db.conn.commit()


def acct(db, money=0):
    a = db.fn('open_account', int, 'CUR', customer(db), 0)
    for op in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC'):
        db.cur.callfunc('bk_core.set_rule', int, [None, a, op, '*'], {'p_allowed': 'Y', 'p_fee': 0})
    if money:
        at(db, db.fn('deposit', int, a, money), '11:00')
    db.conn.commit()
    return a


def at(db, entry, hhmi):
    """the hour of a movement (as if it was made then)"""
    db.cur.execute("update bk_entry set created_at = trunc(book_date) + to_dsinterval('0 ' || :t || ':00') "
                   'where id = :e', t=hhmi, e=entry)


def history(db):
    """enough usual movements of the days closed to learn from (a database without the demo): spread on the day"""
    n = db.one('select count(*) from bk_ai_features where book_date < bk_core.open_day')[0]
    if n >= 400:
        return
    for i in range(12):
        a = acct(db, 2000)
        for k in range(30):
            e = db.fn('deposit', int, a, 40 + (i * 7 + k * 13) % 90) if k % 3 == 0 else \
                db.fn('withdraw', int, a, 20 + (i * 11 + k * 5) % 60, None, None, 'ATM' if k % 2 else 'BR')
            at(db, e, '%02d:%02d' % (8 + (i + k) % 14, (k * 7) % 60))
    db.conn.commit()
    close_days(db, 1)


def scores(db, lines):
    db.cur.execute('select line_id, prediction_probability(bk_ai_fraud, 0 using *) from bk_ai_features '
                   'where line_id in (%s)' % ','.join(str(x) for x in lines))
    return dict(db.cur.fetchall())


def lines_of(db, entry, account):
    return db.one('select id from bk_line where entry_id = :e and account_id = :a', e=entry, a=account)[0]


def test_the_model_and_a_suspicious_movement(ai):
    db = ai
    history(db)
    n = db.cur.callfunc('bk_ai.train', int)
    assert n >= 200 and db.one('select bk_ai.ready from dual')[0] == 'Y'
    info = db.one('select bk_ai.model_info from dual')[0]
    assert info.startswith('One-Class SVM, ') and 'από %d κινήσεις' % n in info
    # an account with its usual: 10 deposits of 60 € at noon; then 3.600 € out to another bank at 03:30
    a = acct(db, 5000)
    usual = []
    for _ in range(10):
        e = db.fn('withdraw', int, a, 60)
        at(db, e, '12:15')
        usual.append(lines_of(db, e, a))
    e = db.fn('transfer_out', int, a, 3600, 'GR9608100010000001234567890', 'Test', None, 'WEB')
    at(db, e, '03:30')
    odd = lines_of(db, e, a)
    db.conn.commit()
    s = scores(db, usual + [odd])
    assert s[odd] > max(s[x] for x in usual) + 0.1, s
    # the threshold between them: only that one an alert, with its reasons; not twice
    db.cur.execute("delete from bk_setting where name = 'AI_THRESHOLD'")
    db.cur.execute("insert into bk_setting (name, value) values ('AI_THRESHOLD', :v)",
                   v='%.4f' % ((s[odd] + max(s[x] for x in usual)) / 2))
    db.cur.callfunc('bk_ai.scan', int)
    db.conn.commit()
    got = db.cur.execute('select line_id, status, score, reasons from bk_ai_alert where account_id = :a', a=a).fetchall()
    assert [g[0] for g in got] == [odd] and got[0][1] == 'N' and got[0][2] == pytest.approx(s[odd], abs=1e-3)
    assert got[0][3] and len(got[0][3]) > 10
    db.cur.callfunc('bk_ai.scan', int)
    db.conn.commit()
    assert db.one('select count(*) from bk_ai_alert where line_id = :l', l=odd)[0] == 1
    v = db.one('select iban, holder, at_time, kind, amount, currency from bk_ai_alert_v where line_id = :l', l=odd)
    assert v[2:] == ('03:30', 'OUT', 3600, 'EUR')


def test_the_reasons_in_greek(ai):
    db = ai
    a = acct(db, 900)
    e = db.fn('withdraw', int, a, 700, None, None, 'BR')
    at(db, e, '02:10')
    db.conn.commit()
    ln = lines_of(db, e, a)
    det = '<Details algorithm="Support Vector Machines" class="0">' \
          '<Attribute name="NIGHT" actualValue="Y" weight=".3" rank="1"/>' \
          '<Attribute name="HOUR" actualValue="2" weight=".1" rank="2"/>' \
          '<Attribute name="CHANNEL" actualValue="BR" weight=".05" rank="3"/>' \
          '<Attribute name="AMOUNT_BAND" actualValue="A1K" weight=".04" rank="4"/></Details>'
    r = db.one('select bk_ai.reasons_of(:l, :d) from dual', l=ln, d=det)[0]
    assert r == 'νυχτερινή ώρα 02:10 · από γκισέ · ποσό 700,00 €'


def test_the_close_of_a_day_scans_it(ai):
    db = ai
    if db.one('select bk_ai.ready from dual')[0] != 'Y':
        db.cur.callfunc('bk_ai.train', int)
    db.cur.execute("delete from bk_setting where name = 'AI_THRESHOLD'")
    db.cur.execute("insert into bk_setting (name, value) values ('AI_THRESHOLD', '0.0001')")
    a = acct(db, 300)
    e = db.fn('withdraw', int, a, 250, None, None, 'BR')
    at(db, e, '04:05')
    db.conn.commit()
    close_days(db, 1)
    assert db.one('select count(*) from bk_ai_alert where entry_id = :e', e=e)[0] == 1


def test_an_alert_cleared_or_a_fraud(ai):
    db = ai
    if db.one('select bk_ai.ready from dual')[0] != 'Y':
        db.cur.callfunc('bk_ai.train', int)
    db.cur.execute("delete from bk_setting where name = 'AI_THRESHOLD'")
    db.cur.execute("insert into bk_setting (name, value) values ('AI_THRESHOLD', '0.0001')")
    a, b = acct(db, 500), acct(db, 500)
    for x in (a, b):
        at(db, db.fn('withdraw', int, x, 300, None, None, 'BR'), '03:00')
    db.conn.commit()
    db.cur.callfunc('bk_ai.scan', int)
    db.conn.commit()
    ida = db.one("select min(id) from bk_ai_alert where account_id = :a and status = 'N'", a=a)[0]
    idb = db.one("select min(id) from bk_ai_alert where account_id = :a and status = 'N'", a=b)[0]
    db.cur.execute("begin dbms_session.set_identifier('tst-ai'); end;")
    db.cur.callproc('bk_ai.review', [ida, 'C', 'ο πελάτης το επιβεβαίωσε'])
    db.cur.callproc('bk_ai.review', [idb, 'F', 'κλεμμένη κάρτα'])
    db.cur.execute('begin dbms_session.clear_identifier; end;')
    db.conn.commit()
    assert db.one('select status, reviewed_by, note from bk_ai_alert where id = :i', i=ida) == ('C', 'tst-ai', 'ο πελάτης το επιβεβαίωσε')
    assert db.one('select status from bk_ai_alert where id = :i', i=idb)[0] == 'F'
    assert db.one('select status from bk_account where id = :a', a=a)[0] == 'O'
    assert db.one('select status from bk_account where id = :a', a=b)[0] == 'B'          # the fraud: blocked
    for code, args in ((173, [ida, 'X']), (172, [-1, 'C'])):
        with pytest.raises(Exception, match='BK-%d' % code):
            db.cur.callproc('bk_ai.review', args)
        db.conn.rollback()
