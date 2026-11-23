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
    for it in set(re.findall(r"'((?:CTL|CUST|CA|ACC|ST|LAST|CC|CST)\.[A-Z_0-9]+)'", body)):
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
    # functions of SQL the PL/SQL of the Forms 14 does not know, even inside a SELECT (PL/SQL ERROR 201 on forms1)
    m = re.search(r'\b(ORA_HASH|STANDARD_HASH|LISTAGG|NVL2|REGEXP_\w+)\s*\(', body)
    assert not m, 'not known to the Forms: ' + (m.group(1) if m else '')


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


# -- part 2: the rules, the products, the cards, the ATMs, the users ---------------------------------------

@needs_db
def test_the_rules(cur):
    compile_ui(cur, 'BK_RULES')
    a = new_account(cur)
    iban = cur.execute('select iban from bk_account where id = :a', a=a).fetchone()[0]
    run(cur, "ui.press('CTL.SETRULE');", CTL__R_ACC_ID=str(a), CTL__R_ACC_TEXT=iban, CTL__R_OP='WDR',
        CTL__R_CHANNEL='ATM', CTL__R_MAX='150', CTL__R_DAYAMT='300')
    rid, mx, da = cur.execute("select id, max_amount, day_amount from bk_rule where account_id = :a and op = 'WDR' "
                              "and channel = 'ATM'", a=a).fetchone()
    assert (mx, da) == (150, 300) and '#%d' % rid in msgs(cur)
    # the one selected to the fields, then changed: the same rule, its values replaced
    run(cur, "ui.press('CTL.LOADRULE');", RULE__ID=str(rid), RULE__ACCOUNT_ID=str(a), RULE__IBAN=iban, RULE__OP='WDR',
        RULE__CHANNEL='ATM', RULE__MAX_AMOUNT='150', RULE__DAY_AMOUNT='300')
    assert (item(cur, 'CTL.R_ACC_ID'), item(cur, 'CTL.R_MAX'), item(cur, 'CTL.R_OP')) == (str(a), '150', 'WDR')
    run(cur, "ui.press('CTL.SETRULE');", CTL__R_ACC_ID=str(a), CTL__R_ACC_TEXT=iban, CTL__R_OP='WDR',
        CTL__R_CHANNEL='ATM', CTL__R_MAX='200')
    assert cur.execute('select max_amount, day_amount from bk_rule where id = :r', r=rid).fetchone() == (200, None)
    assert 'BK-132' in fails(cur, "ui.press('CTL.SETRULE');", CTL__R_OP='XXX', CTL__R_CHANNEL='*')
    run(cur, "ui.press('CTL.REMOVERULE');", RULE__ID=str(rid))
    assert cur.execute('select count(*) from bk_rule where id = :r', r=rid).fetchone()[0] == 0
    # a teller: no save, no remove
    run(cur, 'ui.init;', GLOBAL__BK_TOKEN=LOGIN['teller'])
    assert prop(cur, 'CTL.SETRULE#11') == 'FALSE' and prop(cur, 'CTL.REMOVERULE#11') == 'FALSE'


@needs_db
def test_the_products_and_their_rates(cur):
    compile_ui(cur, 'BK_PRODUCTS')
    run(cur, 'ui.init;', GLOBAL__BK_TOKEN=LOGIN['teller'])
    assert prop(cur, 'BLOCK PROD#13') == 'FALSE' and prop(cur, 'CTL.SETRATE#11') == 'FALSE'   # read only
    run(cur, 'ui.init;')
    assert prop(cur, 'BLOCK PROD#13') is None
    day = cur.execute("select bk_core.open_day from dual").fetchone()[0]
    assert item(cur, 'CTL.N_FROM') == day.strftime('%d/%m/%Y')
    # a product of its own (TF1: not that of test_api, whose rates it sets itself)
    pid = cur.execute("select id from bk_product where code = 'TF1'").fetchone()
    if not pid:
        cur.execute("insert into bk_product (code, name, kind, day_basis, cap_every, tax_rate, od_rate) "
                    "values ('TF1', 'Test forms', 'CUR', 'ACT365', 'Q', 15, 10)")
        cur.connection.commit()
        pid = cur.execute("select id from bk_product where code = 'TF1'").fetchone()
    run(cur, "ui.press('CTL.SETRATE');", PROD__ID=str(pid[0]), CTL__N_FROM=day.strftime('%d/%m/%Y'), CTL__N_MIN='70000',
        CTL__N_RATE='2,5'.replace(',', '.'))
    assert cur.execute('select rate from bk_rate where product_id = :p and valid_from = :d and min_balance = 70000',
                       p=pid[0], d=day).fetchone()[0] == 2.5
    assert 'εργάσιμη' in fails(cur, "ui.press('CTL.SETRATE');", PROD__ID=str(pid[0]), CTL__N_FROM='01/01/2020', CTL__N_RATE='1')


