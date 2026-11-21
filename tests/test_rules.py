"""test_rules.py -- the rules of the movements (BK_RULE) on a live database (INSTALL.sql first, with or
without demo): allowed or not by channel (BR the counter, WEB e-banking, ATM), the most particular rule first
(an account before its product before the bank, a channel before all of them), the amount of a movement, the
limits of the day and of the month (of a channel or of all of them; a reversal gives its movement back), the fee
after the free ones of the month (in the same entry, to the FEE account of the bank), the balance that must be
left, a transfer checked on both of its accounts; set_rule / remove_rule and what they refuse; BK_LIMITS.
BK_CHECK empty at the end of each test.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests

It commits: on its own customers, accounts and rules (of its own accounts and of its own product TR1).
"""
import itertools
import os
import random

import pytest

oracledb = pytest.importorskip('oracledb')
DSN = os.environ.get('BANK_DSN')
pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set (user/password@host:port/service)')
SEQ = itertools.count(1)
OTHER_IBAN = 'GR1601101250000000012300695'


class Db:
    def __init__(self, conn):
        self.conn = conn
        self.cur = conn.cursor()

    def one(self, sql, **kw):
        self.cur.execute(sql, kw)
        return self.cur.fetchone()

    def fn(self, name, rtype, *args, **kw):
        return self.cur.callfunc('bk_core.' + name, rtype, list(args), kw)

    def fails(self, code, name, *args, rtype=int, **kw):
        """the call fails with BK-<code> (its text back); rolled back"""
        with pytest.raises(oracledb.DatabaseError) as e:
            if rtype is None:
                self.cur.callproc('bk_core.' + name, list(args), kw)
            else:
                self.fn(name, rtype, *args, **kw)
        self.conn.rollback()
        assert f'BK-{code}' in str(e.value), str(e.value)
        return str(e.value)

    def balance(self, acc):
        return float(self.one('select balance from bk_account where id = :a', a=acc)[0])

    def rule(self, product, acc, op, channel, **kw):
        v = self.fn('set_rule', int, product, acc, op, channel, **{'p_' + k: w for k, w in kw.items()})
        self.conn.commit()
        return v

    def check(self):
        self.cur.execute('select what, ref, detail from bk_check')
        rows = self.cur.fetchall()
        assert rows == [], rows


def afm():
    s = ''.join(random.choice('0123456789') for _ in range(8))
    t = sum(int(c) * 2 ** (8 - i) for i, c in enumerate(s))
    return s + str(t % 11 % 10)


@pytest.fixture(scope='module')
def db():
    conn = oracledb.connect(DSN)
    d = Db(conn)
    if not d.one('select count(*) from bk_product')[0]:
        pytest.skip('INSTALL.sql first')
    if not d.one("select count(*) from bk_product where code = 'TR1'")[0]:
        d.cur.execute("insert into bk_product (code, name, kind, day_basis, cap_every, tax_rate, od_rate) "
                      "values ('TR1', 'Test κανόνες', 'CUR', 'ACT365', 'Q', 15, 0)")
        conn.commit()
    yield d
    conn.rollback()
    conn.close()


def account(db, money=1000, product='TR1'):
    """an account of its own with money in, and rules of its own: none of the bank's (of the demo) left in force
    (the fees off, every op and channel allowed); a test sets what it checks (a rule set again: all of its values
    replaced; a value it leaves null: from a rule of the bank, such as the free ones of the month)"""
    c = db.fn('new_customer', int, 'Test Κανόνες %d' % next(SEQ), afm())
    a = db.fn('open_account', int, product, c, 0)
    for op in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC'):
        db.fn('set_rule', int, None, a, op, '*', p_allowed='Y', p_fee=0)
        for ch in ('BR', 'WEB', 'ATM'):
            db.fn('set_rule', int, None, a, op, ch, p_allowed='Y')
    if money:
        db.fn('deposit', int, a, money)
    db.conn.commit()
    return a


def test_allowed_by_channel(db):
    a = account(db)
    db.rule(None, a, 'WDR', 'ATM', allowed='N')
    t = db.fails(126, 'withdraw', a, 50, p_channel='ATM')
    assert 'ανάληψη από ΑΤΜ' in t
    e = db.fn('withdraw', int, a, 50, p_channel='BR')
    db.conn.commit()
    assert db.one('select channel from bk_entry where id = :e', e=e)[0] == 'BR'
    assert db.one('select op from bk_line where entry_id = :e and account_id = :a', e=e, a=a)[0] == 'WDR'
    db.fails(131, 'withdraw', a, 50, p_channel='XYZ')
    db.fails(131, 'withdraw', a, 50, p_channel=None)
    db.check()


