"""test_core.py -- the rules of BK_CORE on a live database (INSTALL.sql demo first): the check digits, the
customers, the accounts and their holders, the movements in double entry (deposit, withdrawal, transfers, to
and from other banks, a reversal) and what is refused, the interest of each day (its balance by value date,
the rate of its tier and of its day, the day basis, the overdraft) and its capitalization with the tax, the
close of a day and of an account; BK_CHECK empty at the end of each test.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests

It commits: on its own customers and accounts (their names start with Test), and it closes days (the business
day goes on).
"""
import datetime
import itertools
import os
import random

import pytest

oracledb = pytest.importorskip('oracledb')
DSN = os.environ.get('BANK_DSN')
pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set (user/password@host:port/service)')
SEQ = itertools.count(1)
TEST_IBAN = 'GR1601101250000000012300695'


class Db:
    def __init__(self, conn):
        self.conn = conn
        self.cur = conn.cursor()

    def one(self, sql, **kw):
        self.cur.execute(sql, kw)
        return self.cur.fetchone()

    def fn(self, name, rtype, *args, **kw):
        return self.cur.callfunc('bk_core.' + name, rtype, list(args), kw)

    def proc(self, name, *args, **kw):
        self.cur.callproc('bk_core.' + name, list(args), kw)

    def fails(self, code, name, *args, rtype=int, **kw):
        """the call fails with BK-<code> (its text back); rolled back"""
        with pytest.raises(oracledb.DatabaseError) as e:
            if rtype is None:
                self.proc(name, *args, **kw)
            else:
                self.fn(name, rtype, *args, **kw)
        self.conn.rollback()
        assert f'BK-{code}' in str(e.value), str(e.value)
        return str(e.value)

    def balance(self, acc):
        return float(self.one('select balance from bk_account where id = :a', a=acc)[0])

    def day(self):
        return self.one('select bk_core.open_day from dual')[0]

    def check(self):
        self.cur.execute('select what, ref, detail from bk_check')
        rows = self.cur.fetchall()
        assert rows == [], rows


def afm():
    """a made-up AFM with a right check digit, of nobody in the database"""
    while True:
        s = ''.join(random.choice('0123456789') for _ in range(8))
        t = sum(int(c) * 2 ** (8 - i) for i, c in enumerate(s))
        return s + str(t % 11 % 10)


@pytest.fixture(scope='module')
def db():
    conn = oracledb.connect(DSN)
    d = Db(conn)
    n = d.one('select count(*) from bk_product')[0]
    if not n:
        pytest.skip('INSTALL.sql first')
    if not d.one('select count(*) from bk_setting where name = :n', n='START_DAY')[0]:
        d.proc('set_start', datetime.date.today())
        conn.commit()
    # the products of the tests: TS1 savings ACT365, a month, 3 % (10.000: 4 %), tax 15 %; TC1 current, 10 % on
    # an overdraft, no interest on a balance
    for code, kind, od in (('TS1', 'SAV', 0), ('TC1', 'CUR', 10)):
        if not d.one('select count(*) from bk_product where code = :c', c=code)[0]:
            d.cur.execute("insert into bk_product (code, name, kind, day_basis, cap_every, tax_rate, od_rate) "
                          "values (:c, 'Test ' || :c, :k, 'ACT365', 'M', 15, :od)", c=code, k=kind, od=od)
    p1 = d.one("select id from bk_product where code = 'TS1'")[0]
    p2 = d.one("select id from bk_product where code = 'TC1'")[0]
    d.proc('set_rate', p1, datetime.date(2020, 1, 1), 0, 3)
    d.proc('set_rate', p1, datetime.date(2020, 1, 1), 10000, 4)
    d.proc('set_rate', p2, datetime.date(2020, 1, 1), 0, 0)
    # the rules of the movements of the bank (of the demo) not on them: everything allowed, no fees
    for code in ('TS1', 'TC1'):
        for op in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC'):
            d.cur.callfunc('bk_core.set_rule', int, [code, None, op, '*'], {'p_allowed': 'Y', 'p_fee': 0})
    conn.commit()
    yield d
    conn.rollback()
    conn.close()


def customer(db, name=None):
    v = db.fn('new_customer', int, name or 'Test Πελάτης %d' % next(SEQ), afm())
    db.conn.commit()
    return v


def account(db, product='TS1', od=0):
    a = db.fn('open_account', int, product, customer(db), od)
    db.conn.commit()
    return a


