#!/usr/bin/env python3
"""mkforms.py -- the forms of the bank in the XML of Oracle Forms 14 (XML2Forms makes the .fmb, frmcmp the .fmx:
build_forms.sh on the Forms server, forms1). The same way as the forms of the mini market:

  BK_LOGIN      the login: the users of the pages (BK_USER, bk-api), checked by BK_AUTH (PBKDF2 in the database)
  BK_MAIN       the first menu: a button for each form, the business day
  BK_CUSTOMERS  the customers (their data corrected in place; a new one by BK_CORE), their accounts below; a new
                account for the customer on the screen
  BK_ACCOUNTS   the accounts, the moves of the one on the screen below with their running balance; its status,
                its overdraft limit, its interest up to the last day closed, a reversal, its close
  BK_MOVE       a movement at the counter: a deposit, a withdrawal, a transfer (in the bank, to or from another
                bank), its value date; the last moves of the account below
  BK_DAY        the business day, BK_CHECK, the close of the day

Each form: a block CTL (Find... with a LOV, All, its own fields and buttons), its blocks, a toolbar (TB) and the
bar of menus BK_MENU. Everything that writes goes through BK_CORE (its errors BK-1xx shown as they are), then
COMMIT. The forms are ASCII: XML2Forms does not carry Greek into a form; the prompts, labels, titles and messages
are in the package BK_TEXT of the database (../db/BK_TEXT.sql, written here too), and ui.init sets them when the
form opens. The logic of all the forms: BK_UI.pls (the package UI of each form).

  python3 mkforms.py        (writes BK_*.xml here and ../db/BK_TEXT.sql)
"""
import hashlib
import os
import re
from xml.sax.saxutils import quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(HERE, '..', 'db')
CANVAS, WINDOW = 'CNV', 'WIN'
ROWS, ROW_H = 15, 22
TOP = 80                        # the first row of the block (the prompts above it)

GREEKLISH = dict(zip('ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩαβγδεζηθικλμνξοπρσςτυφχψωάέήίόύώΆΈΉΊΌΎΏϊϋΐΰ',
                     ['A', 'V', 'G', 'D', 'E', 'Z', 'I', 'Th', 'I', 'K', 'L', 'M', 'N', 'X', 'O', 'P',
                      'R', 'S', 'T', 'Y', 'F', 'Ch', 'Ps', 'O', 'a', 'v', 'g', 'd', 'e', 'z', 'i',
                      'th', 'i', 'k', 'l', 'm', 'n', 'x', 'o', 'p', 'r', 's', 's', 't', 'y', 'f',
                      'ch', 'ps', 'o', 'a', 'e', 'i', 'i', 'o', 'y', 'o', 'A', 'E', 'I', 'I', 'O',
                      'Y', 'O', 'i', 'y', 'i', 'y']))


def greeklish(s):
    return ''.join(GREEKLISH.get(c, c) for c in s).replace('€', 'EUR').replace('·', '-').replace('→', '->')


def nonascii(s):
    return any(ord(c) > 127 for c in s)


class Words:
    """The Greek of all the forms: a key from the md5 of the text (a new layout keeps it)."""
    def __init__(self):
        self.words = {}

    def key(self, text):
        k = 'T' + hashlib.md5(text.encode('utf-8')).hexdigest()[:8].upper()
        assert self.words.get(k, text) == text, 'two words, one key: ' + text
        self.words[k] = text
        return k


WORDS = Words()
MONEY = '999G999G990D00'


def C(name, prompt, width, **o):
    """a column of a block: (name, prompt, width, options)
       db=False not a column of the table; hidden=True not on the canvas; num=True a number; date=True a date;
       len the maximum length; lov its LOV; display=True read only; check=True a check box Y/N; init its
       initial value; req=True required; upper=True capitals; mask the format mask of a number"""
    return dict(name=name, prompt=prompt, width=width, **o)


# the statement of an account: its lines (BK_STATEMENT_LINE), the newest first; the running balance and the words
# of the kind of each (ui.post_query)
def statement_cols():
    return [C('LINE_ID', '', 0, num=True, hidden=True),
            C('ENTRY_ID', 'Εγγραφή', 64, num=True),
            C('BOOK_DATE', 'Λογισμός', 84, date=True),
            C('VALUE_DATE', 'Αξία', 84, date=True),
            C('KIND_TEXT', 'Κίνηση', 130, len=60, db=False, display=True),
            C('KIND', '', 0, len=3, hidden=True),
            C('OP', '', 0, len=3, hidden=True),
            C('CHANNEL', 'Κανάλι', 50, len=3),
            C('DESCR', 'Περιγραφή', 250, len=200),
            C('DEBIT', 'Χρέωση', 90, num=True, mask=MONEY),
            C('CREDIT', 'Πίστωση', 90, num=True, mask=MONEY),
            C('RUN_BALANCE', 'Υπόλοιπο', 100, num=True, db=False, display=True, mask=MONEY)]


STATEMENT_ORDER = 'book_date desc, entry_id desc, line_id desc'
ACCOUNTS_LOV = ("select id, iban || ' ' || holder text from bk_account_v where status <> 'C' order by id")
KINDS = (('DEP', 'Κατάθεση'), ('WDR', 'Ανάληψη'), ('TRF', 'Μεταφορά σε λογαριασμό της τράπεζας'),
         ('OUT', 'Μεταφορά σε άλλη τράπεζα'), ('INC', 'Μεταφορά από άλλη τράπεζα'))

