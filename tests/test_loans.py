"""test_loans.py -- the loans on a live database (INSTALL.sql first): a loan paid to the account of its customer,
its schedule (an annuity), its installments due collected from that account, one late (its fee, its late
interest, collected when there is money), a variable rate again (the installments after it again), a prepayment
(the same installment and fewer of them, or a smaller one), paid off and closed; BK_CHECK empty at every step.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests

It commits: its own customers, accounts, products and index, and it closes days (the business day goes on).
"""
import datetime

import pytest

from test_core import DSN, close_days, customer, db  # noqa: F401  (db: the fixture)

pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set')
DAY = datetime.timedelta(days=1)


@pytest.fixture(scope='module')
def ln(db):
    """TLF fixed 12 %, a prepayment 1 %, the late fee 15 after 5 days; TLV variable: TSTIDX + 2, again every month"""
    db.fn('set_ln_product', int, 'TLF', 'Test σταθερό', 'F', 12, None, 3, 2.5, 15, 5, 1, 120)
    db.proc('set_ln_index', 'TSTIDX', datetime.date(2020, 1, 1), 3)
    db.fn('set_ln_product', int, 'TLV', 'Test κυμαινόμενο', 'V', 2, 'TSTIDX', 1, 2.5, 15, 5, 0, 360)
    db.conn.commit()
    return db


def payer(db, money=0):
    c = customer(db)
    a = db.fn('open_account', int, 'TC1', c, 0)
    if money:
        db.fn('deposit', int, a, money)
    db.conn.commit()
    return c, a


def soon(db):
    """a day of the installments a few days on"""
    d = db.day() + 3 * DAY
    return d.day if d.day <= 28 else 1


def rows(db, a):
    db.cur.execute('select n, due_date, rate, principal, interest, payment, balance, status, paid, late_fee, late_booked '
                   'from bk_ln_schedule where account_id = :a order by n', a=a)
    cols = [d[0].lower() for d in db.cur.description]
    return [dict(zip(cols, r)) for r in db.cur]


def until(db, a, n, status='P'):
    """the days closed till its installment n is so"""
    for _ in range(70):
        r = [x for x in rows(db, a) if x['n'] == n]
        if r and r[0]['status'] == status:
            return r[0]
        close_days(db, 1)
    raise AssertionError('installment %d not %s' % (n, status))


def annuity(b, rate, n):
    r = rate / 1200
    return round(b * r / (1 - (1 + r) ** -n), 2)


def test_a_loan_its_schedule_and_its_installments(ln):
    db = ln
    c, p = payer(db, 500)
    a = db.fn('ln_open', int, 'TLF', c, 10000, 12, p, soon(db))
    db.conn.commit()
    s = rows(db, a)
    pay = annuity(10000, 12, 12)
    assert len(s) == 12 and {x['payment'] for x in s[:-1]} == {pay} and s[-1]['balance'] == 0
    assert s[0]['interest'] == 100 and s[0]['principal'] == pay - 100 and sum(x['principal'] for x in s) == 10000
    assert db.balance(a) == -10000 and db.balance(p) == 10500
    assert db.one("select status, currency from bk_account where id = :a", a=a) == ('O', 'EUR')
    db.check()
    # its first installment: its interest booked, collected from the account
    r = until(db, a, 1)
    assert r['paid'] == pay and db.balance(p) == 10500 - pay and db.balance(a) == -(10000 - (pay - 100))
    assert db.one("select v.principal_after, v.owed, v.late from bk_loan_v v where v.id = :a", a=a) == \
        (s[0]['balance'], 10000 - (pay - 100), 0)
    db.check()
    # what is refused
    db.fails(156, 'ln_open', 'TLF', c, 1000, 121, p)
    db.fails(156, 'ln_open', 'TLF', c, 1000, 12, p, 29)
    db.fails(157, 'ln_open', 'TLF', customer(db), 1000, 12, p)
    db.fails(155, 'ln_open', 'TC1', c, 1000, 12, p)
    db.fails(155, 'ln_payoff', p, rtype=float)


