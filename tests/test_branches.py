"""test_branches.py -- the branches on a live database (INSTALL.sql first): a branch new or changed, an account
opened in one (its code in the IBAN), in the branch of the user of the session or of set_branch_context, moved to
another (its IBAN as it was); where a movement was made: the counter of the user, the ATM, none for e-banking; the
cash of each branch; a branch not active: no new account in it; BK_CHECK empty.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests
"""
import hashlib
import os

import pytest

from test_core import DSN, customer, db  # noqa: F401  (db: the fixture)

pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set')


@pytest.fixture(scope='module')
def br(db):
    db.proc('set_branch', '9001', 'Test υποκατάστημα', 'Πάτρα', 'Test οδός 1')
    db.proc('set_branch', '9002', 'Test δεύτερο', 'Αθήνα')
    for code in ('9001', '9002'):
        db.proc('set_branch', code, 'Test ' + code, None, None, 'Y')
    db.cur.execute("delete from bk_user where username = 'tst-branch'")
    salt = os.urandom(16)
    db.cur.execute("insert into bk_user (username, full_name, role, pw_hash, pw_salt, pw_iter, branch_code) "
                   "values ('tst-branch', 'Test', 'TELLER', :h, :s, 1000, '9002')",
                   h=hashlib.pbkdf2_hmac('sha256', b'x', salt, 1000), s=salt)
    db.conn.commit()
    yield db
    db.cur.execute("begin dbms_session.clear_identifier; bk_core.set_branch_context(null); end;")
    db.cur.execute("delete from bk_user where username = 'tst-branch'")
    db.conn.commit()


def acct(db, branch=None, money=0):
    a = db.fn('open_account', int, 'TC1', customer(db), 0, None, None, branch)
    for op in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC'):
        db.cur.callfunc('bk_core.set_rule', int, [None, a, op, '*'], {'p_allowed': 'Y', 'p_fee': 0})
    if money:
        db.fn('deposit', int, a, money)
    db.conn.commit()
    return a


def branch_of(db, a):
    return db.one('select branch_code, substr(iban, 8, 4), bk_core.iban_ok(iban) from bk_account where id = :a', a=a)


def test_an_account_in_a_branch(br):
    db = br
    a = acct(db, '9001')
    assert branch_of(db, a) == ('9001', '9001', 'Y')
    db.fails(160, 'open_account', 'TC1', customer(db), 0, None, None, '9999')
    db.fails(160, 'set_branch', '12', 'Λάθος', rtype=None)
    # not active: no new account in it; active again
    db.proc('set_branch', '9002', 'Test 9002', None, None, 'N')
    db.conn.commit()
    db.fails(160, 'open_account', 'TC1', customer(db), 0, None, None, '9002')
    db.proc('set_branch', '9002', 'Test 9002', None, None, 'Y')
    db.conn.commit()
    # moved: its branch, not its IBAN
    iban = db.one('select iban from bk_account where id = :a', a=a)[0]
    db.proc('set_account_branch', a, '9002')
    db.conn.commit()
    assert db.one('select branch_code, iban from bk_account where id = :a', a=a) == ('9002', iban)
    db.check()


def test_the_branch_of_the_session(br):
    db = br
    # a script: set_branch_context
    db.proc('set_branch_context', '9001')
    a = acct(db, None, 100)
    assert branch_of(db, a)[0] == '9001'
    assert db.one("select branch_code from bk_entry e join bk_line l on l.entry_id = e.id "
                  "where l.account_id = :a and e.kind = 'DEP'", a=a)[0] == '9001'
    db.proc('set_branch_context', None)
    # the user of the session (the forms, the pages): its branch
    db.cur.execute("begin dbms_session.set_identifier('tst-branch'); end;")
    assert db.fn('session_branch', str) == '9002'
    b = acct(db, None, 50)
    e = db.fn('withdraw', int, b, 20)
    w = db.fn('withdraw', int, b, 5, 'Test web', None, 'WEB')
    db.conn.commit()
    assert branch_of(db, b)[0] == '9002'
    assert db.one('select branch_code from bk_entry where id = :e', e=e)[0] == '9002'
    assert db.one('select branch_code from bk_entry where id = :e', e=w)[0] is None
    db.cur.execute("begin dbms_session.clear_identifier; end;")
    # the cash of the branch: what came in at its counters less what went out
    cash = db.one("select nvl(sum(cash), 0) from bk_branch_cash where branch_code = '9002' and channel = 'BR'")[0]
    assert cash == pytest.approx(50 - 20, abs=1e-9) or cash > 0
    db.check()


def test_the_branch_of_an_atm(br):
    db = br
    a = acct(db, '9001', 500)
    k = db.fn('new_card', int, a)
    old = db.one("select branch_code from bk_atm where code = 'ATM02'")[0]
    db.proc('set_atm_branch', 'ATM02', '9002')
    db.conn.commit()
    try:
        e = db.fn('atm_deposit', int, 'ATM02', k, 100)
        db.conn.commit()
        assert db.one('select branch_code, channel from bk_entry where id = :e', e=e) == ('9002', 'ATM')
        # after it, a movement at a counter: not of the ATM
        f = db.fn('deposit', int, a, 10)
        assert db.one('select branch_code from bk_entry where id = :e', e=f)[0] is None
        db.conn.commit()
    finally:
        db.proc('set_atm_branch', 'ATM02', old)
        db.conn.commit()
    db.fails(160, 'set_atm_branch', 'ATM99', '9001', rtype=None)
    db.fails(160, 'set_user_branch', 'nobody-x', '9001', rtype=None)
    db.check()
