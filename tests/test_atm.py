"""test_atm.py -- the debit cards and the ATM on a live database: the cards in BK_CORE (the Luhn check digit, of
a holder, blocked, expired, cancelled), then the ATM as its page asks it (/api/atm/, bk-api.jar started by
test_api's fixture): the PIN (3 wrong: locked; a new one at the counter), the balance, a withdrawal (in tens,
its notes, the cash of the ATM, the rules of the channel ATM), a deposit, a transfer, the last moves, a new PIN,
the end of the session; the cards at the counter (blocked by a teller, again active or cancelled by a manager).

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests
"""
import datetime

import pytest

from test_api import DSN, base, call, conn, ok, open_account, tok  # noqa: F401  (the fixtures of the jar)

oracledb = pytest.importorskip('oracledb')
pytestmark = pytest.mark.skipif(not DSN, reason='BANK_DSN not set')


def new_card(base, acc):
    """a card of the account at the counter: (its PAN, its PIN)"""
    r = ok(base, '/api/accounts/%d/cards' % acc['id'], {})
    assert len(r['pin']) == 4 and r['status'] == 'A' and r['has_pin'] == 'Y'
    return r


def atm(base, code, what, body=None, token=None):
    return call(base, '/api/atm/%s/%s' % (code, what), {} if body is None else body, token)


def login(base, card, code='ATM01', pin=None):
    s, r = atm(base, code, 'login', {'pan': card['pan'], 'pin': pin or card['pin']})
    assert s == 200, r
    return r['token']


def test_cards_in_the_database(conn):
    cur = conn.cursor()
    assert cur.callfunc('bk_core.luhn_ok', str, ['4539578763621486']) == 'Y'
    assert cur.callfunc('bk_core.luhn_ok', str, ['4539578763621487']) == 'N'
    acc = cur.execute("select a.id from bk_account a where a.status = 'O' fetch first 1 rows only").fetchone()[0]
    k = cur.callfunc('bk_core.new_card', int, [acc])
    pan, expires = cur.execute('select pan, expires from bk_card where id = :k', k=k).fetchone()
    day = cur.execute('select bk_core.open_day from dual').fetchone()[0]
    assert len(pan) == 16 and pan.startswith('4999') and cur.callfunc('bk_core.luhn_ok', str, [pan]) == 'Y'
    assert expires.month == ((day.month - 1) % 12) + 1 and expires.year == day.year + 4
    assert cur.callfunc('bk_core.card_account', int, [k]) == acc
    other = cur.execute('select max(id) from bk_customer where id not in (select customer_id from bk_holder '
                        'where account_id = :a)', a=acc).fetchone()[0]
    for code, args, name in ((136, [acc, other], 'new_card'), (133, [-1], 'card_account')):
        with pytest.raises(oracledb.DatabaseError, match='BK-%d' % code):
            cur.callfunc('bk_core.' + name, int, args)
    with pytest.raises(oracledb.DatabaseError, match='BK-134'):
        cur.callproc('bk_core.set_card_status', [k, 'X'])
    cur.callproc('bk_core.set_card_status', [k, 'B'])
    with pytest.raises(oracledb.DatabaseError, match='BK-134'):
        cur.callfunc('bk_core.card_account', int, [k])
    cur.callproc('bk_core.set_card_status', [k, 'A'])
    cur.execute('update bk_card set expires = :d where id = :k', d=day - datetime.timedelta(days=1), k=k)
    with pytest.raises(oracledb.DatabaseError, match='BK-135'):
        cur.callfunc('bk_core.card_account', int, [k])
    cur.callproc('bk_core.set_card_status', [k, 'C'])
    with pytest.raises(oracledb.DatabaseError, match='BK-134'):
        cur.callproc('bk_core.set_card_status', [k, 'A'])
    with pytest.raises(oracledb.DatabaseError, match='BK-138'):
        cur.callproc('bk_core.atm_cash', ['ATM01', 15])
    with pytest.raises(oracledb.DatabaseError, match='BK-137'):
        cur.callproc('bk_core.atm_cash', ['NOPE', 10])
    conn.rollback()