@needs_db
def test_the_cards_and_their_pin(cur):
    compile_ui(cur, 'BK_CARDS')
    a = new_account(cur, 100)
    iban = cur.execute('select iban from bk_account where id = :a', a=a).fetchone()[0]
    run(cur, "ui.press('CTL.NEWCARD');", CTL__C_ACC_ID=str(a), CTL__C_ACC_TEXT=iban)
    k, pan, h, s, n = cur.execute('select id, pan, pin_hash, pin_salt, pin_iter from bk_card where account_id = :a', a=a).fetchone()
    pin = item(cur, 'CTL.C_PIN')[:4]
    assert pin.isdigit() and pan in item(cur, 'CTL.C_PIN') and pan in msgs(cur)
    # the hash of the PIN as bk-api (Java: PBKDF2WithHmacSHA256) and the ATM read it
    assert n == 120000 and hashlib.pbkdf2_hmac('sha256', pin.encode(), s, n) == h
    run(cur, "ui.press('CTL.BLOCKCARD');", CARD__ID=str(k), CARD__PAN=pan)
    assert cur.execute('select status from bk_card where id = :k', k=k).fetchone()[0] == 'B' and item(cur, 'CTL.C_PIN') is None
    run(cur, "ui.press('CTL.ACTIVATE');", CARD__ID=str(k), CARD__PAN=pan)
    run(cur, "ui.press('CTL.NEWPIN');", CARD__ID=str(k), CARD__PAN=pan)
    pin2 = item(cur, 'CTL.C_PIN')[:4]
    h2, s2 = cur.execute('select pin_hash, pin_salt from bk_card where id = :k', k=k).fetchone()
    assert hashlib.pbkdf2_hmac('sha256', pin2.encode(), s2, 120000) == h2 and pin2 not in ('1234', '0000')
    run(cur, "ui.press('CTL.CANCELCARD');", CARD__ID=str(k), CARD__PAN=pan)
    assert 'BK-134' in fails(cur, "ui.press('CTL.NEWPIN');", CARD__ID=str(k), CARD__PAN=pan)
    run(cur, 'ui.init;', GLOBAL__BK_TOKEN=LOGIN['teller'])
    assert prop(cur, 'CTL.CANCELCARD#11') == 'FALSE' and prop(cur, 'CTL.NEWPIN#11') is None


@needs_db
def test_the_atms(cur):
    compile_ui(cur, 'BK_ATMS')
    run(cur, 'ui.init;')
    assert item(cur, 'CTL.S_NOTES') == '20,50' and item(cur, 'CTL.S_MAX') == '40'
    aid = cur.execute("select id from bk_atm where code = 'ATM03'").fetchone()[0]
    before = cur.execute('select pieces from bk_atm_note where atm_id = :a and note = 20', a=aid).fetchone()[0]
    run(cur, "ui.press('CTL.FILL');", ATMS__ID=str(aid), ATMS__CODE='ATM03', CTL__F_NOTE='20', CTL__F_PIECES='10')
    assert cur.execute('select pieces from bk_atm_note where atm_id = :a and note = 20', a=aid).fetchone()[0] == before + 10
    run(cur, "ui.press('CTL.FILL');", ATMS__ID=str(aid), ATMS__CODE='ATM03', CTL__F_NOTE='20', CTL__F_PIECES='-10')
    assert 'BK-140' in fails(cur, "ui.press('CTL.SETNOTES');", CTL__S_NOTES='20,30', CTL__S_MAX='40')
    run(cur, "ui.press('CTL.SETNOTES');", CTL__S_NOTES='20,50', CTL__S_MAX='40')
    assert cur.execute('select count(*) from bk_check').fetchone()[0] == 0


