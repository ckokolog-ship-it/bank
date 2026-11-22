"""test_locks.py -- two sessions at the same account at the same time (two connections, a thread each): the
balance of the account is never lost (a deposit waits for a withdrawal not committed yet, and adds to what it
left), the limits of a day are never passed by two movements at once, two transfers in opposite directions
end without a deadlock, a movement is reversed only once.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests
"""
import threading
import time

import pytest

import test_rules
from test_rules import DSN, Db, afm, account  # noqa: F401

oracledb = pytest.importorskip('oracledb')
pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set')


db = test_rules.db                                          # (the fixture of test_rules: its product TR1, its accounts)


def later(fn):
    """fn in a thread of its own, on a connection of its own: (the thread, its result: value or error)"""
    out = {}

    def run():
        c = oracledb.connect(DSN)
        try:
            out['value'] = fn(c)
            c.commit()
        except oracledb.DatabaseError as e:
            out['error'] = str(e)
            c.rollback()
        finally:
            c.close()
    t = threading.Thread(target=run)
    t.start()
    return t, out


def waits(t):
    """the thread still waiting (on a lock) after a while"""
    time.sleep(1.0)
    return t.is_alive()


def test_a_deposit_waits_for_a_withdrawal(db):
    a = account(db, 1000)
    e = db.fn('withdraw', int, a, 300)                      # not committed yet
    t, out = later(lambda c: c.cursor().callfunc('bk_core.deposit', int, [a, 50]))
    assert waits(t)                                         # the row of the account: locked by the withdrawal
    db.conn.commit()
    t.join(30)
    assert 'error' not in out, out
    assert db.balance(a) == 750 and e
    db.check()


def test_two_withdrawals_within_the_balance(db):
    a = account(db, 100)
    db.fn('withdraw', int, a, 80)
    t, out = later(lambda c: c.cursor().callfunc('bk_core.withdraw', int, [a, 80]))
    assert waits(t)
    db.conn.commit()
    t.join(30)
    assert 'BK-119' in out.get('error', ''), out            # it saw the 20 left, not the 100 of before
    assert db.balance(a) == 20
    db.check()


def test_the_limit_of_a_day_at_once(db):
    a = account(db, 1000)
    db.rule(None, a, 'WDR', 'ATM', allowed='Y', day_amount=500)
    db.fn('withdraw', int, a, 300, p_channel='ATM')
    t, out = later(lambda c: c.cursor().callfunc('bk_core.withdraw', int, [a, 300], {'p_channel': 'ATM'}))
    assert waits(t)
    db.conn.commit()
    t.join(30)
    assert 'BK-128' in out.get('error', ''), out            # 300 + 300 > 500 a day
    assert db.balance(a) == 700
    db.check()


def test_transfers_in_opposite_directions(db):
    a = account(db, 500)
    b = account(db, 500)
    db.fn('transfer', int, a, b, 100)
    t, out = later(lambda c: c.cursor().callfunc('bk_core.transfer', int, [b, a, 40]))
    assert waits(t)
    db.conn.commit()
    t.join(30)
    assert 'error' not in out, out
    assert (db.balance(a), db.balance(b)) == (440, 560)
    db.check()


def test_a_reversal_only_once(db):
    a = account(db, 500)
    e = db.fn('withdraw', int, a, 100)
    db.conn.commit()
    db.fn('reverse', int, e)
    t, out = later(lambda c: c.cursor().callfunc('bk_core.reverse', int, [e]))
    assert waits(t)
    db.conn.commit()
    t.join(30)
    assert 'BK-123' in out.get('error', ''), out            # not ORA-00001: the entry locked, then seen reversed
    assert db.balance(a) == 500
    db.check()
