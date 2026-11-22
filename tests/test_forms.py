"""test_forms.py -- the forms of forms/mkforms.py, without the Forms (they are built on forms1):

- the XML: ASCII, every LOV of an item exists, every return item is an item of the form; the menu module;
- the PL/SQL of the forms: no built-in of the Forms in SQL, no SELECT inside an expression, no ANSI join (the
  PL/SQL of frmcmp refuses them; the database would take them);
- the record groups: each query runs in the database, with the columns its LOV maps;
- the words: every key of BK_TEXT that the forms ask for is there, in Greek;
- the package UI of each form, compiled in the database against small stubs of the built-ins of the Forms
  (NAME_IN, COPY, MESSAGE, SHOW_LOV, GO_BLOCK, EXECUTE_QUERY, SET_*_PROPERTY, NEW_FORM ...), then called as
  the triggers call it: the login (BK_AUTH, the users of the pages), the roles, a new customer and account, a
  movement, the account (its status, a reversal), the running balance of a statement, the close of a day.
  The stubs and UI are dropped at the end.

    BANK_DSN=bank/<password>@localhost:1521/FREEPDB1 python3 -m pytest -q tests

It commits: its own users (tst-f...), customers and accounts (Test ...), and it closes a day.
"""
import hashlib
import importlib.util
import os
import random
import re
import uuid
import xml.etree.ElementTree as ET

import pytest

oracledb = pytest.importorskip('oracledb')
DSN = os.environ.get('BANK_DSN')
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
NS = {'f': 'http://xmlns.oracle.com/Forms'}

spec = importlib.util.spec_from_file_location('mkforms', os.path.join(ROOT, 'forms', 'mkforms.py'))
mkforms = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mkforms)
BUILT = {name: mkforms.build(name, f) for name, f in mkforms.FORMS.items()}
WORDS = dict(mkforms.WORDS.words)
PW = 'Kodikos-2026'

