"""test_reports.py -- the reports of the bank (reports/mkreports.py, db/BK_REPORT.sql): the XML (ASCII, its
parameters, its query of bk_report), and on a live database the rows of them: the statement of an account (its
lines of the period, the running balance from the balance before it, the carry-over of each row), its interest
(the stretches and the capitalizations; the accrued at the end as the account has it), the words.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests
"""
import datetime
import importlib.util
import os
import xml.etree.ElementTree as ET

import pytest

from test_core import DSN, account, close_days, db  # noqa: F401  (db: the fixture)

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('mkreports', os.path.join(HERE, '..', 'reports', 'mkreports.py'))
mkreports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mkreports)
BUILT = mkreports.build_all()
DAY = datetime.timedelta(days=1)


@pytest.mark.parametrize('name', list(BUILT))
def test_the_xml_of_a_report(name):
    xml = BUILT[name]
    assert all(ord(c) < 128 for c in xml)
    root = ET.fromstring(xml)
    assert [p.get('name') for p in root.iter('userParameter')] == ['P_KIND', 'P_ACCOUNT', 'P_FROM', 'P_TO']
    assert root.find('.//userParameter[@name="P_KIND"]').get('initialValue') == mkreports.REPORTS[name]['kind']
    assert 'bk_report.report_rows(:P_KIND, :P_ACCOUNT' in root.find('.//select').text
    # every field on a column of the query, a summary, a formula or the page number
    names = {i.get('name') for i in root.iter('dataItem')} | {s.get('name') for s in root.iter('summary')} \
        | {f.get('name') for f in root.iter('formula')} | {'PageNumber'}
    assert {f.get('source') for f in root.iter('field')} <= names
    funcs = {f.get('name') for f in root.iter('function')}
    assert {f.get('source') for f in root.iter('formula')} <= funcs
    # on the disk as made
    path = os.path.join(HERE, '..', 'reports', name + '.xml')
    assert open(path, encoding='ascii').read() == xml, 'python3 reports/mkreports.py'


def rows(db, kind, a, d1, d2):
    db.cur.execute('select seq, ldate, doc_text, descr, debit, credit, balance, prior_debit, prior_credit, '
                   'prior_balance, cum_debit, cum_credit from table(bk_report.report_rows(:k, :a, :d1, :d2)) '
                   'order by seq', k=kind, a=a, d1=d1, d2=d2)
    cols = [d[0].lower() for d in db.cur.description]
    return [dict(zip(cols, r)) for r in db.cur]


def carried(rs):
    """each row: what was before it in the period and up to it"""
    pd = pc = 0
    for r in rs:
        assert (r['prior_debit'], r['prior_credit']) == pytest.approx((pd, pc), abs=1e-9)
        pd += r['debit'] or 0
        pc += r['credit'] or 0
        assert (r['cum_debit'], r['cum_credit']) == pytest.approx((pd, pc), abs=1e-9)
        assert r['balance'] == pytest.approx(r['prior_balance'] + (r['credit'] or 0) - (r['debit'] or 0), abs=1e-9)


@pytest.mark.skipif(not DSN, reason='BANK_DSN not set')
def test_the_statement_of_an_account(db):
    a = account(db, 'TS1')
    d0 = db.day()
    e1 = db.fn('deposit', int, a, 1000, 'Test καρτέλα')
    db.fn('withdraw', int, a, 200)
    db.conn.commit()
    rs = rows(db, 'S', a, d0, d0)
    assert [(r['debit'], r['credit'], r['balance']) for r in rs] == [(None, 1000, 1000), (200, None, 800)]
    assert rs[0]['prior_balance'] == 0 and rs[0]['ldate'].date() == d0.date()
    assert rs[0]['doc_text'] == d0.strftime('%d/%m/%Y')
    assert rs[0]['descr'] == '#%d Κατάθεση: Test καρτέλα' % e1 and 'Ανάληψη' in rs[1]['descr']
    carried(rs)
    # the next day: before it the 800; a move of it, and a reversal of the withdrawal marked
    close_days(db, 1)
    db.fn('deposit', int, a, 50)
    db.conn.commit()
    rs = rows(db, 'S', a, d0 + DAY, d0 + DAY)
    assert [(r['prior_balance'], r['credit'], r['balance']) for r in rs] == [(800, 50, 850)]
    carried(rs)
    # nothing in the period: one row, the balance before it
    rs = rows(db, 'S', a, d0 + 10 * DAY, d0 + 20 * DAY)
    assert len(rs) == 1 and rs[0]['balance'] == rs[0]['prior_balance'] == 850 and rs[0]['debit'] is None
    assert rs[0]['descr'] == 'Από προηγούμενη περίοδο'
    # the whole of it: its end the balance of the account
    rs = rows(db, 'S', a, d0, d0 + DAY)
    assert rs[-1]['balance'] == db.balance(a) and len(rs) == 3
    carried(rs)
    with pytest.raises(Exception, match='BK-108'):
        rows(db, 'S', -1, d0, d0)
    with pytest.raises(Exception, match='BK-145'):
        rows(db, 'X', a, d0, d0)