@needs_db
def test_the_users(cur):
    compile_ui(cur, 'BK_USERS')
    run(cur, 'ui.init;')                                   # a manager: not an ADMIN
    assert prop(cur, 'NEW_FORM') == 'BK_MAIN'
    admin = 'tst-fa-' + uuid.uuid4().hex[:6]
    salt = os.urandom(16)
    cur.execute("insert into bk_user (username, full_name, role, pw_hash, pw_salt, pw_iter) values (:u, 'Test', 'ADMIN', :h, :s, 1000)",
                u=admin, h=hashlib.pbkdf2_hmac('sha256', PW.encode(), salt, 1000), s=salt)
    cur.connection.commit()
    t = token_of(cur, admin)
    run(cur, 'ui.init;', GLOBAL__BK_TOKEN=t)
    assert prop(cur, 'NEW_FORM') is None
    name = 'tst-fn-' + uuid.uuid4().hex[:6]
    assert 'ίδιοι' in fails(cur, "ui.press('CTL.NEWUSER');", GLOBAL__BK_TOKEN=t, CTL__U_NAME=name, CTL__U_FULL='Test',
                            CTL__U_ROLE='TELLER', CTL__U_PW=PW, CTL__U_PW2='other')
    run(cur, "ui.press('CTL.NEWUSER');", GLOBAL__BK_TOKEN=t, CTL__U_NAME=name, CTL__U_FULL='Test Νέος', CTL__U_ROLE='TELLER',
        CTL__U_PW=PW, CTL__U_PW2=PW)
    uid, h, s, n = cur.execute('select id, pw_hash, pw_salt, pw_iter from bk_user where username = :u', u=name).fetchone()
    assert hashlib.pbkdf2_hmac('sha256', PW.encode(), s, n) == h and n == 120000        # (as bk-api: Java can check it)
    assert token_of(cur, name)                                                          # and BK_AUTH
    run(cur, "ui.press('CTL.SETROLE');", GLOBAL__BK_TOKEN=t, USR__ID=str(uid), CTL__U_ROLE='MANAGER')
    assert cur.execute('select role from bk_user where id = :u', u=uid).fetchone()[0] == 'MANAGER'
    run(cur, "ui.press('CTL.SETPW');", GLOBAL__BK_TOKEN=t, USR__ID=str(uid), CTL__U_PW='Allos-kodikos-1', CTL__U_PW2='Allos-kodikos-1')
    assert 'BK-141' in str(pytest.raises(oracledb.DatabaseError, token_of, cur, name).value)
    run(cur, "ui.press('CTL.TOGGLEACT');", GLOBAL__BK_TOKEN=t, USR__ID=str(uid))
    assert cur.execute('select active from bk_user where id = :u', u=uid).fetchone()[0] == 'N'
    assert 'BK-144' in fails(cur, "ui.press('CTL.NEWUSER');", GLOBAL__BK_TOKEN=t, CTL__U_NAME='X Y', CTL__U_FULL='Test',
                             CTL__U_ROLE='TELLER', CTL__U_PW=PW, CTL__U_PW2=PW)
    # always an active ADMIN: the only one cannot leave
    others = cur.execute("select count(*) from bk_user where role = 'ADMIN' and active = 'Y' and username <> :u", u=admin).fetchone()[0]
    if others == 0:
        aid = cur.execute('select id from bk_user where username = :u', u=admin).fetchone()[0]
        assert 'BK-144' in fails(cur, "ui.press('CTL.SETROLE');", GLOBAL__BK_TOKEN=t, USR__ID=str(aid), CTL__U_ROLE='TELLER')
    cur.execute("delete from bk_user where username in (:a, :b)", a=admin, b=name)
    cur.connection.commit()


@needs_db
def test_the_menu_by_role(cur):
    compile_ui(cur, 'BK_MAIN')
    run(cur, 'ui.init;', GLOBAL__BK_TOKEN=LOGIN['teller'])
    assert prop(cur, 'CTL.GO_BK_USERS#11') == 'FALSE' and prop(cur, 'MENU SETUP_MENU.USERS#11') == 'FALSE'
    assert prop(cur, 'CTL.GO_BK_CARDS#11') is None