FORMS = {}

# the customers: their data corrected in place (the AFM checked: ui.validate); a new one by bk_core.new_customer
# (its code), so no insert in the block; below, their accounts (as primary holder or joint)
FORMS['BK_CUSTOMERS'] = dict(
    title='Πελάτες',
    find_title='Πελάτες', find=("select id, code, name, afm from bk_customer order by name",
                               [('ID', 0, 'Κωδ.', 'FIND_ID'), ('CODE', 80, 'Κωδικός', None),
                                ('NAME', 260, 'Ονοματεπώνυμο', 'FIND_TEXT'), ('AFM', 90, 'ΑΦΜ', None)]),
    blocks=[dict(name='CUST', table='BK_CUSTOMER', order='name', top=TOP, rows=10, no_insert=True, cols=[
        C('ID', '', 0, num=True, hidden=True, query_only=True),
        C('CODE', 'Κωδικός', 70, len=12, query_only=True),
        C('NAME', 'Ονοματεπώνυμο', 200, len=100, req=True),
        C('AFM', 'ΑΦΜ', 80, len=9),
        C('ID_CARD', 'Ταυτότητα', 80, len=20),
        C('BIRTH_DATE', 'Γέννηση', 84, date=True),
        C('PHONE', 'Τηλέφωνο', 90, len=20),
        C('EMAIL', 'Email', 160, len=100),
        C('ADDRESS', 'Διεύθυνση', 190, len=200),
        C('ACTIVE', 'Ενεργός', 50, check=True, init='Y')]),
        dict(name='CA', table='BK_CUSTOMER_ACCOUNT_V', order='account_id', top=TOP + 10 * ROW_H + 40, rows=5,
             read_only=True, where='customer_id = :CUST.ID',
             cols=[C('ACCOUNT_ID', '', 0, num=True, hidden=True),
                   C('IBAN', 'IBAN', 230, len=27),
                   C('PRODUCT_NAME', 'Προϊόν', 180, len=60),
                   C('ROLE', 'Ρόλος', 46, len=1),
                   C('STATUS', 'Κατ.', 40, len=1),
                   C('BALANCE', 'Υπόλοιπο', 110, num=True, mask=MONEY),
                   C('OD_LIMIT', 'Όριο υπεραν.', 100, num=True, mask=MONEY)])],
    ctl=[('C_NAME', 'text', 10, 430, 200, 'Νέος πελάτης: ονοματεπώνυμο', {'len': 100}),
         ('C_AFM', 'text', 216, 430, 90, 'ΑΦΜ', {'len': 9}),
         ('C_PHONE', 'text', 312, 430, 100, 'Τηλέφωνο', {'len': 20}),
         ('C_EMAIL', 'text', 418, 430, 180, 'Email', {'len': 100}),
         ('NEWCUST', 'button', 604, 428, 170, 'Νέος πελάτης', {}),
         ('A_PRODUCT', 'text', 10, 480, 90, 'Προϊόν (λίστα)', {'len': 10, 'upper': True, 'lov': 'LOV_PROD', 'init': 'CUR'}),
         ('A_OD', 'text', 106, 480, 100, 'Όριο υπεραν.', {'num': True, 'init': '0'}),
         ('NEWACC', 'button', 212, 478, 300, 'Νέος λογαριασμός (του πελάτη της οθόνης)', {})],
    lovs=[('LOV_PROD', 'Προϊόντα', "select code, name from bk_product where active = 'Y' order by id",
           [('CODE', 70, 'Προϊόν', 'CTL.A_PRODUCT'), ('NAME', 220, 'Όνομα', None)])])

# the accounts: the account on the screen, its moves below (the newest first, with the running balance)
FORMS['BK_ACCOUNTS'] = dict(
    title='Λογαριασμοί',
    find_title='Λογαριασμοί', find=("select id, iban, holder from bk_account_v order by id",
                                   [('ID', 0, 'Κωδ.', 'FIND_ID'), ('IBAN', 220, 'IBAN', 'FIND_TEXT'),
                                    ('HOLDER', 240, 'Δικαιούχος', None)]),
    blocks=[dict(name='ACC', table='BK_ACCOUNT_V', order='id', top=TOP, rows=6, read_only=True,
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('IBAN', 'IBAN', 220, len=27),
                       C('PRODUCT', 'Προϊόν', 54, len=10),
                       C('HOLDER', 'Δικαιούχος', 200, len=100),
                       C('STATUS', 'Κατ.', 36, len=1),
                       C('BALANCE', 'Υπόλοιπο', 110, num=True, mask=MONEY),
                       C('OD_LIMIT', 'Όριο υπεραν.', 96, num=True, mask=MONEY),
                       C('ACCRUED', 'Δεδουλ. τόκοι', 96, num=True, mask=MONEY),
                       C('ACCRUED_TO', 'Τόκοι ως', 84, date=True),
                       C('OPENED_ON', 'Άνοιξε', 84, date=True)]),
            dict(name='ST', table='BK_STATEMENT_LINE', order=STATEMENT_ORDER, top=TOP + 6 * ROW_H + 40, rows=12,
                 read_only=True, where='account_id = :ACC.ID', cols=statement_cols())],
    ctl=[('O_LIMIT', 'text', 10, 520, 110, 'Νέο όριο υπεραν.', {'num': True}),
         ('SETOD', 'button', 126, 518, 150, 'Όριο υπεραν.', {'role': 'MANAGER'}),
         ('BLOCKACC', 'button', 282, 518, 190, 'Δέσμευση / αποδέσμευση', {'role': 'MANAGER'}),
         ('ACCRUE', 'button', 478, 518, 190, 'Τόκοι ως χθες', {}),
         ('CLOSEACC', 'button', 674, 518, 190, 'Κλείσιμο λογαριασμού', {'role': 'MANAGER'}),
         ('R_DESCR', 'text', 10, 566, 260, 'Αιτία αντιλογισμού', {'len': 200}),
         ('REVERSE', 'button', 276, 564, 280, 'Αντιλογισμός της επιλεγμένης κίνησης', {'role': 'MANAGER'}),
         ('GO_BK_MOVE', 'button', 674, 564, 190, 'Νέα κίνηση', {})])