@pytest.mark.skipif(not DSN, reason='BANK_DSN not set')
def test_the_interest_of_an_account(db):
    a = account(db, 'TS1')
    d0 = db.day()
    db.fn('deposit', int, a, 5000)
    db.conn.commit()
    end = (d0.replace(day=28) + 4 * DAY).replace(day=1) - DAY          # the end of the month: capitalized
    close_days(db, (end - d0).days + 3)
    db.fn('deposit', int, a, 1000)
    db.conn.commit()
    close_days(db, 1)
    db.proc('accrue', a)
    db.conn.commit()
    rs = rows(db, 'I', a, d0, db.day())
    carried(rs)
    acc = db.one('select sum(interest) from bk_accrual where account_id = :a', a=a)[0]
    gross, tax = db.one('select gross, tax from bk_capital where account_id = :a', a=a)
    assert sum(r['credit'] or 0 for r in rs) == pytest.approx(acc, abs=1e-9)
    assert [r['debit'] for r in rs if r['debit']] == [gross]
    cap = [r for r in rs if r['debit']][0]
    assert cap['ldate'].date() == end.date() and cap['doc_text'] is None
    assert 'φόρος %s €' % ('%.2f' % tax).replace('.', ',') in cap['descr']
    # a stretch: its words
    s = rs[0]
    assert s['ldate'].date() == d0.date() and '5.000,00 € × 3% × ' in s['descr'] and s['descr'].endswith('/365')
    # the end: the accrued of the account; from the day after the capitalization: before it what was left
    assert rs[-1]['balance'] == db.one('select accrued from bk_account where id = :a', a=a)[0]
    after = rows(db, 'I', a, end + DAY, db.day())
    assert after[-1]['balance'] == rs[-1]['balance']
    assert after[0]['prior_balance'] == cap['balance']


@pytest.mark.skipif(not DSN, reason='BANK_DSN not set')
def test_the_words_of_the_reports(db):
    a = account(db, 'TS1')
    iban = db.one('select iban from bk_account where id = :a', a=a)[0]
    t = db.one("select bk_report.title('S', :a), bk_report.title('I', :a) from dual", a=a)
    assert t[0].startswith('Καρτέλα λογαριασμού ' + iban) and t[1].startswith('Τόκοι λογαριασμού ' + iban)
    for key in mkreports.LABELS + ['PERIOD']:
        for k in ('S', 'I'):
            w = db.one('select bk_report.label(:k, :p) from dual', k=key, p=k)[0]
            assert w and w != key and all(ord(c) < 128 or 'Ά' <= c <= 'ώ' or c in '×/ ' for c in w), (key, w)
    assert db.one("select bk_report.label('DEBIT', 'S'), bk_report.label('DEBIT', 'I') from dual") == \
        ('Χρέωση', 'Κεφαλαιοποίηση')