def test_the_most_particular_rule_first(db):
    a = account(db)
    # the product: no transfer to another bank; its account: from the e-banking yes
    db.rule('TR1', None, 'OUT', '*', allowed='N')
    try:
        db.rule(None, a, 'OUT', '*', allowed=None, fee=0)       # (of the account: none for all channels)
        db.rule(None, a, 'OUT', 'BR', allowed=None)
        db.rule(None, a, 'OUT', 'WEB', allowed='Y')
        db.fails(126, 'transfer_out', a, 10, OTHER_IBAN, p_channel='BR')
        db.fn('transfer_out', int, a, 10, OTHER_IBAN, p_channel='WEB')
        db.conn.commit()
        assert db.balance(a) == 990
        assert db.fn('rule_value', int, a, 'OUT', 'BR', 'ALLOWED') == 0
        assert db.fn('rule_value', int, a, 'OUT', 'WEB', 'ALLOWED') == 1
    finally:
        db.cur.execute("delete from bk_rule where product_id = (select id from bk_product where code = 'TR1')")
        db.conn.commit()
    db.check()


def test_the_amount_of_a_movement(db):
    a = account(db)
    db.rule(None, a, 'WDR', 'ATM', min_amount=20, max_amount=300)
    assert 'ως 300,00 €' in db.fails(127, 'withdraw', a, 300.01, p_channel='ATM')
    assert 'από 20,00 €' in db.fails(127, 'withdraw', a, 10, p_channel='ATM')
    db.fn('withdraw', int, a, 300, p_channel='ATM')
    db.fn('withdraw', int, a, 400, p_channel='BR')            # (the limit of the ATM only)
    db.conn.commit()
    assert db.balance(a) == 300
    db.check()


def test_the_limits_of_a_day(db):
    a = account(db, 5000)
    db.rule(None, a, 'OUT', '*', allowed='Y', fee=0, day_amount=500)   # all the channels together
    db.rule(None, a, 'WDR', 'ATM', allowed='Y', day_amount=200)        # the ATM only
    db.rule(None, a, 'TRO', '*', allowed='Y', fee=0, day_count=2)
    db.fn('transfer_out', int, a, 300, OTHER_IBAN, p_channel='BR')
    db.conn.commit()
    t = db.fails(128, 'transfer_out', a, 250, OTHER_IBAN, p_channel='WEB')
    assert 'ημερήσιο' in t and '300,00 €' in t and '500,00 €' in t
    db.fn('transfer_out', int, a, 200, OTHER_IBAN, p_channel='WEB')
    db.conn.commit()
    db.fn('withdraw', int, a, 150, p_channel='ATM')
    db.conn.commit()
    db.fails(128, 'withdraw', a, 60, p_channel='ATM')
    db.fn('withdraw', int, a, 600, p_channel='BR')
    b = account(db, 0)
    db.fn('transfer', int, a, b, 1, p_channel='WEB')
    db.fn('transfer', int, a, b, 1, p_channel='BR')
    db.conn.commit()
    db.fails(128, 'transfer', a, b, 1)
    assert db.fn('rule_used', float, a, 'OUT', 'ATM', 'DAY_AMOUNT') == 500
    assert db.fn('rule_used', float, a, 'WDR', 'ATM', 'DAY_AMOUNT') == 150
    assert db.fn('rule_used', int, a, 'TRO', 'BR', 'DAY_COUNT') == 2
    db.check()


def test_the_limits_of_a_month_and_a_reversal(db):
    a = account(db)
    db.rule(None, a, 'WDR', '*', allowed='Y', month_count=2, month_amount=500)
    e = db.fn('withdraw', int, a, 100)
    db.fn('withdraw', int, a, 100, p_channel='ATM')
    db.conn.commit()
    assert 'μηνιαίο' in db.fails(129, 'withdraw', a, 10)
    db.fn('reverse', int, e)                                   # its movement given back
    db.conn.commit()
    assert db.fn('rule_used', int, a, 'WDR', 'BR', 'MONTH_COUNT') == 1
    db.fails(129, 'withdraw', a, 400.01)
    db.fn('withdraw', int, a, 400)
    db.conn.commit()
    assert db.balance(a) == 500
    db.check()