def test_the_pin(base):
    a = open_account(base, 100)
    card = new_card(base, a)
    wrong = '0000' if card['pin'] != '0000' else '1111'
    s, r = atm(base, 'ATM01', 'login', {'pan': card['pan'], 'pin': wrong})
    assert s == 401 and r['error'] == 'bad_pin' and '2 προσπάθειες' in r['message']
    s, r = atm(base, 'ATM01', 'login', {'pan': card['pan'], 'pin': wrong})
    assert s == 401 and 'απομένει 1' in r['message']
    login(base, card)                                       # right: the count from 0 again
    for _ in range(2):
        atm(base, 'ATM01', 'login', {'pan': card['pan'], 'pin': wrong})
    s, r = atm(base, 'ATM01', 'login', {'pan': card['pan'], 'pin': wrong})
    assert s == 423 and r['error'] == 'pin_locked'
    s, r = atm(base, 'ATM01', 'login', {'pan': card['pan'], 'pin': card['pin']})
    assert s == 423                                         # the right one too: locked
    c = [x for x in ok(base, '/api/accounts/%d/cards' % a['id']) if x['id'] == card['id']][0]
    assert c['pin_locked'] == 'Y'
    fresh = ok(base, '/api/cards/%d/pin' % card['id'], {})  # a new PIN at the counter: unlocked
    assert fresh['pin_locked'] == 'N'
    login(base, fresh)
    s, r = atm(base, 'ATM01', 'login', {'pan': '4999000000000000', 'pin': '5678'})
    assert s == 401 and r['error'] == 'bad_card'
    s, r = atm(base, 'NOPE', 'login', {'pan': card['pan'], 'pin': fresh['pin']})
    assert s == 400 and r['error'] == 'BK-137'


def test_a_withdrawal(base):
    a = open_account(base, 1000)
    card = new_card(base, a)
    t = login(base, card)
    cash = {m['code']: m['cash'] for m in ok(base, '/api/atms')}
    s, r = atm(base, 'ATM01', 'balance', token=t)
    assert s == 200 and r['balance'] == 1000 and r['iban'].endswith(a['iban'][-4:])
    assert r['withdraw_today'] in (600, 1000)                # (the demo: 600 a day from an ATM, a rule of the bank)
    s, r = atm(base, 'ATM01', 'withdraw', {'amount': 35}, t)
    assert s == 400 and r['error'] == 'BK-138'
    s, r = atm(base, 'ATM01', 'withdraw', {'amount': 120}, t)
    assert s == 200 and r['notes'] == {'50': 2, '20': 1} and r['balance'] == 880 and r['fee'] == 0
    e = ok(base, '/api/entries/%d' % r['entry_id'])
    assert e['channel'] == 'ATM' and e['created_by'] == 'ATM01' and e['kind'] == 'WDR'
    assert {m['code']: m['cash'] for m in ok(base, '/api/atms')}['ATM01'] == cash['ATM01'] - 120
    # the rules of the channel ATM: of this account, at most 100 at a time, 150 a day
    ok(base, '/api/rules', {'account_id': a['id'], 'op': 'WDR', 'channel': 'ATM', 'allowed': 'Y', 'max_amount': 100,
                            'day_amount': 150}, 'tst-manager')
    s, r = atm(base, 'ATM01', 'balance', token=t)
    assert r['withdraw_today'] == 30                         # 150 a day, 120 taken
    s, r = atm(base, 'ATM01', 'withdraw', {'amount': 110}, t)
    assert s == 400 and r['error'] == 'BK-127'
    s, r = atm(base, 'ATM01', 'withdraw', {'amount': 40}, t)
    assert s == 400 and r['error'] == 'BK-128'
    # an ATM with little cash: what it has
    ok(base, '/api/rules', {'account_id': a['id'], 'op': 'WDR', 'channel': 'ATM', 'allowed': 'Y'}, 'tst-manager')
    left = cash['ATM02'] - 100
    ok(base, '/api/atms/ATM02/cash', {'amount': -left}, 'tst-manager')
    try:
        t2 = login(base, card, 'ATM02')
        s, r = atm(base, 'ATM02', 'withdraw', {'amount': 200}, t2)
        assert s == 400 and r['error'] == 'BK-139' and '100,00' in r['message']
        assert atm(base, 'ATM02', 'withdraw', {'amount': 100}, t2)[0] == 200
        assert atm(base, 'ATM01', 'balance', token=t2)[0] == 401     # a session of another ATM
    finally:
        ok(base, '/api/atms/ATM02/cash', {'amount': left + 100}, 'tst-manager')
    assert ok(base, '/api/check') == []


