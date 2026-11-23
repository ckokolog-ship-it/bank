"""test_api.py -- the REST service and the pages (api/, bk-api.jar) on a live database: it starts the jar on a
free port of this computer, with BANK_DSN, and asks it as the pages do: a login first (its users: tst-teller,
tst-manager, tst-admin, made here), then each call with its token. The roles; a lock after 5 wrong passwords;
customers, accounts, movements, a statement, a reversal, the rules and the limits, the rates, the close of a
day, the users; the pages themselves.

    (cd api && ./mvnw -q -B package)      the jar (else the tests build it)
    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests

Without BANK_DSN, java or the jar, the tests are skipped. It commits: its own users, customers (Test ...),
accounts (of its product TA1), and it closes a day.
"""
import hashlib
import json
import os
import random
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request

import pytest

oracledb = pytest.importorskip('oracledb')
DSN = os.environ.get('BANK_DSN')
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
JAR = os.path.join(ROOT, 'api', 'target', 'bk-api.jar')
pytestmark = pytest.mark.skipif(not DSN or not shutil.which('java'), reason='BANK_DSN or java missing')
NO_PROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))
PW = 'Kodikos-2026'
OTHER_IBAN = 'GR1601101250000000012300695'


def afm():
    s = ''.join(random.choice('0123456789') for _ in range(8))
    return s + str(sum(int(c) * 2 ** (8 - i) for i, c in enumerate(s)) % 11 % 10)


@pytest.fixture(scope='module')
def conn():
    c = oracledb.connect(DSN)
    cur = c.cursor()
    if not cur.execute('select count(*) from bk_product').fetchone()[0]:
        pytest.skip('INSTALL.sql first')
    if not cur.execute("select count(*) from bk_setting where name = 'START_DAY'").fetchone()[0]:
        cur.callproc('bk_core.set_start', [__import__('datetime').date.today()])
    if not cur.execute("select count(*) from bk_product where code = 'TA1'").fetchone()[0]:
        cur.execute("insert into bk_product (code, name, kind, day_basis, cap_every, tax_rate, od_rate) "
                    "values ('TA1', 'Test api', 'CUR', 'ACT365', 'Q', 15, 10)")
        pid = cur.execute("select id from bk_product where code = 'TA1'").fetchone()[0]
        cur.callproc('bk_core.set_rate', [pid, __import__('datetime').date(2020, 1, 1), 0, 1])
    # the users of the tests, their password as bk-api keeps it (PBKDF2-SHA256; few iterations: fast)
    cur.execute("delete from bk_user where username like 'tst-%'")
    for name, role in (('tst-teller', 'TELLER'), ('tst-manager', 'MANAGER'), ('tst-admin', 'ADMIN'), ('tst-lock', 'TELLER')):
        salt = os.urandom(16)
        cur.execute('insert into bk_user (username, full_name, role, pw_hash, pw_salt, pw_iter) values (:u, :f, :r, :h, :s, 1000)',
                    u=name, f='Test ' + name, r=role, h=hashlib.pbkdf2_hmac('sha256', PW.encode(), salt, 1000), s=salt)
    c.commit()
    TOKENS.clear()                          # (their sessions gone with them: a module of tests after another)
    yield c
    c.close()