def test_a_fee_after_the_free_ones(db):
    a = account(db)
    fee0 = float(db.one("select nvl(sum(credit - debit), 0) from bk_line where gl_code = 'FEE'")[0])
    db.rule(None, a, 'WDR', '*', allowed='Y', fee=1.5, free_month=2)
    for _ in range(2):
        db.fn('withdraw', int, a, 100)
    assert db.balance(a) == 800
    e = db.fn('withdraw', int, a, 100)
    db.conn.commit()
    assert db.balance(a) == 698.5
    rows = db.cur.execute('select account_id, gl_code, debit, credit, op from bk_line where entry_id = :e order by id',
                          e=e).fetchall()
    assert [(r[1], float(r[2]), float(r[3]), r[4]) for r in rows] == [
        (None, 100, 0, 'WDR'), ('CASH', 0, 100, None), (None, 1.5, 0, 'FEE'), ('FEE', 0, 1.5, None)]
    assert float(db.one("select sum(credit - debit) from bk_line where gl_code = 'FEE'")[0]) == fee0 + 1.5
    # the money for its fee too
    db.fails(119, 'withdraw', a, 698)
    # a fee without free ones: every time; a reversal gives the fee back
    db.rule(None, a, 'OUT', '*', allowed='Y', fee=3)
    e = db.fn('transfer_out', int, a, 50, OTHER_IBAN)
    db.conn.commit()
    assert db.balance(a) == 645.5
    db.fn('reverse', int, e)
    db.conn.commit()
    assert db.balance(a) == 698.5
    db.check()


def test_the_balance_left(db):
    a = account(db, 500)
    db.rule(None, a, 'WDR', '*', allowed='Y', min_balance=100, fee=2, free_month=0)   # (no free ones)
    t = db.fails(130, 'withdraw', a, 399)
    assert '100,00 €' in t and '400,00 €' in t
    db.fn('withdraw', int, a, 398)
    db.conn.commit()
    assert db.balance(a) == 100
    # a transfer: the rules of both of its accounts
    b = account(db, 0)
    db.rule(None, b, 'TRI', 'WEB', allowed='N')
    db.fails(126, 'transfer', a, b, 10, p_channel='WEB')
    e = db.fn('transfer', int, a, b, 10, p_channel='BR')
    db.conn.commit()
    ops = db.cur.execute('select account_id, op from bk_line where entry_id = :e order by id', e=e).fetchall()
    assert ops == [(a, 'TRO'), (b, 'TRI')]
    db.check()


def test_set_and_remove_a_rule(db):
    a = account(db, 0)
    r = db.rule(None, a, 'DEP', 'ATM', max_amount=1000)
    assert db.rule(None, a, 'DEP', 'ATM', max_amount=2000) == r            # the same keys: replaced
    assert db.fn('rule_value', float, a, 'DEP', 'ATM', 'MAX_AMOUNT') == 2000
    assert db.one("select max_amount, allowed from bk_limits where account_id = :a and op = 'DEP' and channel = 'ATM'",
                  a=a) == (2000, 1)
    db.cur.callproc('bk_core.remove_rule', [r])
    db.conn.commit()
    assert db.fn('rule_value', float, a, 'DEP', 'ATM', 'MAX_AMOUNT') is None
    db.fails(132, 'remove_rule', r, rtype=None)
    db.fails(132, 'set_rule', 'TR1', a, 'DEP', '*')
    db.fails(132, 'set_rule', None, a, 'XXX', '*')
    db.fails(131, 'set_rule', None, a, 'DEP', 'POS')
    db.fails(132, 'set_rule', None, a, 'DEP', '*', p_allowed='X')
    db.fails(132, 'set_rule', None, a, 'DEP', '*', p_fee=-1)
    db.fails(132, 'set_rule', None, a, 'DEP', '*', p_min_amount=10, p_max_amount=5)
    db.fails(132, 'set_rule', None, a, 'DEP', '*', p_day_count=1.5)
    db.fails(110, 'set_rule', 'NOPE', None, 'DEP', '*')
    db.fails(108, 'set_rule', None, -1, 'DEP', '*')
    db.check()