@needs_db
def test_the_reports_of_an_account(cur):
    """the buttons of the reports: the address of the Reports Server (REPORTS_URL) with the report, the format
    and its parameters, in a new window; the interest counted first"""
    compile_ui(cur, 'BK_ACCOUNTS')
    a = new_account(cur, 100)
    old = cur.execute("select name, value from bk_setting where name like 'REPORTS%'").fetchall()
    try:
        cur.execute("delete from bk_setting where name like 'REPORTS%'")
        cur.connection.commit()
        assert 'SET_REPORTS_URL' in fails(cur, "ui.press('CTL.PRINTST');", ACC__ID=str(a), CTL__P_FROM='01/01/2026',
                                          CTL__P_TO='31/12/2026')
        cur.execute("insert into bk_setting (name, value) values ('REPORTS_URL', 'http://x:9012/reports/rwservlet?bank')")
        cur.connection.commit()
        run(cur, "ui.press('CTL.PRINTST');", ACC__ID=str(a), CTL__P_FROM='01/01/2026', CTL__P_TO='31/12/2026')
        assert prop(cur, 'SHOW_DOCUMENT') == ('http://x:9012/reports/rwservlet?bank&report=BK_STATEMENT.rdf&destype=cache'
                                              '&desformat=PDF&P_KIND=S&P_ACCOUNT=%d&P_FROM=01/01/2026&P_TO=31/12/2026 _blank' % a)
        cur.execute("insert into bk_setting (name, value) values ('REPORTS_FORMAT', 'HTML')")
        cur.connection.commit()
        run(cur, "ui.press('CTL.PRINTINT');", ACC__ID=str(a), CTL__P_FROM='1/2/2026', CTL__P_TO='28/02/2026')
        assert 'BK_INTEREST.rdf&destype=cache&desformat=HTML&P_KIND=I&P_ACCOUNT=%d&P_FROM=01/02/2026&P_TO=28/02/2026' % a \
            in prop(cur, 'SHOW_DOCUMENT')
        assert 'Πρώτα' in fails(cur, "ui.press('CTL.PRINTST');", CTL__P_FROM='01/01/2026', CTL__P_TO='31/12/2026')
        assert 'διάστημα' in fails(cur, "ui.press('CTL.PRINTST');", ACC__ID=str(a), CTL__P_FROM='01/02/2026',
                                   CTL__P_TO='01/01/2026')
    finally:
        cur.execute("delete from bk_setting where name like 'REPORTS%'")
        for n, v in old:
            cur.execute('insert into bk_setting (name, value) values (:n, :v)', n=n, v=v)
        cur.connection.commit()


@needs_db
def test_the_credit_cards(cur):
    """a new card for a customer (its PIN once), a purchase, payments from an account and in cash, the limit, the
    statement chosen printed (BK_CC_STATEMENT, its period)"""
    compile_ui(cur, 'BK_CCARDS')
    c = cur.callfunc('bk_core.new_customer', int, ['Test Φόρμες κάρτα %d' % random.randrange(10 ** 6), afm()])
    cur.connection.commit()
    assert 'Πρώτα ο πελάτης' in fails(cur, "ui.press('CTL.NEWCC');", CTL__N_PRODUCT='VISA', CTL__N_LIMIT='1000')
    run(cur, "ui.press('CTL.NEWCC');", CTL__N_CUST_ID=str(c), CTL__N_PRODUCT='VISA', CTL__N_LIMIT='1000', CTL__N_DAY='12')
    a, day = cur.execute("select k.account_id, k.stmt_day from bk_ccard k join bk_holder h on h.account_id = k.account_id "
                         "where h.customer_id = :c", c=c).fetchone()
    assert day == 12 and 'CC:id = %d;' % a in queries(cur)
    assert re.match(r'^\d{4}   \(4\d{15}\)$', item(cur, 'CTL.C_RESULT')) and 'Νέα πιστωτική κάρτα' in msgs(cur)
    run(cur, "ui.press('CTL.BUY');", CC__ID=str(a), CTL__Q_AMOUNT='200', CTL__Q_MERCHANT='Test βιβλιοπωλείο')
    assert 'Αγορά: εγγραφή #' in msgs(cur) and item(cur, 'CTL.Q_AMOUNT') is None
    p = new_account(cur, 500)
    run(cur, "ui.press('CTL.PAYCC');", CC__ID=str(a), CTL__P_FROM_ID=str(p), CTL__P_AMOUNT='50')
    run(cur, "ui.press('CTL.PAYCASH');", CC__ID=str(a), CTL__P_AMOUNT='20')
    assert cur.execute('select balance from bk_account where id = :a', a=a).fetchone()[0] == -130
    assert cur.execute('select balance from bk_account where id = :p', p=p).fetchone()[0] == 450
    assert 'Πρώτα ο λογαριασμός' in fails(cur, "ui.press('CTL.PAYCC');", CC__ID=str(a), CTL__P_AMOUNT='5')
    run(cur, "ui.press('CTL.SETLIMIT');", CC__ID=str(a), CTL__L_LIMIT='100')
    assert cur.execute('select available from bk_ccard_v where id = :a', a=a).fetchone()[0] == -30
    assert 'BK-147' in fails(cur, "ui.press('CTL.BUY');", CC__ID=str(a), CTL__Q_AMOUNT='1')
    assert 'Πρώτα μια κάρτα' in fails(cur, "ui.press('CTL.BUY');", CTL__Q_AMOUNT='1')
    # the statement chosen: its report, with its period
    assert 'Πρώτα μια κίνηση' in fails(cur, "ui.press('CTL.PRINTSTMT');", CC__ID=str(a))
    old = cur.execute("select name, value from bk_setting where name like 'REPORTS%'").fetchall()
    try:
        cur.execute("delete from bk_setting where name like 'REPORTS%'")
        cur.execute("insert into bk_setting (name, value) values ('REPORTS_URL', 'http://x:9012/reports/rwservlet?bank')")
        cur.connection.commit()
        run(cur, "ui.press('CTL.PRINTSTMT');", CC__ID=str(a), CST__STMT_TEXT='12/11/2026', CST__FROM_TEXT='13/10/2026')
        assert prop(cur, 'SHOW_DOCUMENT') == ('http://x:9012/reports/rwservlet?bank&report=BK_CC_STATEMENT.rdf&destype=cache'
                                              '&desformat=PDF&P_KIND=C&P_ACCOUNT=%d&P_FROM=13/10/2026&P_TO=12/11/2026 _blank' % a)
    finally:
        cur.execute("delete from bk_setting where name like 'REPORTS%'")
        for n, v in old:
            cur.execute('insert into bk_setting (name, value) values (:n, :v)', n=n, v=v)
        cur.connection.commit()