@pytest.mark.skipif(not DSN, reason='BANK_DSN not set')
def test_the_statement_of_a_credit_card(db):
    """its lines of the period of a statement; the balance what is owed, from what was owed before it to its
    closing; under the title its minimum and its due date"""
    from test_core import customer
    d = db.day() + 2 * DAY
    a = db.fn('cc_open', int, 'VISA', customer(db), 2000, d.day if d.day <= 28 else 1)
    k = db.fn('new_card', int, a)
    p = account(db, 'TC1')
    db.fn('deposit', int, p, 1000)
    db.fn('cc_purchase', int, k, 300, 'Test ηλεκτρονικά')
    db.conn.commit()
    for _ in range(40):
        if db.one('select count(*) from bk_cc_statement where account_id = :a', a=a)[0]:
            break
        close_days(db, 1)
    db.fn('cc_purchase', int, k, 120, 'Test καύσιμα')
    db.fn('cc_pay', int, a, p, 100)
    db.conn.commit()
    for _ in range(40):
        if db.one('select count(*) from bk_cc_statement where account_id = :a', a=a)[0] == 2:
            break
        close_days(db, 1)
    s = db.one('select period_from, stmt_date, opening, closing, min_due, due_date from bk_cc_statement '
               'where account_id = :a order by stmt_date desc fetch first 1 rows only', a=a)
    rs = rows(db, 'C', a, s[0], s[1])
    assert rs[0]['prior_balance'] == s[2] == 300 and rs[-1]['balance'] == s[3]
    assert [(r['debit'], r['credit']) for r in rs][:2] == [(120, None), (None, 100)]
    assert rs[0]['descr'].endswith(' Αγορά: Test καύσιμα') and 'Πληρωμή κάρτας' in rs[1]['descr']
    for r in rs:                                     # (owed: charges less payments)
        assert r['balance'] == pytest.approx(r['prior_balance'] + (r['debit'] or 0) - (r['credit'] or 0), abs=1e-9)
    t = db.one("select bk_report.period('C', :a, :f, :t), bk_report.title('C', :a), bk_report.label('BALANCE', 'C') "
               "from dual", a=a, f=s[0], t=s[1])
    assert ('Ελάχιστη καταβολή %s €' % ('%.2f' % s[4]).replace('.', ',')) in t[0] and s[5].strftime('%d/%m/%Y') in t[0]
    assert t[1].startswith('Κίνηση πιστωτικής κάρτας ') and t[2] == 'Οφειλή'
    assert db.one("select bk_report.period('S', :a, :f, :t) from dual", a=a, f=s[0], t=s[1])[0] == \
        'Διάστημα: %s - %s' % (s[0].strftime('%d/%m/%Y'), s[1].strftime('%d/%m/%Y'))


@pytest.mark.skipif(not DSN, reason='BANK_DSN not set')
def test_the_schedule_of_a_loan(db):
    """its installments: the interest as debit, the principal as credit, the balance the principal left (from its
    principal before them); under the title its principal, months, rate and day"""
    from test_core import customer
    c = customer(db)
    p = db.fn('open_account', int, 'TC1', c, 0)
    a = db.fn('ln_open', int, 'CONS', c, 6000, 12, p, 10)
    db.conn.commit()
    d0, end = db.one('select min(due_date), max(due_date) from bk_ln_schedule where account_id = :a', a=a)
    rs = rows(db, 'L', a, d0 - 40 * DAY, end)
    assert len(rs) == 12 and rs[0]['prior_balance'] == 6000 and rs[-1]['balance'] == 0
    assert sum(r['credit'] for r in rs) == pytest.approx(6000, abs=1e-9)
    assert rs[0]['debit'] == round(6000 * 9.5 / 1200, 2) and rs[0]['doc_text'] == 'Δόση 1' and 'θα έρθει' in rs[0]['descr']
    # from its 4th: before them the principal of the first three paid
    s3 = db.one('select balance from bk_ln_schedule where account_id = :a and n = 3', a=a)[0]
    rs = rows(db, 'L', a, rs[3]['ldate'], end)
    assert rs[0]['prior_balance'] == s3 and len(rs) == 9
    t = db.one("select bk_report.period('L', :a, null, null), bk_report.title('L', :a), bk_report.label('CREDIT', 'L') from dual", a=a)
    assert t[0].startswith('Κεφάλαιο 6.000,00 € σε 12 μήνες') and 'σταθερό επιτόκιο, τώρα 9,5%' in t[0] and 'δόση στις 10' in t[0]
    assert t[1].startswith('Πρόγραμμα αποπληρωμής δανείου ') and t[2] == 'Κεφάλαιο'
    with pytest.raises(Exception, match='BK-155'):
        rows(db, 'L', p, d0, end)
