"""test_ccards.py -- the credit cards on a live database (INSTALL.sql first): the limit (what may be spent: the
limit, less what is owed, less what is held), an authorization held, posted or released, two at once on one card
(a connection each: the second waits for the first, so the limit is never passed), the statement of each cycle
(its sums, its minimum, the day it is due), the grace (no interest when the statement before was paid in full),
the interest on what was owed each day when not, the fee when less than the minimum was paid, an authorization
released after CC_HOLD_DAYS; BK_CHECK empty.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests

It commits: its own customers and cards, and it closes days (the business day goes on).
"""
import datetime

import pytest

from test_core import DSN, close_days, customer, db  # noqa: F401  (db: the fixture)
from test_locks import later, waits

oracledb = pytest.importorskip('oracledb')
pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set')
DAY = datetime.timedelta(days=1)
RATE = 18.25                                # (a day: 0,05 %)


@pytest.fixture(scope='module')
def cc(db):
    db.fn('set_cc_product', int, 'TCC', 'Test πιστωτική', RATE, 5, 20, 20, 12)
    for op in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC'):
        db.cur.callfunc('bk_core.set_rule', int, ['TCC', None, op, '*'], {'p_allowed': 'Y', 'p_fee': 0})
    db.conn.commit()
    return db


def card(db, limit=1000, stmt_day=None):
    """a card account of a new customer and its card"""
    a = db.fn('cc_open', int, 'TCC', customer(db), limit, stmt_day)
    k = db.fn('new_card', int, a)
    db.conn.commit()
    return a, k


def payer(db, money=10000):
    """an account of the bank to pay from"""
    a = db.fn('open_account', int, 'TC1', customer(db), 0)
    db.fn('deposit', int, a, money)
    db.conn.commit()
    return a


def available(db, a):
    return float(db.fn('cc_available', float, a))


def held(db, a):
    return float(db.one('select held from bk_ccard where account_id = :a', a=a)[0])


def test_the_limit_and_the_authorizations(cc):
    db = cc
    a, k = card(db, 1000)
    h1 = db.fn('cc_authorize', int, k, 600, 'Test κατάστημα')
    db.conn.commit()                                        # (a refused one rolls back)
    assert available(db, a) == 400 and held(db, a) == 600
    assert 'διαθέσιμα 400,00' in db.fails(147, 'cc_authorize', k, 500)
    # posted: less than held (a tip less, a part of the order); what is left of it no more held
    e = db.fn('cc_capture', int, h1, 550)
    db.conn.commit()
    assert db.balance(a) == -550 and held(db, a) == 0 and available(db, a) == 450
    assert db.one('select kind, descr from bk_entry where id = :e', e=e) == ('PUR', 'Αγορά: Test κατάστημα')
    assert db.one('select status, amount, entry_id from bk_cc_auth where id = :h', h=h1) == ('P', 550, e)
    db.fails(148, 'cc_capture', h1)
    h2 = db.fn('cc_authorize', int, k, 400)
    db.conn.commit()
    db.fails(149, 'cc_capture', h2, 400.01)
    db.proc('cc_release', h2)
    db.conn.commit()
    assert available(db, a) == 450
    db.fails(148, 'cc_release', h2, rtype=None)
    # the limit lower than what is owed: nothing more, till it is paid
    db.proc('cc_set_limit', a, 300)
    db.conn.commit()
    assert available(db, a) == -250
    db.fails(147, 'cc_authorize', k, 1)
    db.fails(151, 'cc_set_limit', a, -1, rtype=None)
    db.proc('cc_set_limit', a, 1000)
    db.fn('cc_purchase', int, k, 450)
    db.conn.commit()
    assert available(db, a) == 0 and db.balance(a) == -1000
    # a blocked card; not an account of a card; a deposit account: not of a card
    db.proc('set_card_status', k, 'B')
    db.conn.commit()
    db.fails(134, 'cc_authorize', k, 1)
    db.fails(146, 'cc_available', payer(db), rtype=float)
    db.fails(146, 'cc_open', 'TC1', customer(db), 100)
    db.fails(150, 'cc_open', 'TCC', customer(db), 100, 29)
    db.check()


def test_two_purchases_at_once_never_pass_the_limit(cc):
    db = cc
    a, k = card(db, 1000)
    db.fn('cc_authorize', int, k, 700)                    # not committed yet
    t, out = later(lambda c: c.cursor().callfunc('bk_core.cc_authorize', int, [k, 700]))
    assert waits(t)                                         # the row of the account: locked by the first
    db.conn.commit()
    t.join(30)
    assert 'BK-147' in out.get('error', ''), out
    # the first one rolled back: the second one passes, with all of the limit
    db.fn('cc_authorize', int, k, 200)
    t, out = later(lambda c: c.cursor().callfunc('bk_core.cc_authorize', int, [k, 250]))
    assert waits(t)
    db.conn.rollback()
    t.join(30)
    assert 'error' not in out, out
    assert held(db, a) == 950 and available(db, a) == 50
    # a payment and a purchase at once: the purchase waits, and sees the money paid
    p = payer(db)
    db.fn('cc_pay', int, a, p, 400)
    t, out = later(lambda c: c.cursor().callfunc('bk_core.cc_authorize', int, [k, 300]))
    assert waits(t)
    db.conn.commit()
    t.join(30)
    assert 'error' not in out, out
    assert available(db, a) == 150 and held(db, a) == 1250
    db.check()


def stmt_day_soon(db):
    """a statement day 2 days on (or the 1st, a few days on)"""
    d = db.day() + 2 * DAY
    return d.day if d.day <= 28 else 1