@needs_db
def test_the_currencies_in_the_forms(cur):
    """BK_FX: a currency saved, its rate, active or not, an amount converted; an account in USD (BK_CUSTOMERS); a
    transfer to it (BK_MOVE: what it got); the amount it was in (post_query); the currencies and a rate of a
    product in USD (BK_PRODUCTS)"""
    compile_ui(cur, 'BK_FX')
    run(cur, "ui.press('CTL.SAVECUR');", CTL__S_CODE='xts', CTL__S_NAME='Test νόμισμα', CTL__S_DEC='2', CTL__S_SPREAD='1')
    xid = cur.execute("select id from bk_currency_v where code = 'XTS'").fetchone()[0]
    assert 'CURR:id = %d;' % xid in queries(cur) and 'XTS' in msgs(cur)
    assert cur.execute("select name, spread_pct, active from bk_currency where code = 'XTS'").fetchone() == ('Test νόμισμα', 1, 'Y')
    day = cur.execute("select to_char(bk_core.open_day, 'DD/MM/YYYY') from dual").fetchone()[0]
    assert 'Πρώτα ένα νόμισμα' in fails(cur, "ui.press('CTL.SETFX');", CTL__R_DAY=day, CTL__R_MID='2')
    run(cur, "ui.press('CTL.SETFX');", CURR__ID=str(xid), CURR__CODE='XTS', CTL__R_DAY=day, CTL__R_MID='2')
    assert cur.execute("select mid from bk_currency_v where code = 'XTS'").fetchone()[0] == 2
    run(cur, "ui.press('CTL.CONVERT');", CTL__X_AMOUNT='100', CTL__X_FROM='EUR', CTL__X_TO='XTS')
    assert item(cur, 'CTL.X_RESULT') == '100,00 € = 200,00 XTS  ·  ο πελάτης παίρνει 198,00 XTS'
    assert 'BK-152' in fails(cur, "ui.press('CTL.SETFX');", CURR__ID=str(xid), CURR__CODE='XTS', CTL__R_DAY=day, CTL__R_MID='0')
    run(cur, "ui.press('CTL.TOGGLECUR');", CURR__ID=str(xid), CURR__CODE='XTS')
    assert cur.execute("select active from bk_currency where code = 'XTS'").fetchone()[0] == 'N'
    run(cur, "ui.press('CTL.TOGGLECUR');", CURR__ID=str(xid), CURR__CODE='XTS')         # (again: the next run)
    assert cur.execute("select active from bk_currency where code = 'XTS'").fetchone()[0] == 'Y'
    # an account in USD; a transfer to it from one in EUR
    compile_ui(cur, 'BK_CUSTOMERS')
    c = cur.callfunc('bk_core.new_customer', int, ['Test Φόρμες νόμισμα %d' % random.randrange(10 ** 6), afm()])
    cur.connection.commit()
    run(cur, "ui.press('CTL.NEWACC');", CUST__ID=str(c), CTL__A_PRODUCT='CUR', CTL__A_OD='0', CTL__A_CURRENCY='USD')
    u = cur.execute("select account_id from bk_customer_account_v where customer_id = :c and currency = 'USD'", c=c).fetchone()[0]
    assert '(USD, ' in msgs(cur)
    assert 'BK-153' in fails(cur, "ui.press('CTL.NEWACC');", CUST__ID=str(c), CTL__A_PRODUCT='SAVP', CTL__A_OD='0',
                             CTL__A_CURRENCY='USD')
    compile_ui(cur, 'BK_MOVE')
    a = new_account(cur, 500)
    run(cur, "ui.press('CTL.SAVE');", CTL__M_ACC_ID=str(a), CTL__M_KIND='TRF', CTL__M_TO_ID=str(u), CTL__M_AMOUNT='100',
        CTL__M_KIND_TEXT='Μεταφορά', CTL__M_VDATE=day)
    got = cur.execute("select balance from bk_account where id = :u", u=u).fetchone()[0]
    assert got > 0 and item(cur, 'CTL.M_RESULT').endswith(' 100,00 € → %s USD' % ('%.2f' % got).replace('.', ','))
    run(cur, "ui.post_query('LAST');", CTL__M_ACC_ID=str(u), LAST__ENTRY_ID='1', LAST__LINE_ID='1', LAST__KIND='TRF',
        LAST__OP='TRI', LAST__ORIG_AMOUNT='100', LAST__ORIG_CURRENCY='EUR', LAST__FX_RATE='1.2438', SYSTEM__TRIGGER_RECORD='1')
    assert item(cur, 'LAST.ORIG_TEXT') == '100,00 € × 1,2438'
    # a product: its currencies, a rate in USD
    compile_ui(cur, 'BK_PRODUCTS')
    pid = cur.execute("select id from bk_product where code = 'TF1'").fetchone()
    if pid:
        run(cur, "ui.press('CTL.SETCURS');", PROD__ID=str(pid[0]), PROD__CODE='TF1', CTL__P_CURS='eur,usd')
        assert cur.execute("select currencies from bk_product where id = :p", p=pid[0]).fetchone()[0] == 'EUR,USD'
        assert 'BK-153' in fails(cur, "ui.press('CTL.SETCURS');", PROD__ID=str(pid[0]), PROD__CODE='TF1', CTL__P_CURS='EUR,EUR')
        run(cur, "ui.press('CTL.SETRATE');", PROD__ID=str(pid[0]), CTL__N_FROM=day, CTL__N_MIN='0', CTL__N_RATE='1.5',
            CTL__N_CURRENCY='USD')
        assert cur.execute("select rate from bk_rate where product_id = :p and currency = 'USD'", p=pid[0]).fetchone()[0] == 1.5