def test_an_installment_late(ln):
    db = ln
    c, p = payer(db)
    a = db.fn('ln_open', int, 'TLF', c, 2400, 12, p, soon(db))
    db.fn('withdraw', int, p, 2400)                    # (nothing left to pay it)
    db.conn.commit()
    r = until(db, a, 1, 'O')
    db.check()
    # after its 5 days of grace: late, its fee; its late interest each day on what is late
    r = until(db, a, 1, 'L')
    assert r['late_fee'] == 15 and r['paid'] == 0
    owed = r['payment'] + 15
    close_days(db, 3)
    li = db.one('select late_int from bk_ln_schedule where account_id = :a and n = 1', a=a)[0]
    assert li >= round(owed * 14.5 / 36000, 6) * 3 - 1e-6
    assert db.balance(a) == -(2400 + r['interest'] + 15) - db.one(
        'select late_booked from bk_ln_schedule where account_id = :a and n = 1', a=a)[0]
    db.check()
    # a prepayment while one is late: refused
    db.fails(158, 'ln_prepay', a, 100)
    # money in: collected with its late interest
    db.fn('deposit', int, p, 1000)
    db.conn.commit()
    close_days(db, 1)
    r = rows(db, a)[0]
    assert r['status'] == 'P' and r['paid'] == r['payment'] + 15 + r['late_booked'] and r['late_booked'] > 0
    assert db.balance(a) == -(2400 - r['principal'])
    db.check()


def test_a_variable_rate_again(ln):
    db = ln
    c, p = payer(db, 5000)
    a = db.fn('ln_open', int, 'TLV', c, 12000, 24, p, soon(db))
    db.conn.commit()
    assert db.one('select rate from bk_loan where account_id = :a', a=a)[0] == 5          # 3 + 2
    db.proc('set_ln_index', 'TSTIDX', db.day(), 4)
    db.conn.commit()
    r = until(db, a, 1)
    s = rows(db, a)
    # again at its first installment (every month): the next ones at 6 %, on what was left after it
    assert r['rate'] == 5 and {x['rate'] for x in s[1:]} == {6}
    assert s[1]['payment'] == annuity(r['balance'], 6, 23) and len(s) == 24 and s[-1]['balance'] == 0
    assert db.one('select rate from bk_loan where account_id = :a', a=a)[0] == 6
    db.check()
    db.proc('set_ln_index', 'TSTIDX', db.day(), 3)          # (the others, as before)
    db.conn.commit()


def test_a_prepayment_and_the_payoff(ln):
    db = ln
    c, p = payer(db, 20000)
    a = db.fn('ln_open', int, 'TLF', c, 12000, 24, p, soon(db))
    db.conn.commit()
    r1 = until(db, a, 1)
    close_days(db, 10)
    left = r1['balance']
    pay = r1['payment']
    # T: the same installment, fewer of them; interest on what is prepaid for its days, the fee 1 %
    before = db.balance(p)
    db.fn('ln_prepay', int, a, 3000, 'T')
    db.conn.commit()
    s = rows(db, a)
    pre = s[1]
    days = (db.day() - r1['due_date']).days                  # (since its installment: 11, the day of it closed)
    assert (pre['principal'], pre['interest'], pre['late_fee'], pre['status']) == (3000, round(3000 * 12 / 36000 * days, 2), 30, 'P')
    assert db.balance(p) == round(before - 3000 - pre['interest'] - 30, 2)
    rest = s[2:]
    assert rest[0]['payment'] == pay and len(rest) < 23 and rest[-1]['balance'] == 0
    assert sum(x['principal'] for x in rest) == round(left - 3000, 2)
    assert rest[0]['due_date'] == r1['due_date'].replace(month=r1['due_date'].month % 12 + 1,
                                                           year=r1['due_date'].year + (r1['due_date'].month == 12))
    db.check()
    # P: the same months, a smaller installment
    n = len(rest)
    db.fn('ln_prepay', int, a, 1000, 'P')
    db.conn.commit()
    s2 = [x for x in rows(db, a) if x['status'] == 'D']
    assert len(s2) == n and s2[0]['payment'] < pay
    db.fails(158, 'ln_prepay', a, 100, 'X')
    db.check()
    # paid off: what it takes today, all of it; closed
    off = db.fn('ln_payoff', float, a)
    left = db.one("select principal_after from bk_loan_v where id = :a", a=a)[0]
    assert off == pytest.approx(left + round(left * 0.01, 2), abs=0.01)
    db.fn('ln_prepay', int, a, 1000000)
    db.conn.commit()
    assert db.one('select status from bk_loan where account_id = :a', a=a)[0] == 'C'
    assert db.one('select status, balance from bk_account where id = :a', a=a) == ('C', 0)
    assert db.fn('ln_payoff', float, a) == 0
    db.fails(155, 'ln_prepay', a, 10)
    db.check()


def test_a_loan_paid_to_its_end(ln):
    db = ln
    c, p = payer(db, 400)
    a = db.fn('ln_open', int, 'TLF', c, 300, 2, p, soon(db))
    db.conn.commit()
    until(db, a, 2)
    close_days(db, 1)
    assert db.one('select status from bk_loan where account_id = :a', a=a)[0] == 'C'
    assert db.one('select status from bk_account where id = :a', a=a)[0] == 'C'
    # no interest of deposits on a loan
    assert db.one('select count(*) from bk_accrual where account_id = :a', a=a)[0] == 0
    db.check()