@pytest.fixture(scope='module')
def base(conn):
    if not os.path.exists(JAR):
        subprocess.run(['./mvnw', '-q', '-B', 'package', '-DskipTests'], cwd=os.path.join(ROOT, 'api'), check=True)
    user, rest = DSN.split('/', 1)
    pw, where = rest.rsplit('@', 1)
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    e = dict(os.environ, BK_DB_URL='jdbc:oracle:thin:@' + where, BK_DB_USER=user, BK_DB_PASSWORD=pw,
             BK_API_PORT=str(port), BK_API_BIND='127.0.0.1')
    p = subprocess.Popen(['java', '-jar', JAR], env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    url = 'http://127.0.0.1:%d' % port
    try:
        for _ in range(60):
            try:
                NO_PROXY.open(url + '/api/health', timeout=2).read()
                break
            except (urllib.error.URLError, ConnectionError):
                if p.poll() is not None:
                    pytest.fail('bk-api stopped: ' + p.stdout.read().decode(errors='replace'))
                time.sleep(0.5)
        yield url
    finally:
        p.terminate()                       # by its own handle (its PID), nothing else
        p.wait(timeout=20)


def call(base, path, body=None, token=None, raw=False):
    """(status, JSON) of a call"""
    req = urllib.request.Request(base + path, method='GET' if body is None else 'POST',
                                 data=None if body is None else json.dumps(body).encode())
    if body is not None:
        req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    try:
        with NO_PROXY.open(req, timeout=30) as r:
            data = r.read()
            return (r.status, r.headers, data) if raw else (r.status, json.loads(data))
    except urllib.error.HTTPError as e:
        data = e.read()
        return (e.code, e.headers, data) if raw else (e.code, json.loads(data or b'{}'))


TOKENS = {}


def tok(base, name):
    if name not in TOKENS:
        s, r = call(base, '/api/auth/login', {'username': name, 'password': PW})
        assert s == 200, r
        TOKENS[name] = r['token']
    return TOKENS[name]


def ok(base, path, body=None, who='tst-teller'):
    s, r = call(base, path, body, tok(base, who))
    assert s == 200, (path, s, r)
    return r


def open_account(base, money=0):
    c = ok(base, '/api/customers', {'name': 'Test Ψάρης %d' % random.randrange(10 ** 6), 'afm': afm()})
    a = ok(base, '/api/accounts', {'product': 'TA1', 'customer_id': c['id']})
    # none of the rules of the bank (of the demo) on it: everything allowed, no fee
    for op in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC'):
        ok(base, '/api/rules', {'account_id': a['id'], 'op': op, 'channel': '*', 'allowed': 'Y', 'fee': 0}, 'tst-manager')
    if money:
        ok(base, '/api/movements', {'kind': 'DEP', 'account_id': a['id'], 'amount': money})
    return a


def test_login_and_roles(base):
    s, r = call(base, '/api/health')
    assert s == 200 and r['status'] == 'ok'
    assert call(base, '/api/auth/login', {'username': 'tst-teller', 'password': 'wrong'})[0] == 401
    assert call(base, '/api/auth/login', {'username': 'nobody', 'password': 'wrong'})[0] == 401
    assert call(base, '/api/customers')[0] == 401
    assert call(base, '/api/customers', token='not-a-token')[0] == 401
    assert ok(base, '/api/auth/me')['role'] == 'TELLER'
    assert call(base, '/api/users', token=tok(base, 'tst-teller'))[0] == 403
    assert call(base, '/api/users', token=tok(base, 'tst-manager'))[0] == 403
    assert any(u['username'] == 'tst-admin' for u in ok(base, '/api/users', who='tst-admin'))
    # a logout: its token no more
    s, r = call(base, '/api/auth/login', {'username': 'tst-teller', 'password': PW})
    t = r['token']
    assert call(base, '/api/auth/logout', {}, t)[0] == 200
    assert call(base, '/api/auth/me', token=t)[0] == 401


def test_locked_after_five_wrong(base):
    for _ in range(5):
        assert call(base, '/api/auth/login', {'username': 'tst-lock', 'password': 'wrong'})[0] == 401
    s, r = call(base, '/api/auth/login', {'username': 'tst-lock', 'password': PW})
    assert s == 423, r
    u = [x for x in ok(base, '/api/users', who='tst-admin') if x['username'] == 'tst-lock'][0]
    assert u['locked'] == 'Y'
    ok(base, '/api/users/%d' % u['id'], {'unlock': True}, 'tst-admin')
    assert call(base, '/api/auth/login', {'username': 'tst-lock', 'password': PW})[0] == 200


def test_customers(base):
    a = afm()
    c = ok(base, '/api/customers', {'name': 'Test Ελένη Παπαδοπούλου', 'afm': a, 'email': 'e@example.com',
                                    'birth_date': '1980-05-17'})
    assert c['code'].startswith('C') and c['birth_date'] == '1980-05-17' and c['accounts'] == []
    r = ok(base, '/api/customers?q=' + urllib.request.quote('ελενη παπαδοπουλου'))      # without the accents
    assert any(x['id'] == c['id'] for x in r['rows'])
    assert ok(base, '/api/customers?q=' + a)['rows'][0]['id'] == c['id']
    c2 = ok(base, '/api/customers/%d' % c['id'], {'phone': '6900000000'})
    assert c2['phone'] == '6900000000' and c2['email'] == 'e@example.com' and c2['afm'] == a
    s, r = call(base, '/api/customers', {'name': 'Test x', 'afm': '123456789'}, tok(base, 'tst-teller'))
    assert s == 400 and r['error'] == 'BK-104' and 'ΑΦΜ' in r['message']
    s, r = call(base, '/api/customers', {'name': 'Test x', 'afm': a}, tok(base, 'tst-teller'))
    assert s == 400 and r['error'] == 'BK-106'
    assert call(base, '/api/customers/999999999', token=tok(base, 'tst-teller'))[0] == 404


def test_movements_statement_and_a_reversal(base):
    a = open_account(base)
    b = open_account(base)
    assert a['iban'].startswith('GR') and a['status'] == 'O'
    mv = lambda **k: ok(base, '/api/movements', dict(k, account_id=a['id']))
    e = mv(kind='DEP', amount=1000, descr='Test κατάθεση')
    assert e['created_by'] == 'tst-teller' and e['channel'] == 'BR' and e['balance'] == 1000
    assert [(l['gl_code'], l['debit'], l['credit']) for l in e['lines']] == [('CASH', 1000, 0), (None, 0, 1000)]
    mv(kind='WDR', amount=200, channel='ATM')
    mv(kind='TRF', amount=100, to_account=b['iban'][:4] + ' ' + b['iban'][4:])        # its IBAN, with a space
    mv(kind='OUT', amount=50, iban=OTHER_IBAN)
    last = mv(kind='INC', amount=25.5, iban=OTHER_IBAN)
    assert last['balance'] == 675.5
    assert ok(base, '/api/accounts/%d' % b['id'])['balance'] == 100
    s, r = call(base, '/api/movements', {'kind': 'WDR', 'account_id': a['id'], 'amount': 10000}, tok(base, 'tst-teller'))
    assert s == 400 and r['error'] == 'BK-119'
    s, r = call(base, '/api/movements', {'kind': 'OUT', 'account_id': a['id'], 'amount': 1, 'iban': 'GR00'}, tok(base, 'tst-teller'))
    assert s == 400 and r['error'] == 'BK-121'
    st = ok(base, '/api/accounts/%d/statement' % a['id'])
    assert st['carry_in'] == 0 and st['carry_out'] == 675.5 and len(st['rows']) == 5
    assert st['rows'][1]['channel'] == 'ATM' and st['rows'][-1]['balance'] == 675.5
    assert st['debit'] == 350 and st['credit'] == 1025.5
    # a reversal: of a MANAGER only
    s, r = call(base, '/api/entries/%d/reverse' % e['id'], {}, tok(base, 'tst-teller'))
    assert s == 403
    s, r = call(base, '/api/entries/%d/reverse' % e['id'], {}, tok(base, 'tst-manager'))
    assert s == 400 and r['error'] == 'BK-119'                       # the money is not there any more
    rev = ok(base, '/api/entries/%d/reverse' % last['id'], {'descr': 'Test λάθος'}, 'tst-manager')
    assert rev['kind'] == 'REV' and rev['reversal_of'] == last['id'] and rev['created_by'] == 'tst-manager'
    assert ok(base, '/api/entries/%d' % last['id'])['reversed_by'] == rev['id']
    assert ok(base, '/api/accounts/%d' % a['id'])['balance'] == 650
    assert ok(base, '/api/check') == []


def test_account_status_holders_and_close(base):
    a = open_account(base, 10)
    c = ok(base, '/api/customers', {'name': 'Test Συνδικαιούχος', 'afm': afm()})
    x = ok(base, '/api/accounts/%d/holders' % a['id'], {'customer_id': c['id']})
    assert [h['role'] for h in x['holders']] == ['P', 'J']
    assert ok(base, '/api/customers/%d' % c['id'])['accounts'][0]['role'] == 'J'
    x = ok(base, '/api/accounts/%d/holders/%d/remove' % (a['id'], c['id']), {})
    assert len(x['holders']) == 1
    assert call(base, '/api/accounts/%d/status' % a['id'], {'status': 'B'}, tok(base, 'tst-teller'))[0] == 403
    assert ok(base, '/api/accounts/%d/status' % a['id'], {'status': 'B'}, 'tst-manager')['status'] == 'B'
    s, r = call(base, '/api/movements', {'kind': 'WDR', 'account_id': a['id'], 'amount': 1}, tok(base, 'tst-teller'))
    assert s == 400 and r['error'] == 'BK-118'
    ok(base, '/api/accounts/%d/status' % a['id'], {'status': 'O'}, 'tst-manager')
    assert ok(base, '/api/accounts/%d/od-limit' % a['id'], {'od_limit': 300}, 'tst-manager')['available'] == 310
    s, r = call(base, '/api/accounts/%d/close' % a['id'], {}, tok(base, 'tst-manager'))
    assert s == 400 and r['error'] == 'BK-125'
    ok(base, '/api/movements', {'kind': 'WDR', 'account_id': a['id'], 'amount': 10})
    assert ok(base, '/api/accounts/%d/close' % a['id'], {}, 'tst-manager')['status'] == 'C'
    r = ok(base, '/api/accounts?status=C&q=' + a['iban'])
    assert r['total'] == 1 and r['rows'][0]['id'] == a['id']


def test_rules_and_limits(base):
    a = open_account(base, 1000)
    assert call(base, '/api/rules', {'account_id': a['id'], 'op': 'WDR', 'channel': 'ATM', 'allowed': 'N'},
                tok(base, 'tst-teller'))[0] == 403
    r = ok(base, '/api/rules', {'account_id': a['id'], 'op': 'WDR', 'channel': 'ATM', 'allowed': 'N'}, 'tst-manager')
    assert r['lvl'] == 'ACCOUNT' and r['iban'] == a['iban']
    s, e = call(base, '/api/movements', {'kind': 'WDR', 'account_id': a['id'], 'amount': 20, 'channel': 'ATM'},
                tok(base, 'tst-teller'))
    assert s == 400 and e['error'] == 'BK-126' and 'ΑΤΜ' in e['message']
    ok(base, '/api/rules', {'account_id': a['id'], 'op': 'WDR', 'channel': 'BR', 'allowed': 'Y', 'day_amount': 300}, 'tst-manager')
    ok(base, '/api/movements', {'kind': 'WDR', 'account_id': a['id'], 'amount': 120})
    lim = ok(base, '/api/accounts/%d/limits' % a['id'])
    row = {(x['op'], x['channel']): x for x in lim['limits']}
    assert row[('WDR', 'ATM')]['allowed'] == 0 and row[('WDR', 'BR')]['allowed'] == 1
    assert row[('WDR', 'BR')]['day_amount'] == 300 and row[('WDR', 'BR')]['day_amount_used'] == 120
    assert len(lim['limits']) == 18 and any(x['id'] == r['id'] for x in lim['rules'])
    s, e = call(base, '/api/movements', {'kind': 'WDR', 'account_id': a['id'], 'amount': 200}, tok(base, 'tst-teller'))
    assert s == 400 and e['error'] == 'BK-128'
    assert any(x['id'] == r['id'] for x in ok(base, '/api/rules?account_id=%d' % a['id']))
    ok(base, '/api/rules/%d/remove' % r['id'], {}, 'tst-manager')
    ok(base, '/api/movements', {'kind': 'WDR', 'account_id': a['id'], 'amount': 20, 'channel': 'ATM'})
    s, e = call(base, '/api/rules', {'account_id': a['id'], 'op': 'XXX'}, tok(base, 'tst-manager'))
    assert s == 400 and e['error'] == 'BK-132'


def test_products_and_rates(base, conn):
    p = [x for x in ok(base, '/api/products') if x['code'] == 'TA1'][0]
    assert p['day_basis'] == 'ACT365' and p['rates_now'][0]['min_balance'] == 0
    day = ok(base, '/api/day')['open_day']
    s, r = call(base, '/api/products/TA1/rates', {'valid_from': '2020-01-02', 'rate': 2}, tok(base, 'tst-manager'))
    assert s == 400 and r['error'] == 'bad_date'
    assert call(base, '/api/products/TA1/rates', {'rate': 2}, tok(base, 'tst-teller'))[0] == 403
    p = [x for x in ok(base, '/api/products/TA1/rates', {'valid_from': day, 'min_balance': 50000, 'rate': 2},
                       'tst-manager') if x['code'] == 'TA1'][0]
    assert {'min_balance': 50000, 'rate': 2} in p['rates_now']


def test_close_of_a_day_and_its_interest(base):
    a = open_account(base, 36500)
    d = ok(base, '/api/day')
    assert d['check_rows'] == 0
    assert call(base, '/api/day/close', {}, tok(base, 'tst-teller'))[0] == 403
    r = ok(base, '/api/day/close', {}, 'tst-manager')
    assert r['closed'] == d['open_day'] and r['open_day'] > d['open_day'] and r['last_closed'] == d['open_day']
    i = ok(base, '/api/accounts/%d/interest?from=%s&to=%s' % (a['id'], d['open_day'], d['open_day']))
    s = i['stretches']                                        # (accrued when asked: up to the day closed)
    assert len(s) == 1 and s[0]['day_from'] == s[0]['day_to'] == d['open_day'] and s[0]['balance'] == 36500 and s[0]['rate'] == 1
    assert abs(i['total'] - 1.0) < 1e-6                       # 36.500 × 1 % / 365


def test_users(base):
    name = 'tst-new%d' % random.randrange(10 ** 6)
    s, r = call(base, '/api/users', {'username': name, 'full_name': 'Test', 'role': 'TELLER', 'password': 'short'},
                tok(base, 'tst-admin'))
    assert s == 400 and r['error'] == 'weak_password'
    u = ok(base, '/api/users', {'username': name, 'full_name': 'Test Νέος', 'role': 'teller', 'password': PW}, 'tst-admin')
    assert u['role'] == 'TELLER' and u['active'] == 'Y'
    assert call(base, '/api/auth/login', {'username': name, 'password': PW})[0] == 200
    ok(base, '/api/users/%d' % u['id'], {'role': 'MANAGER', 'password': 'Allos-kodikos-1'}, 'tst-admin')
    assert call(base, '/api/auth/login', {'username': name, 'password': PW})[0] == 401
    s, r = call(base, '/api/auth/login', {'username': name, 'password': 'Allos-kodikos-1'})
    assert s == 200 and r['role'] == 'MANAGER'
    t = r['token']
    ok(base, '/api/users/%d' % u['id'], {'active': 'N'}, 'tst-admin')
    assert call(base, '/api/auth/me', token=t)[0] == 401                 # its sessions ended
    assert call(base, '/api/users', {'username': name, 'full_name': 'x', 'role': 'TELLER', 'password': PW},
                tok(base, 'tst-admin'))[0] == 400


def test_the_pages(base):
    s, hd, b = call(base, '/web/', raw=True)
    assert s == 200 and b'app.js' in b and "script-src 'self'" in hd['Content-Security-Policy']
    for f in ('app.js', 'app.css'):
        assert call(base, '/web/' + f, raw=True)[0] == 200
    assert call(base, '/web/nope.js', raw=True)[0] == 404
    assert call(base, '/api/nope', token=tok(base, 'tst-teller'))[0] == 404


def test_the_currencies(base):
    """the currencies and their rates, a conversion, a rate (M), an account in USD, a transfer to it from one in EUR
    (the amount it was in, each line in its currency and in the base one), the rates of a product by currency"""
    r = ok(base, '/api/fx')
    assert r['base'] == 'EUR' and r['currencies'][0]['code'] == 'EUR' and r['currencies'][0]['mid'] == 1
    usd = [c for c in r['currencies'] if c['code'] == 'USD'][0]
    x = ok(base, '/api/fx/convert?amount=100&from=EUR&to=USD')
    assert x['mid'] == round(100 * usd['mid'], 2) and x['customer'] < x['mid'] and (x['from_'], x['to_']) == ('EUR', 'USD')
    assert call(base, '/api/fx/convert?amount=100&from=EUR&to=XXQ', token=tok(base, 'tst-teller'))[1]['error'] == 'BK-152'
    day = ok(base, '/api/day')['open_day']
    assert call(base, '/api/fx/USD/rates', {'day': day, 'mid': usd['mid']}, tok(base, 'tst-teller'))[0] == 403
    h = ok(base, '/api/fx/USD/rates', {'day': day, 'mid': usd['mid']}, 'tst-manager')
    assert h['code'] == 'USD' and h['rates'][0] == {'day': day, 'mid': usd['mid']}
    assert call(base, '/api/fx', {'code': 'Q', 'name': 'x'}, tok(base, 'tst-manager'))[1]['error'] == 'BK-152'
    # an account in USD; one in EUR (of TA1) to it
    c = ok(base, '/api/customers', {'name': 'Test Νόμισμα %d' % random.randrange(10 ** 6), 'afm': afm()})
    u = ok(base, '/api/accounts', {'product': 'CUR', 'customer_id': c['id'], 'currency': 'USD'})
    assert u['currency'] == 'USD' and 'USD' in u['currencies']
    s, e = call(base, '/api/accounts', {'product': 'SAVP', 'customer_id': c['id'], 'currency': 'USD'}, tok(base, 'tst-teller'))
    assert s == 400 and e['error'] == 'BK-153'
    a = open_account(base, 500)
    e = ok(base, '/api/movements', {'kind': 'TRF', 'account_id': a['id'], 'to_account': str(u['id']), 'amount': 100})
    assert (e['orig_amount'], e['orig_currency']) == (100, 'EUR') and e['fx_rate'] > 0
    assert [l['currency'] for l in e['lines']] == ['EUR', 'EUR', 'USD', 'USD', 'USD']
    got = ok(base, '/api/accounts/%d' % u['id'])['balance']
    assert got == round(100 * e['fx_rate'], 2)
    st = ok(base, '/api/accounts/%d/statement?from=%s&to=%s' % (u['id'], day, day))
    assert st['rows'][0]['orig_currency'] == 'EUR' and st['carry_out'] == got
    p = [x for x in ok(base, '/api/products') if x['code'] == 'CUR'][0]
    assert p['currencies'].startswith('EUR') and 'USD' in p['rates_by_currency']
    assert {x['currency'] for x in p['rates']} >= {'EUR', 'USD'}
    assert call(base, '/api/products/CUR/currencies', {'currencies': 'EUR,EUR'}, tok(base, 'tst-manager'))[1]['error'] == 'BK-153'


def test_the_loans(base):
    """its installment first, a new one (M: paid to an account of the customer), the list, one with its schedule
    and what pays it off, a prepayment (M), paid off (M)"""
    q = ok(base, '/api/loans/quote?product=CONS&amount=12000&months=24')
    r = q['rate'] / 1200
    assert q['payment'] == round(12000 * r / (1 - (1 + r) ** -24), 2)
    assert call(base, '/api/loans/quote?product=CUR&amount=1&months=2', token=tok(base, 'tst-teller'))[1]['error'] == 'BK-155'
    p = open_account(base, 500)
    body = {'product': 'CONS', 'pay_account': p['iban'], 'amount': 12000, 'months': 24, 'pay_day': 10}
    assert call(base, '/api/loans', body, tok(base, 'tst-teller'))[0] == 403
    loan = ok(base, '/api/loans', body, 'tst-manager')
    assert loan['owed'] == 12000 and len(loan['schedule']) == 24 and loan['schedule'][0]['payment'] == q['payment']
    assert loan['pay_account_id'] == p['id'] and loan['payoff'] >= 12000
    assert ok(base, '/api/accounts/%d' % p['id'])['balance'] == 12500
    assert ok(base, '/api/accounts/%d' % loan['id'])['kind'] == 'LN'
    assert loan['id'] in [x['id'] for x in ok(base, '/api/loans?q=' + loan['iban'][-6:])]
    s, e = call(base, '/api/loans', dict(body, months=500), tok(base, 'tst-manager'))
    assert s == 400 and e['error'] == 'BK-156'
    assert call(base, '/api/loans/%d/prepay' % loan['id'], {'amount': 100}, tok(base, 'tst-teller'))[0] == 403
    after = ok(base, '/api/loans/%d/prepay' % loan['id'], {'amount': 2000, 'mode': 'T'}, 'tst-manager')
    assert after['entry_id'] > 0 and sum(1 for x in after['schedule'] if x['status'] == 'D') < 24
    done = ok(base, '/api/loans/%d/payoff' % loan['id'], {}, 'tst-manager')
    assert done['status'] == 'C' and done['payoff'] == 0 and done['owed'] == 0
    assert call(base, '/api/loans/%d' % p['id'], token=tok(base, 'tst-teller'))[0] == 404
