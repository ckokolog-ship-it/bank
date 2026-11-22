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