# a movement at the counter (the channel BR): the account (a list), what (a list), the other account or IBAN, the
# amount, its value date; below, the last moves of the account
FORMS['BK_MOVE'] = dict(
    title='Κίνηση',
    blocks=[dict(name='LAST', table='BK_STATEMENT_LINE', order=STATEMENT_ORDER, top=260, rows=10, read_only=True,
                 where='account_id = -1', cols=statement_cols())],
    ctl=[('M_ACC_TEXT', 'text', 10, 24, 400, 'Λογαριασμός (λίστα)', {'len': 200, 'lov': 'LOV_ACC'}),
         ('M_ACC_ID', 'hidden', 0, 0, 0, '', {'num': True}),
         ('SHOWACC', 'button', 416, 22, 150, 'Δείξε τον', {}),
         ('M_BAL', 'display', 572, 24, 130, 'Υπόλοιπο', {'len': 30}),
         ('M_AVAIL', 'display', 708, 24, 130, 'Διαθέσιμο', {'len': 30}),
         ('M_KIND', 'text', 10, 74, 60, 'Κίνηση (λίστα)', {'len': 3, 'upper': True, 'lov': 'LOV_KIND', 'init': 'DEP'}),
         ('M_KIND_TEXT', 'display', 76, 74, 260, '', {'len': 60}),
         ('M_TO_TEXT', 'text', 342, 74, 330, 'Προς λογαριασμό της τράπεζας (λίστα)', {'len': 200, 'lov': 'LOV_TO'}),
         ('M_TO_ID', 'hidden', 0, 0, 0, '', {'num': True}),
         ('M_IBAN', 'text', 678, 74, 240, 'IBAN άλλης τράπεζας', {'len': 34, 'upper': True}),
         ('M_AMOUNT', 'text', 10, 124, 120, 'Ποσό (€)', {'num': True}),
         ('M_DESCR', 'text', 136, 124, 330, 'Περιγραφή', {'len': 200}),
         ('M_VDATE', 'date', 472, 124, 100, 'Ημερομηνία αξίας', {}),
         ('SAVE', 'button', 578, 122, 190, 'Καταχώριση', {}),
         ('M_RESULT', 'display', 10, 174, 900, 'Αποτέλεσμα', {'len': 300})],
    lovs=[('LOV_ACC', 'Λογαριασμοί', ACCOUNTS_LOV, [('ID', 0, 'Κωδ.', 'CTL.M_ACC_ID'), ('TEXT', 380, 'Λογαριασμός', 'CTL.M_ACC_TEXT')]),
          ('LOV_TO', 'Λογαριασμοί', ACCOUNTS_LOV, [('ID', 0, 'Κωδ.', 'CTL.M_TO_ID'), ('TEXT', 380, 'Λογαριασμός', 'CTL.M_TO_TEXT')]),
          ('LOV_KIND', 'Κινήσεις', ' union all '.join(
              "select '%s' code, bk_text.t('%s') descr, %d o from dual" % (c, WORDS.key(d), i)
              for i, (c, d) in enumerate(KINDS)) + ' order by 3',
           [('CODE', 50, 'Κίνηση', 'CTL.M_KIND'), ('DESCR', 260, 'Περιγραφή', 'CTL.M_KIND_TEXT'), ('O', 0, '#', None)])])

# the business day: the last closed, BK_CHECK (nothing: all agree), the close (MANAGER)
FORMS['BK_DAY'] = dict(
    title='Ημέρα και κλείσιμο',
    blocks=[],
    ctl=[('D_OPEN', 'display', 20, 30, 160, 'Εργάσιμη ημέρα', {'len': 20}),
         ('D_LAST', 'display', 186, 30, 160, 'Τελευταία κλεισμένη', {'len': 20}),
         ('D_ENTRIES', 'display', 352, 30, 160, 'Εγγραφές της ημέρας', {'len': 20}),
         ('D_CHECK', 'display', 20, 80, 492, 'Έλεγχος (BK_CHECK)', {'len': 300}),
         ('REFRESH', 'button', 20, 120, 240, 'Ξανά', {}),
         ('CLOSEDAY', 'button', 272, 120, 240, 'Κλείσιμο της ημέρας', {'role': 'MANAGER'})])

