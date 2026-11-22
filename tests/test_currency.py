"""test_currency.py -- the currencies on a live database (INSTALL.sql first): the base currency and the rates of a
day (the latest on or before it), a conversion at the mid rate and as the customer gets it (less the margin of
the bank), an account in the currency of its product, every line in the currency of its account and in the base
currency, a transfer between two currencies (each currency balanced through the position of the bank, its margin
an income; the amount it was in kept on the entry) and its reversal, the interest of an account in its currency,
a purchase with a card abroad (the fee of conversion), the ATM in the base currency only; BK_CHECK empty.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests

It commits: its own customers, accounts and rates (of the business day and after), and it closes days.
"""
import datetime

import pytest

from test_core import DSN, close_days, customer, db  # noqa: F401  (db: the fixture)

pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set')
DAY = datetime.timedelta(days=1)


@pytest.fixture(scope='module')
def fx(db):
    """USD 1,25 and GBP 0,80 for 1 EUR from the business day on; the products of the tests in EUR and USD"""
    d = db.day()
    db.proc('set_fx_rate', 'USD', d, 1.25)
    db.proc('set_fx_rate', 'GBP', d, 0.80)
    db.proc('set_currencies', 'TS1', 'EUR,USD')
    db.proc('set_currencies', 'TC1', 'EUR,USD,GBP')
    p = db.one("select id from bk_product where code = 'TS1'")[0]
    db.proc('set_rate', p, datetime.date(2020, 1, 1), 0, 2, 'USD')
    for code in ('TS1', 'TC1'):
        for op in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC'):
            db.cur.callfunc('bk_core.set_rule', int, [code, None, op, '*'], {'p_allowed': 'Y', 'p_fee': 0})
    db.conn.commit()
    return db


def acct(db, product='TC1', currency=None, money=0):
    a = db.fn('open_account', int, product, customer(db), 0, None, currency)
    if money:
        db.fn('deposit', int, a, money)
    db.conn.commit()
    return a


def lines(db, e):
    db.cur.execute('select account_id, gl_code, currency, debit, credit, base_debit, base_credit from bk_line '
                   'where entry_id = :e order by id', e=e)
    return [tuple(r) for r in db.cur]


def test_the_rates_and_a_conversion(fx):
    db = fx
    d = db.day()
    assert db.fn('base_currency', str) == 'EUR' and db.fn('fx_rate', float, 'EUR') == 1
    assert db.fn('fx_rate', float, 'USD') == 1.25 and db.fn('fx_rate', float, 'USD', d + 30 * DAY) == 1.25
    # the mid rate; as the customer gets it: 0,5 % less for each currency that is not the base one
    assert db.fn('fx_convert', float, 100, 'EUR', 'USD') == 125
    assert db.fn('fx_convert', float, 100, 'EUR', 'USD', None, 'Y') == round(125 * 0.995, 2)
    assert db.fn('fx_convert', float, 100, 'USD', 'GBP') == 64
    assert db.fn('fx_convert', float, 100, 'USD', 'GBP', None, 'Y') == round(64 * 0.995 * 0.995, 2)
    assert db.fn('fx_convert', float, 1000, 'EUR', 'JPY') == round(1000 * float(db.fn('fx_rate', float, 'JPY')))
    db.fails(152, 'fx_rate', 'XXX', rtype=float)
    db.fails(152, 'set_fx_rate', 'EUR', d, 1, rtype=None)
    db.fails(152, 'set_fx_rate', 'USD', d, 0, rtype=None)
    db.fails(152, 'set_currency', 'US', 'Λάθος', rtype=None)
    db.fails(152, 'set_currencies', 'TC1', 'EUR,XXX', rtype=None)        # (no such currency)
    db.fails(153, 'set_currencies', 'TC1', 'EUR,EUR', rtype=None)


def test_an_account_in_another_currency(fx):
    db = fx
    a = acct(db, 'TC1', 'USD')
    assert db.one('select currency from bk_account where id = :a', a=a)[0] == 'USD'
    assert db.one('select currency from bk_account_v where id = :a', a=a)[0] == 'USD'
    db.fails(153, 'open_account', 'TS1', customer(db), 0, None, 'GBP')
    # the cash in USD; in EUR: / 1,25
    e = db.fn('deposit', int, a, 1000)
    db.conn.commit()
    assert lines(db, e) == [(None, 'CASH', 'USD', 1000, 0, 800, 0), (a, None, 'USD', 0, 1000, 0, 800)]
    assert db.balance(a) == 1000
    db.check()