def test_deposit_transfer_statement_new_pin(base):
    a = open_account(base, 200)
    b = open_account(base)
    card = new_card(base, a)
    t = login(base, card, 'ATM03')
    s, r = atm(base, 'ATM03', 'deposit', {'amount': 52}, t)
    assert s == 400 and r['error'] == 'BK-138'
    s, r = atm(base, 'ATM03', 'deposit', {'amount': 55}, t)
    assert s == 200 and r['balance'] == 255
    s, r = atm(base, 'ATM03', 'transfer', {'iban': b['iban'], 'amount': 30}, t)
    assert s == 200 and r['balance'] == 225
    assert ok(base, '/api/accounts/%d' % b['id'])['balance'] == 30
    s, r = atm(base, 'ATM03', 'transfer', {'iban': 'GR0000000000000000000000000', 'amount': 1}, t)
    assert s == 400 and r['error'] == 'BK-121'
    s, r = atm(base, 'ATM03', 'statement', token=t)
    assert s == 200 and r['balance'] == 225 and [x['amount'] for x in r['rows']][:3] == [-30, 55, 200]
    assert atm(base, 'ATM03', 'pin', {'pin': '1111'}, t)[1]['error'] == 'bad_pin'
    assert atm(base, 'ATM03', 'pin', {'pin': '4827'}, t)[0] == 200
    assert atm(base, 'ATM03', 'end', token=t)[0] == 200
    assert atm(base, 'ATM03', 'balance', token=t)[0] == 401
    assert atm(base, 'ATM03', 'login', {'pan': card['pan'], 'pin': card['pin']})[0] == 401
    login(base, card, 'ATM03', '4827')


def test_cards_at_the_counter(base):
    a = open_account(base, 50)
    card = new_card(base, a)
    k = ok(base, '/api/cards/%d/status' % card['id'], {'status': 'B'})            # a teller blocks it
    assert k['status'] == 'B'
    s, r = atm(base, 'ATM01', 'login', {'pan': card['pan'], 'pin': card['pin']})
    assert s == 400 and r['error'] == 'BK-134'
    assert call(base, '/api/cards/%d/status' % card['id'], {'status': 'A'}, tok(base, 'tst-teller'))[0] == 403
    ok(base, '/api/cards/%d/status' % card['id'], {'status': 'A'}, 'tst-manager')
    login(base, card)
    ok(base, '/api/cards/%d/status' % card['id'], {'status': 'C'}, 'tst-manager')
    s, r = call(base, '/api/cards/%d/pin' % card['id'], {}, tok(base, 'tst-teller'))
    assert s == 400 and r['error'] == 'BK-134'
    assert call(base, '/api/atms/ATM01/cash', {'amount': 100}, tok(base, 'tst-teller'))[0] == 403


def test_the_page_of_the_atm(base):
    s, hd, b = call(base, '/atm/', raw=True)
    assert s == 200 and b'atm.js' in b and "script-src 'self'" in hd['Content-Security-Policy']
    assert call(base, '/atm/atm.js', raw=True)[0] == 200
    assert call(base, '/atm/app.js', raw=True)[0] == 404
    assert call(base, '/web/atm.js', raw=True)[0] == 404
    assert [m['code'] for m in call(base, '/api/atm/')[1]][:3] == ['ATM01', 'ATM02', 'ATM03']


def test_a_pin_to_many_cards(base, conn):
    cur = conn.cursor()
    acc = cur.execute("select id from bk_account where status = 'O' order by id fetch first 1 rows only").fetchone()[0]
    k = cur.callfunc('bk_core.new_card', int, [acc])               # a card without a PIN, as those of the demo
    conn.commit()
    pan = cur.execute('select pan from bk_card where id = :k', k=k).fetchone()[0]
    assert atm(base, 'ATM01', 'login', {'pan': pan, 'pin': '4827'})[1]['error'] == 'no_pin'
    assert call(base, '/api/cards/pins', {'pin': '4827'}, tok(base, 'tst-teller'))[0] == 403
    s, r = call(base, '/api/cards/pins', {'pin': '1111'}, tok(base, 'tst-manager'))
    assert s == 400 and r['error'] == 'bad_pin'
    rows = ok(base, '/api/cards/pins', {'pin': '4827'}, 'tst-manager')
    assert k in [x['id'] for x in rows] and all(x['pin'] == '4827' for x in rows)
    assert cur.execute('select count(*) from bk_card where pin_hash is null and status = \'A\'').fetchone()[0] == 0
    login(base, {'pan': pan, 'pin': '4827'})
    assert ok(base, '/api/cards/pins', {}, 'tst-manager') == []      # none without a PIN now
    rows = ok(base, '/api/cards/pins', {'all': True}, 'tst-manager')  # every card: a new one each
    mine = [x for x in rows if x['id'] == k][0]
    assert len(mine['pin']) == 4
    login(base, {'pan': pan, 'pin': mine['pin']})