# the login: name and password (BK_AUTH, the users of the pages); the token to GLOBAL.BK_TOKEN, then the first
# menu. Every other form checks it when it opens (ui.session_ok, FORM_ROLES).
FORMS['BK_LOGIN'] = dict(
    title='Σύνδεση',
    blocks=[],
    ctl=[('L_USER', 'text', 40, 40, 220, 'Όνομα χρήστη', {'len': 30, 'lower': True}),
         ('L_PW', 'secret', 40, 90, 220, 'Κωδικός (Enter)', {'len': 200, 'enter': True}),
         ('LOGIN', 'button', 40, 130, 220, 'Σύνδεση', {}),
         ('EXIT', 'button', 40, 166, 220, 'Έξοδος', {})])

# the role each form needs (ui.session_ok: TELLER < MANAGER < ADMIN); None: the login itself
FORM_ROLES = {'BK_LOGIN': None, 'BK_MAIN': 'TELLER', 'BK_CUSTOMERS': 'TELLER', 'BK_ACCOUNTS': 'TELLER',
              'BK_MOVE': 'TELLER', 'BK_DAY': 'TELLER'}

# the first menu: a button for each form (NEW_FORM), the business day, the logout, the exit
MENU_FORMS = [('BK_CUSTOMERS', 'Πελάτες'), ('BK_ACCOUNTS', 'Λογαριασμοί'), ('BK_MOVE', 'Κίνηση'),
              ('BK_DAY', 'Ημέρα και κλείσιμο')]