STUBS = [
    """create or replace package fstub as
  type t_map is table of varchar2(4000) index by varchar2(200);
  items t_map; props t_map; msgs varchar2(32767); block varchar2(30); queries varchar2(4000);
  lov_answer boolean := true; lov_id varchar2(40);
  procedure clear;
end;""",
    """create or replace package body fstub as
  procedure clear is
  begin
    items.delete; props.delete; msgs := null; block := null; queries := null;
    lov_answer := true; lov_id := null;
  end;
end;""",
    """create or replace function name_in(p varchar2) return varchar2 is
begin
  if fstub.items.exists(upper(p)) then return fstub.items(upper(p)); end if;
  return null;
end;""",
    "create or replace procedure copy(v varchar2, p varchar2) is begin fstub.items(upper(p)) := v; end;",
    "create or replace procedure message(m varchar2) is begin fstub.msgs := fstub.msgs || m || chr(10); end;",
    "create or replace function title return number is begin return 1; end;",
    "create or replace function label return number is begin return 2; end;",
    "create or replace function prompt_text return number is begin return 3; end;",
    "create or replace function default_where return number is begin return 4; end;",
    "create or replace function format_mask return number is begin return 5; end;",
    "create or replace function enabled return number is begin return 11; end;",
    "create or replace function visible return number is begin return 12; end;",
    "create or replace function update_allowed return number is begin return 13; end;",
    "create or replace function insert_allowed return number is begin return 14; end;",
    "create or replace function delete_allowed return number is begin return 15; end;",
    "create or replace function property_false return varchar2 is begin return 'FALSE'; end;",
    """create or replace procedure default_value(v varchar2, p varchar2) is
begin if not fstub.items.exists(upper(p)) then fstub.items(upper(p)) := v; end if; end;""",
    """create or replace function get_window_property(w varchar2, p number) return varchar2 is
begin if fstub.props.exists('WINDOW ' || upper(w) || '#' || p) then return fstub.props('WINDOW ' || upper(w) || '#' || p); end if;
return null; end;""",
    "create or replace package web as procedure show_document(u varchar2, t varchar2); end;",
    """create or replace package body web as
  procedure show_document(u varchar2, t varchar2) is begin fstub.props('SHOW_DOCUMENT') := u || ' ' || t; end;
end;""",
    """create or replace procedure set_window_property(w varchar2, p number, v varchar2) is
begin fstub.props('WINDOW ' || upper(w) || '#' || p) := v; end;""",
    """create or replace procedure set_item_property(i varchar2, p number, v varchar2) is
begin fstub.props(upper(i) || '#' || p) := v; end;""",
    """create or replace procedure set_lov_property(l varchar2, p number, v varchar2) is
begin fstub.props('LOV ' || upper(l) || '#' || p) := v; end;""",
    """create or replace procedure set_lov_column_property(l varchar2, c number, p number, v varchar2) is
begin fstub.props('LOV ' || upper(l) || '.' || c || '#' || p) := v; end;""",
    """create or replace procedure set_block_property(b varchar2, p number, v varchar2) is
begin fstub.props('BLOCK ' || upper(b) || '#' || p) := v; end;""",
    "create or replace procedure go_block(b varchar2) is begin fstub.block := upper(b); end;",
    "create or replace procedure go_item(i varchar2) is begin fstub.props('GO_ITEM') := upper(i); end;",
    "create or replace function no_validate return number is begin return 16; end;",
    """create or replace procedure clear_block(v number) is
begin fstub.queries := fstub.queries || fstub.block || ':clear;'; end;""",
    """create or replace procedure execute_query is
  w varchar2(4000);
begin
  if fstub.props.exists('BLOCK ' || fstub.block || '#4') then w := fstub.props('BLOCK ' || fstub.block || '#4'); end if;
  fstub.queries := fstub.queries || fstub.block || ':' || w || ';';
end;""",
    "create or replace procedure forms_ddl(p varchar2) is begin execute immediate p; end;",
    "create or replace procedure call_form(f varchar2) is begin fstub.props('CALL_FORM') := f; end;",
    "create or replace procedure do_key(k varchar2) is begin fstub.props('DO_KEY') := k; end;",
    "create or replace function lov_name return number is begin return 9; end;",
    """create or replace function get_item_property(i varchar2, p number) return varchar2 is
begin if fstub.props.exists(upper(i) || '#' || p) then return fstub.props(upper(i) || '#' || p); end if; return null; end;""",
    "create or replace function status return number is begin return 7; end;",
    "create or replace function query_status return number is begin return 8; end;",
    """create or replace procedure set_record_property(r number, b varchar2, p number, v number) is
begin fstub.props('RECORD ' || upper(b) || '#' || p) := v; end;""",
    "create or replace procedure new_form(f varchar2) is begin fstub.props('NEW_FORM') := f; end;",
    """create or replace procedure set_menu_item_property(m varchar2, p number, v varchar2) is
begin fstub.props('MENU ' || upper(m) || '#' || p) := v; end;""",
    "create or replace procedure exit_form is begin fstub.props('EXIT_FORM') := 'Y'; end;",
    """create or replace function show_lov(l varchar2) return boolean is
begin
  if fstub.lov_answer then fstub.items('CTL.FIND_ID') := fstub.lov_id; end if;
  return fstub.lov_answer;
end;""",
]
DROP = ['package ui', 'package web', 'function enabled', 'function visible', 'function update_allowed',
        'function insert_allowed', 'function delete_allowed', 'function property_false', 'procedure default_value',
        'function get_window_property', 'function lov_name', 'function get_item_property', 'function status', 'function query_status', 'procedure set_record_property',
        'procedure do_key', 'procedure new_form', 'procedure set_menu_item_property', 'procedure call_form', 'procedure exit_form', 'procedure forms_ddl', 'function show_lov', 'procedure execute_query', 'procedure go_block', 'procedure go_item', 'procedure clear_block', 'function no_validate',
        'procedure set_block_property', 'procedure set_lov_column_property', 'procedure set_lov_property',
        'procedure set_item_property', 'procedure set_window_property', 'function default_where', 'function format_mask',
        'function prompt_text', 'function label', 'function title', 'procedure message', 'procedure copy',
        'function name_in', 'package fstub']