@needs_db
def test_the_loans(cur):
    """its installment first, a new loan (to an account of the customer), what pays it off, a prepayment (the same
    installment, fewer), its schedule printed (BK_LN_SCHEDULE), paid off"""
    compile_ui(cur, 'BK_LOANS')
    run(cur, 'ui.init;')
    assert item(cur, 'CTL.P_MODE_TEXT') == 'Ίδια δόση, λιγότερες δόσεις'
    run(cur, "ui.press('CTL.QUOTE');", CTL__N_PRODUCT='CONS', CTL__N_AMOUNT='12000', CTL__N_MONTHS='24')
    r = 0.095 / 12
    want = round(12000 * r / (1 - (1 + r) ** -24), 2)
    assert item(cur, 'CTL.N_RESULT').startswith('Δόση %s € × 24 μήνες' % ('{:,.2f}'.format(want).replace(',', 'X').replace('.', ',').replace('X', '.')))
    assert 'Πρώτα ο λογαριασμός' in fails(cur, "ui.press('CTL.NEWLOAN');", CTL__N_PRODUCT='CONS', CTL__N_AMOUNT='12000',
                                          CTL__N_MONTHS='24')
    p = new_account(cur, 500)
    run(cur, "ui.press('CTL.NEWLOAN');", CTL__N_PAY_ID=str(p), CTL__N_PRODUCT='CONS', CTL__N_AMOUNT='12000',
        CTL__N_MONTHS='24', CTL__N_DAY='10')
    a = cur.execute('select account_id from bk_loan where pay_account_id = :p', p=p).fetchone()[0]
    assert 'LN:id = %d;' % a in queries(cur) and 'Νέο δάνειο' in msgs(cur)
    assert cur.execute('select balance from bk_account where id = :p', p=p).fetchone()[0] == 12500
    assert 'BK-156' in fails(cur, "ui.press('CTL.NEWLOAN');", CTL__N_PAY_ID=str(p), CTL__N_PRODUCT='CONS',
                             CTL__N_AMOUNT='1000', CTL__N_MONTHS='100')
    run(cur, "ui.press('CTL.PAYOFF');", LN__ID=str(a))
    off = cur.callfunc('bk_core.ln_payoff', float, [a])
    assert item(cur, 'CTL.X_PAYOFF') == '{:,.2f} €'.format(off).replace(',', 'X').replace('.', ',').replace('X', '.')
    run(cur, "ui.press('CTL.PREPAY');", LN__ID=str(a), CTL__P_AMOUNT='2000', CTL__P_MODE='T')
    assert 'Πρόωρη εξόφληση' in msgs(cur)
    assert cur.execute("select count(*) from bk_ln_schedule where account_id = :a and status = 'D'", a=a).fetchone()[0] < 24
    old = cur.execute("select name, value from bk_setting where name like 'REPORTS%'").fetchall()
    try:
        cur.execute("delete from bk_setting where name like 'REPORTS%'")
        cur.execute("insert into bk_setting (name, value) values ('REPORTS_URL', 'http://x:9012/reports/rwservlet?bank')")
        cur.connection.commit()
        run(cur, "ui.press('CTL.PRINTSCH');", LN__ID=str(a))
        d = cur.execute("select to_char(start_date, 'DD/MM/YYYY') from bk_loan where account_id = :a", a=a).fetchone()[0]
        assert prop(cur, 'SHOW_DOCUMENT') == ('http://x:9012/reports/rwservlet?bank&report=BK_LN_SCHEDULE.rdf&destype=cache'
                                              '&desformat=PDF&P_KIND=L&P_ACCOUNT=%d&P_FROM=%s&P_TO=31/12/2100 _blank' % (a, d))
    finally:
        cur.execute("delete from bk_setting where name like 'REPORTS%'")
        for n, v in old:
            cur.execute('insert into bk_setting (name, value) values (:n, :v)', n=n, v=v)
        cur.connection.commit()
    run(cur, "ui.press('CTL.PAYALL');", LN__ID=str(a))
    assert 'εξοφλήθηκε' in msgs(cur)
    assert cur.execute('select status from bk_loan where account_id = :a', a=a).fetchone()[0] == 'C'
    assert 'Πρώτα ένα δάνειο' in fails(cur, "ui.press('CTL.PAYOFF');")