FORMS['BK_MAIN'] = dict(
    title='Bank',
    blocks=[],
    ctl=[('GO_' + f, 'button', 20 + (i % 2) * 230, 60 + (i // 2) * 44, 220, t, {})
         for i, (f, t) in enumerate(MENU_FORMS)] +
        [('D_OPEN', 'display', 20, 20, 450, '', {'len': 100}),
         ('LOGOUT', 'button', 20, 60 + (len(MENU_FORMS) + 1) // 2 * 44 + 16, 220, 'Αποσύνδεση', {}),
         ('EXIT', 'button', 250, 60 + (len(MENU_FORMS) + 1) // 2 * 44 + 16, 220, 'Έξοδος', {})])

# the bar of menus of all the forms (the menu module BK_MENU, in place of DEFAULT&SMARTBAR): (menu, label,
# [(item, label, PL/SQL)]); a form opens in the place of the one on the screen (NEW_FORM: unsaved changes are
# asked first). Its Greek: ui.init of each form (SET_MENU_ITEM_PROPERTY).
MENU_MODULE = 'BK_MENU'
# the logout from the bar (the PL/SQL of a menu does not see the package UI of the form)
LOGOUT_CODE = ("BEGIN bk_auth.logout(NAME_IN('GLOBAL.BK_TOKEN')); "
               "EXCEPTION WHEN OTHERS THEN NULL; END; COPY('', 'GLOBAL.BK_TOKEN'); NEW_FORM('BK_LOGIN');")
MENU_BAR = [
    ('FILE', 'Αρχείο', [('MAIN', 'Αρχικό μενού', "new_form('BK_MAIN');"),
                        ('LOGOUT', 'Αποσύνδεση', LOGOUT_CODE),
                        ('EXIT', 'Έξοδος', "do_key('EXIT_FORM');")]),
    ('REC', 'Εγγραφές', [('SAVE', 'Αποθήκευση (F10)', "do_key('COMMIT_FORM');"),
                         ('ENTERQ', 'Αναζήτηση (F7)', "do_key('ENTER_QUERY');"),
                         ('EXECQ', 'Εκτέλεση αναζήτησης (F8)', "do_key('EXECUTE_QUERY');"),
                         ('LOV', 'Λίστα τιμών (Ctrl+L)', "do_key('LIST_VALUES');")]),
    ('BANK', 'Τράπεζα', [('CUSTOMERS', 'Πελάτες', "new_form('BK_CUSTOMERS');"),
                         ('ACCOUNTS', 'Λογαριασμοί', "new_form('BK_ACCOUNTS');"),
                         ('MOVE', 'Κίνηση', "new_form('BK_MOVE');"),
                         ('DAY', 'Ημέρα και κλείσιμο', "new_form('BK_DAY');")]),
]


def menu_texts():
    """the Greek labels of the bar, for ui.init of every form"""
    out = []
    for m, label, items in MENU_BAR:
        out.append("SET_MENU_ITEM_PROPERTY('MAIN_MENU.%s', LABEL, tx('%s'));" % (m, WORDS.key(label)))
        for i, il, _ in items:
            out.append("SET_MENU_ITEM_PROPERTY('%s_MENU.%s', LABEL, tx('%s'));" % (m, i, WORDS.key(il)))
    return out


def menu_xml():
    """the menu module BK_MENU (XML2Forms makes BK_MENU.mmb, frmcmp module_type=menu BK_MENU.mmx)"""
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<Module version="141200000" xmlns="http://xmlns.oracle.com/Forms">',
           '  <MenuModule Name="%s" MainMenu="MAIN_MENU">' % MENU_MODULE,
           '    <Menu Name="MAIN_MENU">']
    for m, label, _ in MENU_BAR:
        out.append('      <MenuItem %s/>' % attrs(dict(Name=m, Label=ascii_text(label), CommandType='Menu',
                                                         SubMenuName=m + '_MENU')))
    out.append('    </Menu>')
    for m, _, items in MENU_BAR:
        out.append('    <Menu Name="%s_MENU">' % m)
        for i, il, code in items:
            out.append('      <MenuItem %s/>' % attrs(dict(Name=i, Label=ascii_text(il), CommandType='PL/SQL',
                                                             MenuItemCode=code)))
        out.append('    </Menu>')
    out += ['  </MenuModule>', '</Module>']
    xml = '\n'.join(out) + '\n'
    assert all(ord(c) < 128 for c in xml)
    return xml


# the toolbar of all the forms: a horizontal toolbar canvas TBC with the buttons of the block TB; they
# do not take the cursor (MouseNavigate false), so they act on the block where it is (ui.tool)
TOOLBAR = [('T_SAVE', 'Αποθήκευση', 100), ('T_ENTERQ', 'Αναζήτηση', 90), ('T_EXECQ', 'Εκτέλεση', 80),
           ('T_NEW', 'Νέα', 60), ('T_DEL', 'Διαγραφή', 80), ('T_LOV', 'Λίστα', 60), ('T_PREV', '<', 34), ('T_NEXT', '>', 34),
           ('T_MAIN', 'Μενού', 70), ('T_EXIT', 'Έξοδος', 70)]
TB_CANVAS, TB_H = 'TBC', 34


def toolbar_items(say):
    out, x = [], 4
    for name, label, w in TOOLBAR:
        out.append(dict(Name=name, ItemType='Push Button', CanvasName=TB_CANVAS, XPosition=x, YPosition=4,
                        Width=w, Height=26, Label=ascii_text(label), MouseNavigate='false',
                        KeyboardNavigable='false'))
        say('TB.' + name, 'LABEL', label)
        x += w + 4
    return out, x + 4


def attrs(a):
    return ' '.join('%s=%s' % (k, quoteattr(str(v))) for k, v in a.items())


def trigger(name, text, ind):
    return '%s<Trigger Name=%s TriggerText=%s/>' % (ind, quoteattr(name), quoteattr(text))


def ascii_text(s):
    return greeklish(s) if nonascii(s) else s


def program(name, f, texts):
    """the package UI of BK_UI.pls for this form: its Greek strings as tx('T...'), its blocks, its role, the
    texts of ui.init"""
    src = open(os.path.join(HERE, 'BK_UI.pls'), encoding='utf-8').read()
    spec, body = src.split('\n-- BODY\n')
    spec = '\n'.join(l for l in spec.split('\n') if not l.startswith('--')).strip()
    out = []
    for line in body.strip().split('\n'):
        code, sep, rest = line.partition('--')
        code = re.sub(r"'([^']*)'", lambda m: "tx('%s')" % WORDS.key(m.group(1)) if nonascii(m.group(1))
                      else m.group(0), code)
        out.append(code.rstrip() if not sep else code + sep + greeklish(rest))
    body = '\n'.join(out)
    body = body.replace("c_block CONSTANT VARCHAR2(30) := 'BLOCK'; -- BLOCK",
                        "c_block CONSTANT VARCHAR2(30) := '%s';" % f['block'])
    body = body.replace("c_where CONSTANT VARCHAR2(400) := ''; -- WHERE",
                        "c_where CONSTANT VARCHAR2(400) := '%s';" % f.get('where', '').replace("'", "''"))
    body = body.replace("c_detail CONSTANT VARCHAR2(30) := ''; -- DETAIL",
                        "c_detail CONSTANT VARCHAR2(30) := '%s';" % f.get('detail', ''))
    body = body.replace("c_detail2 CONSTANT VARCHAR2(30) := ''; -- DETAIL2",
                        "c_detail2 CONSTANT VARCHAR2(30) := '%s';" % f.get('detail2', ''))
    body = body.replace("c_role CONSTANT VARCHAR2(10) := ''; -- ROLE",
                        "c_role CONSTANT VARCHAR2(10) := '%s';" % (FORM_ROLES.get(name) or ''))
    body = body.replace("c_form CONSTANT VARCHAR2(30) := ''; -- FORM",
                        "c_form CONSTANT VARCHAR2(30) := '%s';" % name)
    body = body.replace('NULL; -- TEXTS', ('\n' + ' ' * 4).join(texts))
    body = body.replace('NULL; -- ROLES', ('\n' + ' ' * 4).join(role_lines(name, f)))
    return spec, body


def role_lines(name, f):
    """after the login: the buttons of a role higher than the user's, off (BK_CORE checks nothing of the roles:
    the form does); the buttons of the first menu to a form of a higher role, off"""
    out = []
    for c in f.get('ctl', []):
        need = c[6].get('role') if c[1] == 'button' else None
        if c[0].startswith('GO_') and FORM_ROLES.get(c[0][3:]):
            need = FORM_ROLES[c[0][3:]]
        if need:
            out.append("IF NOT at_least('%s') THEN SET_ITEM_PROPERTY('CTL.%s', ENABLED, PROPERTY_FALSE); END IF;"
                       % (need, c[0]))
    return out or ['NULL;']


def block_items(blk, cols, top, say, x0=10):
    """the items of a block of a table, side by side from x0 on the row top; its width"""
    out_items = []
    x = x0
    for c in cols:
        a = dict(Name=c['name'])
        if c.get('hidden'):
            a.update(ItemType='Text Item', Visible='false')
        else:
            a.update(ItemType='Check Box' if c.get('check') else
                     'Display Item' if c.get('display') else 'Text Item',
                     CanvasName=CANVAS, XPosition=x, YPosition=top, Width=c['width'], Height=ROW_H,
                     Prompt=ascii_text(c['prompt']), PromptAttachmentEdge='Top', PromptAttachmentOffset=2)
            x += c['width'] + 4
            say('%s.%s' % (blk, c['name']), 'PROMPT_TEXT', c['prompt'])
        if c.get('check'):
            a.update(CheckedValue='Y', UncheckedValue='N', CheckBoxOtherValues='Not Allowed',
                     Label='', DataType='Char', MaximumLength=1)
        else:
            a.update(DataType='Number' if c.get('num') else 'Date' if c.get('date') else 'Char',
                     MaximumLength=c.get('len', 14 if c.get('num') else 10 if c.get('date') else 30))
        if c.get('num') and not c.get('hidden'):
            a['Justification'] = 'Right'
        if c.get('mask'):
            a['FormatMask'] = c['mask']      # 0,45 not ,45; 4,60 not 4,6 (D and G: the NLS of the runtime)
        if c.get('date'):
            a['FormatMask'] = 'DD/MM/YYYY'
        if c.get('db', True):
            a['ColumnName'] = c['name']
        else:
            a['DatabaseItem'] = 'false'
        if c.get('req'):
            a['Required'] = 'true'
        if c.get('upper'):
            a['CaseRestriction'] = 'Upper'
        if 'init' in c:
            a['InitializeValue'] = c['init']
        if c.get('query_only'):
            a.update(InsertAllowed='false', UpdateAllowed='false')
        if c.get('lov'):
            a['LovName'] = c['lov']
            a['ValidateFromList'] = 'false' if c.get('free') else 'true'
        out_items.append(a)
    return out_items, x


def lov_xml(lovs, texts):
    """the record groups and the LOVs; their Greek titles to ui.init"""
    groups, lovx = [], []
    for lov, title, query, cols in lovs:
        rg = 'RG' + lov[3:]
        groups.append('    <RecordGroup Name="%s" RecordGroupType="Query" RecordGroupQuery=%s>' % (rg, quoteattr(query)))
        for cn, w, t, r in cols:
            # ColumnDataType: "Number"; a column of characters is the default ("Char" is not a
            # value of the schema of XML2Forms 14.1.2: XML-24523)
            num = cn in ('ID', 'RATE', 'O', 'OD')
            groups.append('      <RecordGroupColumn Name="%s"%s MaximumLength="%d"/>'
                          % (cn, ' ColumnDataType="Number"' if num else '', 40 if num else 400))
        groups.append('    </RecordGroup>')
        lw = sum(w for _, w, _, _ in cols) + 40
        lovx.append('    <LOV Name="%s" RecordGroupName="%s" Title=%s Width="%d" Height="300" '
                    'AutoColumnWidth="false" AutoPosition="true" AutoRefresh="true" FilterBeforeDisplay="false">'
                    % (lov, rg, quoteattr(ascii_text(title)), max(lw, 220)))
        if nonascii(title):
            texts.append("SET_LOV_PROPERTY('%s', TITLE, tx('%s'));" % (lov, WORDS.key(title)))
        for i, (cn, w, t, r) in enumerate(cols, 1):
            m = dict(Name=cn, Title=ascii_text(t), DisplayWidth=w)
            if r:
                m['ReturnItem'] = r
            lovx.append('      <LOVColumnMapping %s/>' % attrs(m))
            if nonascii(t):
                texts.append("SET_LOV_COLUMN_PROPERTY('%s', %d, TITLE, tx('%s'));" % (lov, i, WORDS.key(t)))
        lovx.append('    </LOV>')
    return groups, lovx


def ctl_item(c, say):
    """an item of the block CTL: (name, kind, x, y, width, text, options)
       kind: button (its label), text / date / secret (a prompt on its left), display, hidden"""
    name, kind, x, y, w, text, o = c
    a = dict(Name=name)
    if kind == 'button':
        a.update(ItemType='Push Button', CanvasName=CANVAS, XPosition=x, YPosition=y, Width=w, Height=26,
                 Label=ascii_text(text))
        say('CTL.' + name, 'LABEL', text)
        return a
    if kind == 'hidden':
        a.update(ItemType='Text Item', Visible='false', DatabaseItem='false',
                 DataType='Number' if o.get('num') else 'Char', MaximumLength=o.get('len', 40))
        return a
    # a date: text DD/MM/YYYY (ui.day reads it so on every runtime; ui.init puts today in it)
    a.update(ItemType='Display Item' if kind == 'display' else 'Text Item', CanvasName=CANVAS,
             XPosition=x, YPosition=y, Width=w, Height=ROW_H, DatabaseItem='false',
             DataType='Number' if o.get('num') else 'Char',
             MaximumLength=o.get('len', 14 if o.get('num') else 10 if kind == 'date' else 100))
    if text:
        a.update(Prompt=ascii_text(text), PromptAttachmentEdge='Top', PromptAttachmentOffset=2)
        say('CTL.' + name, 'PROMPT_TEXT', text)
    if kind == 'secret':
        a['ConcealData'] = 'true'          # a PIN typed: dots on the screen
    if o.get('num'):
        a['Justification'] = 'Right'
    if o.get('upper'):
        a['CaseRestriction'] = 'Upper'
    if o.get('lower'):
        a['CaseRestriction'] = 'Lower'
    if 'init' in o:
        a['InitializeValue'] = o['init']
    if o.get('lov'):
        a['LovName'] = o['lov']
        a['ValidateFromList'] = 'false'
    if o.get('enter'):
        a['_enter'] = True             # Enter here: ui.press of this item (KEY-NEXT-ITEM; the cursor stays)
    return a


FIND_CTL = [('FIND', 'button', 10, 10, 110, 'Βρες...', {}),
            ('FIND_TEXT', 'display', 126, 12, 300, '', {}),
            ('ALL', 'button', 432, 10, 110, 'Όλα', {}),
            ('FIND_ID', 'hidden', 0, 0, 0, '', {'num': True, 'len': 20})]


def build(name, f):
    """a form: f['blocks'] (the first the master; a detail with 'where' on the master), or one block
    (f['block'], f['table'], f['cols']); the block CTL (Find..., All, and f['ctl']); the LOVs"""
    texts = ["SET_WINDOW_PROPERTY('%s', TITLE, tx('%s'));" % (WINDOW, WORDS.key(f['title']))] + menu_texts()

    def say(item, prop, text):
        if nonascii(text):
            texts.append("SET_ITEM_PROPERTY('%s', %s, tx('%s'));" % (item, prop, WORDS.key(text)))

    # no block of a table (the menu): f['blocks'] = []
    blocks = f['blocks'] if 'blocks' in f else [dict(name=f['block'], table=f['table'], order=f['order'],
                                                     cols=f['cols'], top=TOP, rows=ROWS)]
    width, height, out_blocks = 0, 0, []
    for b in blocks:
        items, w = block_items(b['name'], b['cols'], b['top'], say)
        width = max(width, w + 6)
        height = max(height, b['top'] + b['rows'] * ROW_H + 40)
        out_blocks.append((b, items))
    ctl = [ctl_item(c, say) for c in (FIND_CTL if 'find' in f else []) + f.get('ctl', [])]
    tb, tbw = toolbar_items(say)           # (before program(): its labels go to ui.init)
    width = max(width, tbw)
    for c in f.get('ctl', []):
        if c[1] == 'date':
            # (year_start: the 1st of January, e.g. the start of a ledger)
            texts.append("COPY(to_char(%s, 'DD/MM/YYYY'), 'CTL.%s');"
                         % ("trunc(sysdate, 'YYYY')" if c[6].get('year_start') else 'sysdate', c[0]))
        elif 'init' in c[6]:
            # (the initial value of an item of CTL did not show on the web: put by ui.init too)
            texts.append("COPY('%s', 'CTL.%s');" % (c[6]['init'], c[0]))
    for c in f.get('ctl', []):
        if c[1] != 'hidden':
            width = max(width, c[2] + c[4] + 10)
            height = max(height, c[3] + 40)

    lovs = ([('LOV_FIND', f['find_title'], f['find'][0],
              [(n, w, t, 'CTL.' + r if r else None) for n, w, t, r in f['find'][1]])] if 'find' in f else []) \
        + f.get('lovs', [])
    groups, lovx = lov_xml(lovs, texts)

    master = blocks[0] if blocks else dict(name='')
    detail = blocks[1]['name'] if len(blocks) > 1 else ''
    detail2 = blocks[2]['name'] if len(blocks) > 2 else ''
    spec, body = program(name, dict(block=master['name'], where=master.get('where', ''), detail=detail,
                                    detail2=detail2, ctl=f.get('ctl', [])), texts)
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<Module version="141200000" xmlns="http://xmlns.oracle.com/Forms">',
           '  <FormModule Name="%s" Title=%s ConsoleWindow="%s" MenuModule="%s">'
           % (name, quoteattr(greeklish(f['title'])), WINDOW, MENU_MODULE),
           '    <Coordinate CharacterCellWidth="7" CharacterCellHeight="14" CoordinateSystem="Real" '
           'RealUnit="Pixel" DefaultFontScaling="true"/>']
    for b, items in out_blocks:
        extra = ''
        if b.get('where'):
            extra += ' WhereClause=%s' % quoteattr(b['where'])
        if b.get('read_only'):
            extra += ' InsertAllowed="false" UpdateAllowed="false" DeleteAllowed="false"'
        elif b.get('no_insert'):
            extra += ' InsertAllowed="false" DeleteAllowed="false"'
        out.append('    <Block Name="%s" QueryDataSourceName="%s" DMLDataName="%s" OrderByClause="%s" '
                   'RecordsDisplayCount="%d"%s>' % (b['name'], b['table'], b['table'], b['order'], b['rows'], extra))
        out += ['      <Item %s/>' % attrs(a) for a in items]
        out += [trigger('POST-QUERY', 'ui.post_query(:SYSTEM.TRIGGER_BLOCK);', '      '),
                trigger('WHEN-VALIDATE-ITEM', 'ui.validate(:SYSTEM.TRIGGER_ITEM);', '      ')]
        if (b is master and detail) or (detail2 and b['name'] == detail):
            out.append(trigger('WHEN-NEW-RECORD-INSTANCE', 'ui.master(:SYSTEM.TRIGGER_BLOCK);', '      '))
        out.append('    </Block>')
    out.append('    <Block Name="CTL" DatabaseBlock="false" RecordsDisplayCount="1">')
    for a in ctl:
        if a.pop('_enter', False):
            out += ['      <Item %s>' % attrs(a),
                    trigger('KEY-NEXT-ITEM', 'ui.press(:SYSTEM.TRIGGER_ITEM);', '        '),
                    '      </Item>']
        else:
            out.append('      <Item %s/>' % attrs(a))
    out += [trigger('WHEN-BUTTON-PRESSED', 'ui.press(:SYSTEM.TRIGGER_ITEM);', '      '),
            '    </Block>']
    out.append('    <Block Name="TB" DatabaseBlock="false" RecordsDisplayCount="1">')
    out += ['      <Item %s/>' % attrs(a) for a in tb]
    out += [trigger('WHEN-BUTTON-PRESSED', 'ui.tool(:SYSTEM.TRIGGER_ITEM);', '      '),
            '    </Block>',
            '    <Canvas Name="%s" WindowName="%s" Width="%d" Height="%d"/>' % (CANVAS, WINDOW, width, height),
            '    <Canvas Name="%s" WindowName="%s" CanvasType="Horizontal Toolbar" Width="%d" Height="%d"/>'
            % (TB_CANVAS, WINDOW, width, TB_H)]
    out += groups + lovx
    out += ['    <ProgramUnit Name="UI" ProgramUnitType="Package Spec" ProgramUnitText=%s/>' % quoteattr(spec),
            '    <ProgramUnit Name="UI" ProgramUnitType="Package Body" ProgramUnitText=%s/>' % quoteattr(body),
            trigger('WHEN-NEW-FORM-INSTANCE', 'ui.init;', '    '),
            trigger('ON-ERROR', 'ui.on_error(ERROR_CODE, ERROR_TYPE, ERROR_TEXT, DBMS_ERROR_TEXT);', '    '),
            trigger('ON-MESSAGE', 'ui.on_message(MESSAGE_CODE, MESSAGE_TYPE, MESSAGE_TEXT);', '    '),
            trigger('WHEN-WINDOW-CLOSED', 'exit_form;', '    '),
            trigger('WHEN-MOUSE-DOUBLECLICK', 'ui.dblclick(:SYSTEM.TRIGGER_ITEM);', '    '),
            '    <Window Name="%s" Title=%s XPosition="0" YPosition="0" Width="%d" Height="%d" '
            'HorizontalToolbarCanvasName="%s"/>'
            % (WINDOW, quoteattr(greeklish(f['title'])), width, height + TB_H, TB_CANVAS),
            '  </FormModule>',
            '</Module>']
    xml = '\n'.join(out) + '\n'
    bad = sorted({c for c in xml if ord(c) > 127})
    if bad:
        raise SystemExit('%s.xml: not ASCII: %r' % (name, ''.join(bad)))
    return xml, spec, body


def text_sql():
    sql = ['-- BK_TEXT.sql -- made by forms/mkforms.py: the Greek of the forms (prompts, labels, titles,',
           '-- messages), which the forms ask for when they open (XML2Forms does not carry Greek into a',
           '-- form). UTF-8: run by INSTALL.sql (NLS_LANG ...AL32UTF8).',
           'create or replace package bk_text as',
           '  function t(p_key varchar2) return varchar2;',
           'end bk_text;', '/', '',
           'create or replace package body bk_text as',
           '  function t(p_key varchar2) return varchar2 is',
           '  begin',
           '    return case p_key']
    for k in sorted(WORDS.words):
        sql.append("      when '%s' then '%s'" % (k, WORDS.words[k].replace("'", "''")))
    sql += ['      else p_key', '    end;', '  end;', 'end bk_text;', '/', '']
    return '\n'.join(sql)


def main():
    made = {}
    for name, f in FORMS.items():
        made[name] = build(name, f)
    for name, (xml, _, _) in made.items():
        open(os.path.join(HERE, name + '.xml'), 'w', encoding='ascii', newline='\n').write(xml)
    open(os.path.join(HERE, MENU_MODULE + '.xml'), 'w', encoding='ascii', newline='\n').write(menu_xml())
    open(os.path.join(DB, 'BK_TEXT.sql'), 'w', encoding='utf-8', newline='\n').write(text_sql())
    print('%s, %s (menu); BK_TEXT.sql: %d words' % (', '.join(made), MENU_MODULE, len(WORDS.words)))
    return made


if __name__ == '__main__':
    main()