def xml_of(name):
    return ET.fromstring(BUILT[name][0])


# -- the XML, without a database ---------------------------------------------------------------

@pytest.mark.parametrize('name', list(BUILT))
def test_xml_ascii_and_references(name):
    xml = BUILT[name][0]
    assert all(ord(c) < 128 for c in xml)
    # what the schema of XML2Forms 14.1.2 refused (XML-24535, XML-24523)
    assert 'DMLDataTargetName' not in xml and 'ColumnDataType="Char"' not in xml
    root = xml_of(name)
    items = {'%s.%s' % (b.get('Name'), i.get('Name'))
             for b in root.iter('{%s}Block' % NS['f']) for i in b.findall('f:Item', NS)}
    lovs = {lv.get('Name'): lv for lv in root.iter('{%s}LOV' % NS['f'])}
    groups = {g.get('Name') for g in root.iter('{%s}RecordGroup' % NS['f'])}
    for b in root.iter('{%s}Block' % NS['f']):
        for i in b.findall('f:Item', NS):
            if i.get('LovName'):
                assert i.get('LovName') in lovs, i.get('Name')
    for lv in lovs.values():
        assert lv.get('RecordGroupName') in groups
        for m in lv.findall('f:LOVColumnMapping', NS):
            if m.get('ReturnItem'):
                assert m.get('ReturnItem') in items, m.get('ReturnItem')
    # every item of the package UI is an item of the form (NAME_IN, COPY of BLOCK.ITEM)
    body = BUILT[name][2]
    for it in set(re.findall(r"'((?:CTL|CUST|CA|ACC|ST|LAST)\.[A-Z_0-9]+)'", body)):
        blk = it.split('.')[0]
        if blk in {b.get('Name') for b in root.iter('{%s}Block' % NS['f'])}:
            if it in items or it.startswith('CTL.'):
                continue
            assert it in items, it


def test_the_menu_module():
    xml = mkforms.menu_xml()
    assert all(ord(c) < 128 for c in xml)
    root = ET.fromstring(xml)
    menus = {m.get('Name') for m in root.iter('{%s}Menu' % NS['f'])}
    for mi in root.iter('{%s}MenuItem' % NS['f']):
        if mi.get('CommandType') == 'Menu':
            assert mi.get('SubMenuName') in menus
    # every form of the bar is a form of the generator
    for f in re.findall(r"new_form\('(\w+)'\)", xml, re.I):
        assert f in mkforms.FORMS


BUILTINS = ('NAME_IN', 'COPY', 'SHOW_LOV', 'GO_BLOCK', 'EXECUTE_QUERY', 'MESSAGE', 'TX', 'NUM', 'MONEY', 'DATE_IN')


@pytest.mark.parametrize('name', list(BUILT))
def test_no_forms_builtins_in_sql(name):
    """frmcmp: "function 'NAME_IN' may not be used in SQL" (PL/SQL 231). The stubs of the database are ordinary
    functions, so the compile in the database does not see it: a check of the text"""
    body = re.sub(r'--[^\n]*', '', BUILT[name][2]).upper()
    for stmt in re.findall(r'\b(?:SELECT|INSERT|UPDATE|DELETE|MERGE)\b[^;]*;', body):
        for b in BUILTINS:
            assert not re.search(r'\b%s\s*\(' % b, stmt), '%s in SQL: %s' % (b, stmt[:120])


@pytest.mark.parametrize('name', list(BUILT))
def test_plsql_of_the_forms(name):
    """what the database takes and the PL/SQL of the Forms does not: a SELECT inside an expression, ANSI joins, a
    unit named like a keyword"""
    body = re.sub(r'--[^\n]*', '', BUILT[name][2]).upper()
    assert not re.search(r'\(\s*SELECT\b', body), 'a SELECT inside an expression'
    assert not re.search(r'\b(LEFT|RIGHT|FULL|INNER|CROSS)\s+(OUTER\s+)?JOIN\b|\bJOIN\b', body), 'an ANSI join'
    assert not re.search(r'\b(FUNCTION|PROCEDURE)\s+(DAY|MONTH|YEAR|DATE|LEVEL|SIZE|MODE)\b', body)