def statements(db, a):
    db.cur.execute('select stmt_date, period_from, opening, purchases, payments, interest, fees, closing, min_due, '
                   'due_date, late_fee from bk_cc_statement where account_id = :a order by stmt_date', a=a)
    cols = [d[0].lower() for d in db.cur.description]
    return [dict(zip(cols, r)) for r in db.cur]


def until_statement(db, a, n):
    """the days closed till the n-th statement of the card"""
    for _ in range(40):
        if len(statements(db, a)) >= n:
            return statements(db, a)[n - 1]
        close_days(db, 1)
    raise AssertionError('no statement %d' % n)


def owed_each_day(db, a, d1, d2):
    db.cur.execute('select value_date, credit - debit from bk_line where account_id = :a', a=a)
    lines = list(db.cur)
    out, d = [], d1
    while d <= d2:
        out.append(max(0, -sum(float(x) for v, x in lines if v <= d)))
        d += DAY
    return out


def sums_ok(s):
    assert s['opening'] + s['purchases'] - s['payments'] + s['interest'] + s['fees'] == pytest.approx(s['closing'], abs=1e-9)


def test_the_statements_the_grace_the_interest_and_the_fee(cc):
    db = cc
    a, k = card(db, 2000, stmt_day_soon(db))
    p = payer(db)
    db.fn('cc_purchase', int, k, 1000, 'Test ηλεκτρονικά')
    db.conn.commit()
    # the first statement: no interest (the first cycle), the minimum 5 % (at least 20), due in 20 days
    s1 = until_statement(db, a, 1)
    assert (s1['opening'], s1['purchases'], s1['payments'], s1['interest'], s1['closing']) == (0, 1000, 0, 0, 1000)
    assert s1['min_due'] == 50 and s1['due_date'] == s1['stmt_date'] + 20 * DAY and s1['late_fee'] is None
    # paid in full before its due date: the next one without interest
    db.fn('cc_pay', int, a, p, 1000)
    db.fn('cc_purchase', int, k, 300, 'Test σούπερ μάρκετ')
    db.conn.commit()
    s2 = until_statement(db, a, 2)
    sums_ok(s2)
    assert (s2['opening'], s2['payments'], s2['interest'], s2['closing'], s2['min_due']) == (1000, 1000, 0, 300, 20)
    assert statements(db, a)[0]['late_fee'] == 0                    # (paid in time)
    # its minimum only: the next one with interest on what was owed each day, the new purchases from their day
    db.fn('cc_pay', int, a, p, 20)
    db.conn.commit()
    close_days(db, 3)
    db.fn('cc_purchase', int, k, 100)
    db.conn.commit()
    s3 = until_statement(db, a, 3)
    sums_ok(s3)
    want = round(sum(owed_each_day(db, a, s3['period_from'], s3['stmt_date'])) * RATE / 100 / 365, 2)
    assert want > 0 and s3['interest'] == want
    assert s3['closing'] == 300 - 20 + 100 + want and s3['min_due'] == max(20, round(s3['closing'] * 0.05, 2))
    e = db.one("select descr from bk_entry e join bk_line l on l.entry_id = e.id where l.account_id = :a and e.kind = 'INT'", a=a)
    assert e[0].startswith('Τόκοι κάρτας ')
    # nothing paid by its due date: the fee of the product, on that day
    while db.day() <= s3['due_date']:
        close_days(db, 1)
    s = statements(db, a)[2]
    assert s['late_fee'] == 12
    assert db.one("select sum(l.debit) from bk_line l join bk_entry e on e.id = l.entry_id "
                  "where l.account_id = :a and e.kind = 'FEE' and l.op = 'FEE'", a=a)[0] == 12
    # no interest of deposits on a card, at the end of a month either
    assert db.one('select count(*) from bk_accrual where account_id = :a', a=a)[0] == 0
    s4 = until_statement(db, a, 4)
    sums_ok(s4)
    assert s4['fees'] == 12 and s4['interest'] > 0
    db.check()


def test_an_authorization_not_posted_released(cc):
    db = cc
    a, k = card(db, 500)
    h = db.fn('cc_authorize', int, k, 120, 'Test ξενοδοχείο')
    db.conn.commit()
    days = int(db.one("select value from bk_setting where name = 'CC_HOLD_DAYS'")[0])
    close_days(db, days - 1)
    assert db.one('select status from bk_cc_auth where id = :h', h=h)[0] == 'H'
    close_days(db, 1)
    assert db.one('select status from bk_cc_auth where id = :h', h=h)[0] == 'R'
    assert held(db, a) == 0 and available(db, a) == 500
    db.check()


def test_a_refund_a_payment_back_and_the_close(cc):
    db = cc
    a, k = card(db, 500)
    p = payer(db)
    e = db.fn('cc_purchase', int, k, 80)
    r = db.fn('reverse', int, e, 'Test επιστροφή')               # (a refund of the shop)
    pay = db.fn('cc_pay', int, a, p, 50)
    db.conn.commit()
    assert db.balance(a) == 50 and available(db, a) == 550
    # a payment back (a bounce): owed again, even beyond what the card has
    db.fn('cc_purchase', int, k, 540)
    db.fn('reverse', int, pay, 'Test επιστροφή πληρωμής')
    db.conn.commit()
    assert db.balance(a) == -540 and available(db, a) == -40 and r
    # closed: nothing owed and nothing held
    db.fn('cc_pay', int, a, p, 540)
    h = db.fn('cc_authorize', int, k, 10)
    db.conn.commit()
    db.fails(125, 'close_account', a, rtype=None)
    db.proc('cc_release', h)
    db.proc('close_account', a)
    db.conn.commit()
    assert db.one('select status from bk_account where id = :a', a=a)[0] == 'C'
    db.fails(112, 'cc_authorize', k, 1)
    db.check()