def test_check_digits(db):
    assert db.fn('afm_ok', str, '094014201') == 'Y'
    assert db.fn('afm_ok', str, '094014202') == 'N'
    assert db.fn('afm_ok', str, '12345') == 'N' and db.fn('afm_ok', str, '000000000') == 'N'
    assert db.fn('iban_ok', str, TEST_IBAN) == 'Y'
    assert db.fn('iban_ok', str, TEST_IBAN[:-1] + '6') == 'N'
    assert db.fn('iban_ok', str, 'DE89370400440532013000') == 'N'            # (Greek only)
    iban = db.fn('new_iban', str, 123)
    assert iban.startswith('GR') and len(iban) == 27 and iban.endswith('0000000000000123')
    assert db.fn('iban_ok', str, iban) == 'Y'


def test_customers(db):
    c = customer(db)
    code, = db.one('select code from bk_customer where id = :c', c=c)
    assert code == 'C' + str(c).zfill(6)
    db.fails(103, 'new_customer', ' ')
    db.fails(104, 'new_customer', 'Test x', '123456789')
    db.fails(105, 'new_customer', 'Test x', None, None, 'όχι email')
    a = db.one('select afm from bk_customer where id = :c', c=c)[0]
    db.fails(106, 'new_customer', 'Test x', a)


def test_accounts_and_holders(db):
    c1, c2 = customer(db), customer(db)
    a = db.fn('open_account', int, 'tc1', c1, 500, 'Test όψεως')
    db.conn.commit()
    iban, status, od, opened = db.one('select iban, status, od_limit, opened_on from bk_account where id = :a', a=a)
    assert db.fn('iban_ok', str, iban) == 'Y' and (status, float(od)) == ('O', 500) and opened == db.day()
    db.fails(110, 'open_account', 'NOPE', c1)
    db.fails(111, 'open_account', 'TS1', c1, 100)                              # (an overdraft: current only)
    db.fails(109, 'open_account', 'TS1', -1)
    db.proc('add_holder', a, c2)
    db.conn.commit()
    db.fails(113, 'add_holder', a, c2, rtype=None)
    assert db.one("select count(*) from bk_holder where account_id = :a and role = 'J'", a=a)[0] == 1
    db.fails(114, 'remove_holder', a, c1, rtype=None)                          # (the primary stays)
    db.proc('remove_holder', a, c2)
    db.proc('set_od_limit', a, 1000)
    db.fails(111, 'set_od_limit', a, -5, rtype=None)
    db.fails(115, 'set_status', a, 'C', rtype=None)
    db.conn.commit()
    db.check()


def test_movements_in_double_entry(db):
    a, b = account(db, 'TC1', 300), account(db, 'TS1')
    e = db.fn('deposit', int, a, 1000, 'Test κατάθεση')
    db.fn('withdraw', int, a, 250.5)
    db.fn('transfer', int, a, b, 400)
    db.fn('transfer_out', int, a, 600, 'gr16 0110 1250 0000 0001 2300 695', 'Test έξω')    # (into the overdraft)
    db.fn('transfer_in', int, b, 99.99, TEST_IBAN)
    db.conn.commit()
    assert db.balance(a) == round(1000 - 250.5 - 400 - 600, 2) and db.balance(b) == 499.99
    # each entry balanced, its lines: the account and the bank
    db.cur.execute('select gl_code, debit, credit from bk_line where entry_id = :e order by id', e=e)
    assert [tuple(r) for r in db.cur] == [('CASH', 1000, 0), (None, 0, 1000)]
    # the statement: its running balance
    db.cur.execute('select kind, debit, credit, balance from bk_statement where account_id = :a order by line_id', a=a)
    rows = [tuple(r) for r in db.cur]
    assert [r[0] for r in rows] == ['DEP', 'WDR', 'TRF', 'OUT'] and float(rows[-1][3]) == db.balance(a)
    # refused: more than it has (with its overdraft), an amount of 3 decimals or 0, the same account, a wrong IBAN
    db.fails(119, 'withdraw', a, 50)                                           # (-250,50 and 300: 49,50 left)
    db.fn('withdraw', int, a, 49.5)
    db.conn.commit()
    db.fails(117, 'deposit', a, 0)
    db.fails(117, 'deposit', a, 1.005)
    db.fails(120, 'transfer', b, b, 1)
    db.fails(121, 'transfer_out', b, 1, 'GR0000')
    db.fails(116, 'deposit', b, 1, None, db.day() - datetime.timedelta(days=1))   # (a value date in the past)
    # blocked: money in, nothing out; closed: nothing
    db.proc('set_status', b, 'B')
    db.fn('deposit', int, b, 0.01)
    db.conn.commit()
    db.fails(118, 'withdraw', b, 1)
    db.fails(118, 'transfer', b, a, 1)
    db.proc('set_status', b, 'O')
    db.conn.commit()
    db.check()