def test_the_words_of_the_forms():
    for name, (xml, spec_, body) in BUILT.items():
        for k in re.findall(r"tx\('(T[0-9A-F]{8})'\)", body):
            assert k in WORDS, (name, k)
    sql = open(os.path.join(ROOT, 'db', 'BK_TEXT.sql'), encoding='utf-8').read()
    for k, v in WORDS.items():
        assert "when '%s' then '%s'" % (k, v.replace("'", "''")) in sql, 'BK_TEXT.sql: python3 forms/mkforms.py'


# -- in the database ---------------------------------------------------------------------------

needs_db = pytest.mark.skipif(not DSN, reason='BANK_DSN not set (user/password@host:port/service)')
LOGIN = {}


def token_of(c, name):
    t, r, n = c.var(str), c.var(str), c.var(str)
    c.callproc('bk_auth.login', [name, PW, 'pytest', t, r, n])
    return t.getvalue()


@pytest.fixture(scope='module')
def cur():
    conn = oracledb.connect(DSN)
    c = conn.cursor()
    if not c.execute("select count(*) from user_objects where object_name = 'BK_AUTH'").fetchone()[0]:
        pytest.skip('no BK_AUTH: GRANT_CRYPTO.sql, then INSTALL.sql')
    tag = uuid.uuid4().hex[:6]
    for role in ('TELLER', 'MANAGER'):
        name = 'tst-f%s-%s' % (role[0].lower(), tag)
        salt = os.urandom(16)
        c.execute('insert into bk_user (username, full_name, role, pw_hash, pw_salt, pw_iter) values (:u, :f, :r, :h, :s, 1000)',
                  u=name, f='Test forms', r=role, h=hashlib.pbkdf2_hmac('sha256', PW.encode(), salt, 1000), s=salt)
        LOGIN[role] = name
    conn.commit()
    LOGIN['token'] = token_of(c, LOGIN['MANAGER'])
    LOGIN['teller'] = token_of(c, LOGIN['TELLER'])
    for s in STUBS:
        c.execute(s)
    yield c
    conn.rollback()
    c.execute("delete from bk_user where username like 'tst-f%'")
    conn.commit()
    for d in DROP:
        try:
            c.execute('drop ' + d)
        except oracledb.DatabaseError:
            pass
    conn.close()


def compile_ui(cur, name):
    """UI of the form, as the form has it; FORM_TRIGGER_FAILURE (a built-in of the Forms) declared"""
    _, spec_, body = BUILT[name]
    body = body.replace('PACKAGE BODY ui IS', 'PACKAGE BODY ui IS\n  form_trigger_failure EXCEPTION;', 1)
    for src in (spec_, body):
        cur.execute('create or replace ' + src)
    cur.execute("select line, text from user_errors where name = 'UI' order by sequence")
    errors = cur.fetchall()
    assert not errors, errors


def run(cur, plsql, **items):
    """a call of the package UI, logged in as the manager of the tests unless GLOBAL__BK_TOKEN"""
    cur.execute('begin fstub.clear; end;')
    items.setdefault('GLOBAL__BK_TOKEN', LOGIN['token'])
    for k, v in items.items():
        cur.execute('begin fstub.items(:k) := :v; end;', k=k.replace('__', '.'), v=v)
    cur.execute('begin %s end;' % plsql)


def fails(cur, plsql, **items):
    """the call ends with FORM_TRIGGER_FAILURE (the message of it back)"""
    with pytest.raises(oracledb.DatabaseError):
        run(cur, plsql, **items)
    return msgs(cur)