@needs_db
def test_the_branches_in_the_forms(cur):
    """BK_BRANCHES: a branch new, changed, inactive and again active; an account opened in a branch and moved to
    another (its IBAN as it was); an ATM and a user in a branch"""
    compile_ui(cur, 'BK_BRANCHES')
    run(cur, "ui.press('CTL.SAVEBR');", CTL__S_CODE='9101', CTL__S_NAME='Test Φόρμες', CTL__S_CITY='Βόλος', CTL__S_ADDRESS='Test 1')
    assert cur.execute("select name, city, active from bk_branch where code = '9101'").fetchone() == ('Test Φόρμες', 'Βόλος', 'Y')
    assert 'BR:id = 9101;' in queries(cur)
    run(cur, "ui.press('CTL.SAVEBR');", CTL__S_CODE='9101', CTL__S_NAME='Test Φόρμες 2', CTL__S_CITY='Βόλος')
    assert cur.execute("select name from bk_branch where code = '9101'").fetchone()[0] == 'Test Φόρμες 2'
    assert 'BK-' in fails(cur, "ui.press('CTL.SAVEBR');", CTL__S_CODE='12', CTL__S_NAME='Test')
    run(cur, "ui.press('CTL.TOGGLEBR');", BR__ID='9101', BR__CODE='9101')
    assert cur.execute("select active from bk_branch where code = '9101'").fetchone()[0] == 'N'
    run(cur, "ui.press('CTL.TOGGLEBR');", BR__ID='9101', BR__CODE='9101')
    assert cur.execute("select active from bk_branch where code = '9101'").fetchone()[0] == 'Y'
    assert cur.execute("select code, accounts from bk_branch_v where code = '9101'").fetchone()[0] == '9101'

    compile_ui(cur, 'BK_CUSTOMERS')
    a = afm()
    run(cur, "ui.press('CTL.NEWCUST');", CTL__C_NAME='Test Υποκ. Πελάτης', CTL__C_AFM=a)
    cid = cur.execute('select id from bk_customer where afm = :a', a=a).fetchone()[0]
    run(cur, "ui.press('CTL.NEWACC');", CUST__ID=str(cid), CTL__A_PRODUCT='CUR', CTL__A_BRANCH='9101')
    acc, iban, br = cur.execute('select a.id, a.iban, a.branch_code from bk_account a, bk_holder h where h.account_id = a.id '
                                'and h.customer_id = :c', c=cid).fetchone()
    assert br == '9101' and iban[7:11] == '9101'

    compile_ui(cur, 'BK_ACCOUNTS')
    run(cur, "ui.press('CTL.MOVEBR');", ACC__ID=str(acc), CTL__B_BRANCH='0002')
    assert cur.execute('select iban, branch_code from bk_account where id = :a', a=acc).fetchone() == (iban, '0002')
    assert 'Πρώτα' in fails(cur, "ui.press('CTL.MOVEBR');", CTL__B_BRANCH='0002')

    compile_ui(cur, 'BK_ATMS')
    aid, old = cur.execute("select id, branch_code from bk_atm where code = 'ATM03'").fetchone()
    run(cur, "ui.press('CTL.SETATMBR');", ATMS__ID=str(aid), ATMS__CODE='ATM03', CTL__M_BRANCH='9101')
    assert cur.execute('select branch_code from bk_atm where id = :a', a=aid).fetchone()[0] == '9101'
    run(cur, "ui.press('CTL.SETATMBR');", ATMS__ID=str(aid), ATMS__CODE='ATM03', CTL__M_BRANCH=old)

    compile_ui(cur, 'BK_USERS')
    admin = 'tst-fa-' + uuid.uuid4().hex[:6]
    salt = os.urandom(16)
    cur.execute("insert into bk_user (username, full_name, role, pw_hash, pw_salt, pw_iter) values (:u, 'Test', 'ADMIN', :h, :s, 1000)",
                u=admin, h=hashlib.pbkdf2_hmac('sha256', PW.encode(), salt, 1000), s=salt)
    cur.connection.commit()
    t = token_of(cur, admin)
    name = 'tst-fn-' + uuid.uuid4().hex[:6]
    run(cur, "ui.press('CTL.NEWUSER');", GLOBAL__BK_TOKEN=t, CTL__U_NAME=name, CTL__U_FULL='Test Υποκ.', CTL__U_ROLE='TELLER',
        CTL__U_PW=PW, CTL__U_PW2=PW, CTL__U_BRANCH='9101')
    uid, br = cur.execute('select id, branch_code from bk_user where username = :u', u=name).fetchone()
    assert br == '9101'
    run(cur, "ui.press('CTL.SETUBR');", GLOBAL__BK_TOKEN=t, USR__ID=str(uid), USR__USERNAME=name, CTL__U_BRANCH='0003')
    assert cur.execute('select branch_code from bk_user where id = :u', u=uid).fetchone()[0] == '0003'
    cur.execute("delete from bk_user where username in (:a, :b)", a=admin, b=name)
    cur.connection.commit()
    assert cur.execute('select count(*) from bk_check').fetchone()[0] == 0