def test_a_reversal(db):
    a, b = account(db, 'TC1'), account(db, 'TS1')
    db.fn('deposit', int, a, 100)
    e = db.fn('transfer', int, a, b, 40)
    db.conn.commit()
    r = db.fn('reverse', int, e, 'Test λάθος')
    db.conn.commit()
    assert (db.balance(a), db.balance(b)) == (100, 0)
    assert db.one('select kind, reversal_of from bk_entry where id = :r', r=r) == ('REV', e)
    db.fails(123, 'reverse', e)                                                # once
    db.fails(122, 'reverse', r)                                                # not a reversal
    db.fails(122, 'reverse', -1)
    # the money gone from the account that took it: refused
    e2 = db.fn('transfer', int, a, b, 30)
    db.fn('withdraw', int, b, 30)
    db.conn.commit()
    db.fails(119, 'reverse', e2)
    db.check()


def close_days(db, n):
    for _ in range(n):
        db.proc('close_day', db.day())
    db.conn.commit()


def test_the_interest_of_each_day(db):
    a = account(db, 'TS1')
    d0 = db.day()
    db.fn('deposit', int, a, 1000)
    db.fn('deposit', int, a, 500, 'Test αύριο', d0 + datetime.timedelta(days=1))      # (counts from tomorrow)
    db.conn.commit()
    close_days(db, 2)
    # a day as any other: no interest counted at its close (the end of a period, or when it is needed)
    assert db.one('select count(*) from bk_accrual where account_id = :a', a=a)[0] == 0 or d0.day >= 27
    db.proc('accrue', a)
    db.conn.commit()
    # two stretches: the balance by value date changed on the 2nd day
    db.cur.execute('select day_from, day_to, balance, rate, days, year_days, interest from bk_accrual '
                   'where account_id = :a order by day_from', a=a)
    rows = [tuple(r) for r in db.cur]
    assert [(r[0], r[1]) for r in rows] == [(d0, d0), (d0 + datetime.timedelta(days=1),) * 2]
    assert [(r[2], r[3], r[4], r[5]) for r in rows] == [(1000, 3, 1, 365), (1500, 3, 1, 365)]
    assert [float(r[6]) for r in rows] == [round(1000 * 0.03 / 365, 6), round(1500 * 0.03 / 365, 6)]
    db.proc('accrue', a)                                     # again: nothing more
    assert db.one('select count(*) from bk_accrual where account_id = :a', a=a)[0] == 2
    # a tier: 10.000 and more at 4 %, all of it; 3 days of it: 3 x the interest of a day (each rounded)
    db.fn('deposit', int, a, 9000)
    db.conn.commit()
    close_days(db, 3)
    db.proc('accrue', a)
    db.conn.commit()
    r = db.one('select balance, rate, days, interest from bk_accrual where account_id = :a and day_from = '
               '(select max(day_from) from bk_accrual where account_id = :a)', a=a)
    assert (float(r[0]), float(r[1]), r[2], float(r[3])) == (10500, 4, 3, round(3 * round(10500 * 0.04 / 365, 6), 6))
    assert float(db.fn('interest_by_day', float, a, d0, d0 + datetime.timedelta(days=4))) == \
        float(db.one('select sum(interest) from bk_accrual where account_id = :a', a=a)[0])
    acc = float(db.one('select accrued from bk_account where id = :a', a=a)[0])
    assert acc == round(sum(float(x) for x, in db.cur.execute('select interest from bk_accrual where account_id = :a', a=a)), 6)
    db.check()