def queries(cur):
    """the queries of the call: BLOCK:its where; ..."""
    v = cur.var(str, 4000)
    cur.execute('begin :v := fstub.queries; end;', v=v)
    return v.getvalue() or ''


def item(cur, name):
    return cur.callfunc('name_in', str, [name])


def prop(cur, key):
    v = cur.var(str, 4000)
    cur.execute("begin if fstub.props.exists(:k) then :v := fstub.props(:k); end if; end;", k=key, v=v)
    return v.getvalue()


def msgs(cur):
    v = cur.var(str, 32767)
    cur.execute('begin :v := fstub.msgs; end;', v=v)
    return v.getvalue() or ''


def afm():
    s = ''.join(random.choice('0123456789') for _ in range(8))
    return s + str(sum(int(c) * 2 ** (8 - i) for i, c in enumerate(s)) % 11 % 10)


@needs_db
@pytest.mark.parametrize('name', list(BUILT))
def test_record_groups_run(cur, name):
    root = xml_of(name)
    for g in root.iter('{%s}RecordGroup' % NS['f']):
        cur.execute(g.get('RecordGroupQuery'))
        cols = [d[0] for d in cur.description]
        assert cols == [c.get('Name') for c in g.findall('f:RecordGroupColumn', NS)], g.get('Name')


@needs_db
@pytest.mark.parametrize('name', list(BUILT))
def test_the_package_of_each_form_compiles(cur, name):
    compile_ui(cur, name)


@needs_db
def test_the_login(cur):
    compile_ui(cur, 'BK_LOGIN')
    run(cur, "ui.press('CTL.LOGIN');", CTL__L_USER=LOGIN['TELLER'], CTL__L_PW=PW, GLOBAL__BK_TOKEN='')
    t = item(cur, 'GLOBAL.BK_TOKEN')
    assert t and len(t) == 43 and prop(cur, 'NEW_FORM') == 'BK_MAIN' and item(cur, 'CTL.L_PW') is None
    # the token of the forms is a token of the pages: the same SHA-256 in BK_SESSION
    assert cur.execute('select count(*) from bk_session where token_hash = :h',
                       h=hashlib.sha256(t.encode()).digest()).fetchone()[0] == 1
    m = fails(cur, "ui.press('CTL.L_PW');", CTL__L_USER=LOGIN['TELLER'], CTL__L_PW='wrong', GLOBAL__BK_TOKEN='')
    assert 'BK-141' in m and prop(cur, 'NEW_FORM') is None
    cur.execute('update bk_user set failed = 0 where username = :u', u=LOGIN['TELLER'])
    cur.connection.commit()


@needs_db
def test_the_session_and_the_roles(cur):
    compile_ui(cur, 'BK_DAY')
    run(cur, 'ui.init;', GLOBAL__BK_TOKEN='not-a-token')
    assert prop(cur, 'NEW_FORM') == 'BK_LOGIN'
    run(cur, 'ui.init;', GLOBAL__BK_TOKEN=LOGIN['teller'])
    assert prop(cur, 'NEW_FORM') is None and prop(cur, 'CTL.CLOSEDAY#11') == 'FALSE'      # a teller: no close
    assert prop(cur, 'WINDOW WIN#1').endswith('[%s]' % LOGIN['TELLER'])
    assert item(cur, 'CTL.D_OPEN') and item(cur, 'CTL.D_CHECK')
    run(cur, 'ui.init;')
    assert prop(cur, 'CTL.CLOSEDAY#11') is None                                         # a manager: yes
    compile_ui(cur, 'BK_MAIN')
    run(cur, 'ui.init;', GLOBAL__BK_TOKEN=LOGIN['teller'])
    assert 'TELLER' in item(cur, 'CTL.D_OPEN')
    run(cur, "ui.press('CTL.GO_BK_ACCOUNTS');")
    assert prop(cur, 'NEW_FORM') == 'BK_ACCOUNTS'
    run(cur, "ui.press('CTL.LOGOUT');", GLOBAL__BK_TOKEN=token_of(cur, LOGIN['TELLER']))
    assert prop(cur, 'NEW_FORM') == 'BK_LOGIN' and item(cur, 'GLOBAL.BK_TOKEN') is None