@needs_db
def test_the_branch_filter_and_the_cash_report(cur):
    """the list of one branch only (CTL.FILTERBR; empty: all) in the accounts, the cards, the loans; the report of
    the cash of a branch"""
    for form, block in (('BK_ACCOUNTS', 'ACC'), ('BK_CCARDS', 'CC'), ('BK_LOANS', 'LN')):
        compile_ui(cur, form)
        run(cur, "ui.press('CTL.FILTERBR');", CTL__F_BRANCH='0002')
        assert "%s:branch_code = '0002';" % block in queries(cur) and '0002' in msgs(cur)
        assert 'Δεν υπάρχει' in fails(cur, "ui.press('CTL.FILTERBR');", CTL__F_BRANCH='9999')
        run(cur, "ui.press('CTL.FILTERBR');", CTL__F_BRANCH='')
        assert 'Όλα' in msgs(cur) and "branch_code" not in queries(cur)
    compile_ui(cur, 'BK_BRANCHES')
    old = cur.execute("select name, value from bk_setting where name like 'REPORTS%'").fetchall()
    try:
        cur.execute("delete from bk_setting where name like 'REPORTS%'")
        cur.execute("insert into bk_setting (name, value) values ('REPORTS_URL', 'http://x:9012/reports/rwservlet?bank')")
        cur.connection.commit()
        run(cur, "ui.press('CTL.PRINTCASH');", BR__CODE='0002', CTL__P_FROM='01/01/2026', CTL__P_TO='31/01/2026')
        assert prop(cur, 'SHOW_DOCUMENT') == ('http://x:9012/reports/rwservlet?bank&report=BK_BR_CASH.rdf&destype=cache'
                                              '&desformat=PDF&P_KIND=B&P_ACCOUNT=2&P_FROM=01/01/2026&P_TO=31/01/2026 _blank')
        assert 'Πρώτα' in fails(cur, "ui.press('CTL.PRINTCASH');", CTL__P_FROM='01/01/2026', CTL__P_TO='31/01/2026')
    finally:
        cur.execute("delete from bk_setting where name like 'REPORTS%'")
        for n, v in old:
            cur.execute('insert into bk_setting (name, value) values (:n, :v)', n=n, v=v)
        cur.connection.commit()