def test_capitalized_with_its_tax(db):
    """to the end of the month: the accrued rounded, credited; its tax 15 % debited to the account, credited to
    TAX; the rest of the rounding stays"""
    a = account(db, 'TS1')
    db.fn('deposit', int, a, 5000)
    db.conn.commit()
    d = db.day()
    end = (d.replace(day=28) + datetime.timedelta(days=4)).replace(day=1) - datetime.timedelta(days=1)
    close_days(db, (end - d).days + 1)
    days = (end - d).days + 1
    accrued = round(days * round(5000 * 0.03 / 365, 6), 6)
    gross, tax, e = db.one('select gross, tax, entry_id from bk_capital where account_id = :a', a=a)
    assert float(gross) == round(accrued, 2) and float(tax) == round(float(gross) * 0.15, 2)
    assert db.balance(a) == round(5000 + float(gross) - float(tax), 2)
    db.cur.execute('select gl_code, debit, credit from bk_line where entry_id = :e order by id', e=e)
    assert [tuple(r) for r in db.cur] == [('INT_EXP', gross, 0), (None, 0, gross), (None, tax, 0), ('TAX', 0, tax)]
    rest = float(db.one('select accrued from bk_account where id = :a', a=a)[0])
    assert abs(rest - (accrued - float(gross))) < 1e-9 and abs(rest) < 0.005
    db.check()


def test_an_overdraft_pays_interest(db):
    a = account(db, 'TC1', 1000)
    db.fn('withdraw', int, a, 730)
    db.conn.commit()
    close_days(db, 3)
    db.proc('accrue', a)
    db.conn.commit()
    db.cur.execute('select balance, rate, days, interest from bk_accrual where account_id = :a order by day_from', a=a)
    rows = [tuple(float(x) for x in r) for r in db.cur]
    assert rows == [(-730, 10, 3, round(3 * round(-730 * 0.10 / 365, 6), 6))]
    # closed: its balance 0 after its debit interest (capitalized at the close, to INT_INC); before: refused
    db.fails(125, 'close_account', a, rtype=None)
    db.fn('deposit', int, a, 730)
    db.conn.commit()
    db.fails(125, 'close_account', a, rtype=None)                              # (0, less its interest)
    owed = round(-float(db.one('select accrued from bk_account where id = :a', a=a)[0]), 2)
    assert owed == round(3 * 730 * 0.10 / 365, 2)
    db.fn('deposit', int, a, owed)
    db.conn.commit()
    db.proc('close_account', a)
    db.conn.commit()
    st, closed, bal = db.one('select status, closed_on, balance from bk_account where id = :a', a=a)
    assert (st, closed, float(bal)) == ('C', db.day(), 0)
    g, e = db.one('select gross, entry_id from bk_capital where account_id = :a', a=a)
    assert float(g) == -owed
    db.cur.execute('select gl_code, debit, credit from bk_line where entry_id = :e order by id', e=e)
    assert [tuple(r) for r in db.cur] == [(None, owed, 0), ('INT_INC', 0, owed)]
    db.fails(112, 'deposit', a, 1)                                             # closed: nothing in
    db.fails(112, 'close_account', a, rtype=None)
    db.check()


def test_the_close_of_a_day(db):
    d = db.day()
    db.fails(124, 'close_day', d + datetime.timedelta(days=1), rtype=None)
    db.fails(102, 'set_start', d, rtype=None)                                  # (entries there)
    close_days(db, 1)
    assert db.day() == d + datetime.timedelta(days=1)
    # 30/360: the 31st counts 0, the end of February 30 days in all (the calendar of the stretches)
    for day, d30 in db.cur.execute("select day, d30 from bk_calendar where to_char(day, 'DD') = '31' "
                                   "or (to_char(day, 'MM') = '02' and day = last_day(day))").fetchall():
        assert d30 == (0 if day.day == 31 else 30 - day.day + 1)
    a = db.one('select min(id) from bk_account')[0]
    db.fails(124, 'accrue', a, d + datetime.timedelta(days=1), rtype=None)      # (a day not closed)
    db.check()


def test_the_stretches_as_day_by_day(db):
    """every account (the demo: a year of them; 30/360 too, its 31sts and the end of February; a rate changed;
    overdrafts; capitalized): its interest by stretches the same, to the last decimal, as day by day"""
    ids = [r[0] for r in db.cur.execute("select id from bk_account where status <> 'C' order by id").fetchall()]
    for a in ids:
        db.proc('accrue', a)
    db.conn.commit()
    for a, opened, upto, total in db.cur.execute(
            "select a.id, a.opened_on, a.accrued_to, nvl(sum(x.interest), 0) from bk_account a "
            "left join bk_accrual x on x.account_id = a.id where a.accrued_to is not null "
            "group by a.id, a.opened_on, a.accrued_to order by a.id").fetchall():
        by_day = db.cur.connection.cursor().callfunc('bk_core.interest_by_day', float, [a, opened, upto])
        assert round(by_day, 6) == round(float(total), 6), (a, by_day, total)
    db.check()