@needs_db
def test_a_customer_and_an_account(cur):
    compile_ui(cur, 'BK_CUSTOMERS')
    a = afm()
    run(cur, "ui.press('CTL.NEWCUST');", CTL__C_NAME='Test Φόρμα Πελάτης', CTL__C_AFM=a, CTL__C_PHONE='6900000001')
    cid, code = cur.execute('select id, code from bk_customer where afm = :a', a=a).fetchone()
    assert code in msgs(cur) and 'CUST:id = %d;' % cid in queries(cur)              # the new one on the screen
    assert item(cur, 'CTL.C_NAME') is None
    m = fails(cur, "ui.press('CTL.NEWCUST');", CTL__C_NAME='Test x', CTL__C_AFM='123456789')
    assert 'BK-104' in m
    run(cur, "ui.press('CTL.NEWACC');", CUST__ID=str(cid), CTL__A_PRODUCT='CUR', CTL__A_OD='500')
    iban, od = cur.execute('select a.iban, a.od_limit from bk_account a, bk_holder h where h.account_id = a.id '
                           'and h.customer_id = :c', c=cid).fetchone()
    assert iban in msgs(cur) and od == 500
    assert 'BK-110' in fails(cur, "ui.press('CTL.NEWACC');", CUST__ID=str(cid), CTL__A_PRODUCT='NOPE')
    assert 'ΑΦΜ' in fails(cur, "ui.validate('CUST.AFM');", CUST__AFM='123456789')
    run(cur, "ui.validate('CUST.AFM');", CUST__AFM=a)


def new_account(cur, money=0):
    c = cur.callfunc('bk_core.new_customer', int, ['Test Φόρμες %d' % random.randrange(10 ** 6), afm()])
    a = cur.callfunc('bk_core.open_account', int, ['CUR', c, 0])
    for op in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC'):       # none of the rules of the demo on it
        cur.callfunc('bk_core.set_rule', int, [None, a, op, '*'], {'p_allowed': 'Y', 'p_fee': 0})
    if money:
        cur.callfunc('bk_core.deposit', int, [a, money])
    cur.connection.commit()
    return a


@needs_db
def test_a_movement(cur):
    compile_ui(cur, 'BK_MOVE')
    a = new_account(cur, 1000)
    b = new_account(cur)
    # from the accounts (Νέα κίνηση): its account, its balance, its last moves
    run(cur, 'ui.init;', GLOBAL__BK_ACCOUNT=str(a))
    assert item(cur, 'CTL.M_ACC_ID') == str(a) and '1.000,00' in item(cur, 'CTL.M_BAL')
    assert 'LAST:account_id = %d;' % a in queries(cur)
    day = cur.execute("select to_char(bk_core.open_day, 'DD/MM/YYYY') from dual").fetchone()[0]
    assert item(cur, 'CTL.M_VDATE') == day
    run(cur, "ui.press('CTL.SAVE');", CTL__M_ACC_ID=str(a), CTL__M_KIND='WDR', CTL__M_KIND_TEXT='Ανάληψη',
        CTL__M_AMOUNT='200', CTL__M_VDATE=day, CTL__M_DESCR='Test φόρμα')
    assert item(cur, 'CTL.M_RESULT').startswith('Εγγραφή #') and '800,00' in item(cur, 'CTL.M_BAL')
    assert item(cur, 'CTL.M_AMOUNT') is None
    who = cur.execute("select created_by from bk_entry where descr = 'Test φόρμα' order by id desc fetch first 1 rows only").fetchone()[0]
    assert who == LOGIN['MANAGER']                                     # (CLIENT_IDENTIFIER: the user of the form)
    run(cur, "ui.press('CTL.SAVE');", CTL__M_ACC_ID=str(a), CTL__M_KIND='TRF', CTL__M_TO_ID=str(b),
        CTL__M_AMOUNT='50', CTL__M_VDATE=day)
    assert cur.execute('select balance from bk_account where id = :b', b=b).fetchone()[0] == 50
    m = fails(cur, "ui.press('CTL.SAVE');", CTL__M_ACC_ID=str(a), CTL__M_KIND='WDR', CTL__M_AMOUNT='100000', CTL__M_VDATE=day)
    assert 'BK-119' in m and item(cur, 'CTL.M_AMOUNT') == '100000'            # (kept: to be corrected)
    assert 'λογαριασμό της τράπεζας' in fails(cur, "ui.press('CTL.SAVE');", CTL__M_ACC_ID=str(a), CTL__M_KIND='TRF',
                                               CTL__M_AMOUNT='1', CTL__M_VDATE=day)
    assert cur.execute('select balance from bk_account where id = :a', a=a).fetchone()[0] == 750
    assert cur.execute('select count(*) from bk_check').fetchone()[0] == 0