def test_a_transfer_between_two_currencies(fx):
    db = fx
    a = acct(db, 'TC1', 'EUR', 1000)
    b = acct(db, 'TC1', 'USD')
    e = db.fn('transfer', int, a, b, 100, 'Test συνάλλαγμα')
    db.conn.commit()
    got = round(125 * 0.995, 2)                     # 124,38 USD; the mid 125: 0,62 USD the margin
    assert db.balance(a) == 900 and db.balance(b) == got
    assert lines(db, e) == [(a, None, 'EUR', 100, 0, 100, 0), (None, 'FX_POS', 'EUR', 0, 100, 0, 100),
                            (None, 'FX_POS', 'USD', 125, 0, 100, 0), (b, None, 'USD', 0, got, 0, round(got / 1.25, 2)),
                            (None, 'FX_INC', 'USD', 0, round(125 - got, 2), 0, round((125 - got) / 1.25, 2))]
    assert db.one('select orig_amount, orig_currency, fx_rate from bk_entry where id = :e', e=e) == \
        (100, 'EUR', round(got / 100, 8))
    assert db.one('select orig_currency from bk_statement_line where entry_id = :e and account_id = :b', e=e, b=b)[0] == 'EUR'
    db.check()
    # USD to GBP: both margins; more than there is: in USD
    g = acct(db, 'TC1', 'GBP')
    t = db.fn('transfer', int, b, g, 50)
    db.conn.commit()
    assert db.balance(g) == round(32 * 0.995 * 0.995, 2)
    assert 'διαθέσιμα 74,38 USD' in db.fails(119, 'transfer', b, g, 100)
    # back: each currency to its account, at the rate of today (the same: one day)
    db.fn('reverse', int, t)
    r = db.fn('reverse', int, e)
    db.conn.commit()
    assert db.balance(a) == 1000 and db.balance(b) == 0 and db.balance(g) == 0
    assert sorted((x[2], x[3], x[4]) for x in lines(db, r)) == sorted((x[2], x[4], x[3]) for x in lines(db, e))
    db.check()


def test_the_interest_in_its_currency(fx):
    db = fx
    a = acct(db, 'TS1', 'USD', 3650)
    close_days(db, 2)
    db.proc('accrue', a)
    db.conn.commit()
    db.cur.execute('select rate, interest from bk_accrual where account_id = :a', a=a)
    rows = [tuple(r) for r in db.cur]
    assert rows and {float(r[0]) for r in rows} == {2.0}
    assert float(sum(r[1] for r in rows)) == pytest.approx(2 * round(3650 * 0.02 / 365, 6), abs=1e-9)
    assert db.fn('interest_by_day', float, a, db.day() - 2 * DAY, db.day() - DAY) == pytest.approx(0.4, abs=1e-9)
    db.check()


def test_a_card_abroad_and_the_atm(fx):
    db = fx
    c = db.fn('cc_open', int, 'VISA', customer(db), 1000, 5)
    k = db.fn('new_card', int, c)
    db.conn.commit()
    pct = float(db.one("select fx_fee_pct from bk_cc_product p join bk_product x on x.id = p.product_id "
                       "where x.code = 'VISA'")[0])
    h = db.fn('cc_authorize', int, k, 125, 'Test New York', 'USD')
    db.conn.commit()
    fee = round(100 * pct / 100, 2)
    assert db.one('select amount, orig_amount, orig_currency, fx_fee from bk_cc_auth where id = :h', h=h) == \
        (100 + fee, 125, 'USD', fee)
    e = db.fn('cc_capture', int, h)
    db.conn.commit()
    assert db.balance(c) == -(100 + fee)
    assert [(x[0], x[1], x[3]) for x in lines(db, e)] == [(c, None, 100), (None, 'CC_MERCH', 0), (c, None, fee), (None, 'FEE', 0)]
    assert db.one('select orig_amount, orig_currency, fx_rate from bk_entry where id = :e', e=e) == (125, 'USD', 0.8)
    d = db.day()
    rs = db.cur.execute("select descr from table(bk_report.report_rows('C', :a, :d, :d)) order by seq", a=c, d=d).fetchall()
    assert '(125,00 USD × 0,8)' in rs[0][0] and 'Προμήθεια' in rs[1][0]
    # the same currency: as before
    db.fn('cc_purchase', int, k, 10, 'Test εδώ', 'EUR')
    db.conn.commit()
    assert db.balance(c) == -(110 + fee)
    # the ATM: the base currency only
    u = acct(db, 'TC1', 'USD', 500)
    ku = db.fn('new_card', int, u)
    db.conn.commit()
    db.fails(154, 'atm_withdraw', 'ATM01', ku, 100)
    db.fails(154, 'atm_deposit', 'ATM01', ku, 100)
    db.check()