@needs_db
def test_the_account_and_its_statement(cur):
    compile_ui(cur, 'BK_ACCOUNTS')
    a = new_account(cur, 300)
    e = cur.callfunc('bk_core.withdraw', int, [a, 100])
    cur.connection.commit()
    run(cur, "ui.press('CTL.BLOCKACC');", ACC__ID=str(a))
    assert cur.execute('select status from bk_account where id = :a', a=a).fetchone()[0] == 'B'
    assert 'δεσμεύτηκε' in msgs(cur) and 'ACC:id = %d;' % a in queries(cur)
    run(cur, "ui.press('CTL.BLOCKACC');", ACC__ID=str(a))
    assert cur.execute('select status from bk_account where id = :a', a=a).fetchone()[0] == 'O'
    run(cur, "ui.press('CTL.SETOD');", ACC__ID=str(a), CTL__O_LIMIT='250')
    assert cur.execute('select od_limit from bk_account where id = :a', a=a).fetchone()[0] == 250
    # the running balance of a line: its account up to it
    line = cur.execute('select id from bk_line where entry_id = :e and account_id = :a', e=e, a=a).fetchone()[0]
    run(cur, "ui.post_query('ST');", ACC__ID=str(a), ST__ENTRY_ID=str(e), ST__LINE_ID=str(line), ST__KIND='WDR',
        SYSTEM__TRIGGER_RECORD='1')
    assert item(cur, 'ST.RUN_BALANCE') == '200' and item(cur, 'ST.KIND_TEXT') == 'Ανάληψη'
    run(cur, "ui.press('CTL.REVERSE');", ACC__ID=str(a), ST__ENTRY_ID=str(e), CTL__R_DESCR='Test λάθος')
    assert 'Αντιλογισμός: εγγραφή #' in msgs(cur)
    assert cur.execute('select balance from bk_account where id = :a', a=a).fetchone()[0] == 300
    assert 'BK-123' in fails(cur, "ui.press('CTL.REVERSE');", ACC__ID=str(a), ST__ENTRY_ID=str(e))
    run(cur, "ui.press('CTL.GO_BK_MOVE');", ACC__ID=str(a))
    assert item(cur, 'GLOBAL.BK_ACCOUNT') == str(a) and prop(cur, 'NEW_FORM') == 'BK_MOVE'
    assert 'Πρώτα' in fails(cur, "ui.press('CTL.ACCRUE');")


@needs_db
def test_the_close_of_a_day(cur):
    compile_ui(cur, 'BK_DAY')
    d0 = cur.execute('select bk_core.open_day from dual').fetchone()[0]
    run(cur, "ui.press('CTL.CLOSEDAY');")
    assert cur.execute('select bk_core.open_day from dual').fetchone()[0] > d0
    assert d0.strftime('%d/%m/%Y') in msgs(cur) and item(cur, 'CTL.D_LAST') == d0.strftime('%d/%m/%Y')
    assert item(cur, 'CTL.D_CHECK') == 'Όλα συμφωνούν'
