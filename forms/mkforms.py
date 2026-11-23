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
  BK_RULES      the rules of the movements: a rule set (new or changed) or removed (MANAGER)
  BK_PRODUCTS   the products (a manager corrects them) and their rates; a new rate from the business day on
  BK_CARDS      the debit cards: a new one, a new PIN (shown once), blocked; again active, cancelled (MANAGER)
  BK_LOANS      the loans and their schedule; a new one, its installment first (MANAGER), what pays it off today,
                a prepayment and a payoff (MANAGER), its schedule printed (BK_LN_SCHEDULE)
  BK_BRANCHES   the branches (accounts, users, ATMs, cash), the accounts of each; a branch (MANAGER)
  BK_FX         the currencies, their rates by day; a new rate, a currency (MANAGER); an amount converted
  BK_CCARDS     the credit cards: limit, owed, held, available, their statements; the limit (MANAGER), a payment,
                a purchase (a test), a statement printed; a new card for a customer with its PIN (MANAGER)
  BK_ATMS       the ATMs, their cassettes; a cassette filled or emptied, the notes they give (MANAGER)
  BK_USERS      the users (ADMIN): a new one, a password, a role, active, unlocked

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
            C('DESCR', 'Περιγραφή', 200, len=200),
            C('DEBIT', 'Χρέωση', 90, num=True, mask=MONEY),
            C('CREDIT', 'Πίστωση', 90, num=True, mask=MONEY),
            C('RUN_BALANCE', 'Υπόλοιπο', 100, num=True, db=False, display=True, mask=MONEY),
            # (in another currency: the amount it was in, at its rate: ui.post_query)
            C('ORIG_AMOUNT', '', 0, num=True, hidden=True),
            C('ORIG_CURRENCY', '', 0, len=3, hidden=True),
            C('FX_RATE', '', 0, num=True, hidden=True),
            C('ORIG_TEXT', 'Αρχικό ποσό', 160, len=60, db=False, display=True)]


STATEMENT_ORDER = 'book_date desc, entry_id desc, line_id desc'
# the currencies (a list): the base one first
CURRENCY_LOV = ("select code, name from bk_currency where active = 'Y' "
                "order by case code when 'EUR' then 0 else 1 end, code")


def currency_lov(name, item):
    return (name, 'Νομίσματα', CURRENCY_LOV, [('CODE', 50, 'Νόμ.', item), ('NAME', 200, 'Νόμισμα', None)])


# the branches (a list): those active
BRANCH_LOV = "select code, name from bk_branch where active = 'Y' order by code"


def branch_lov(name, item):
    return (name, 'Υποκαταστήματα', BRANCH_LOV, [('CODE', 50, 'Κωδ.', item), ('NAME', 220, 'Υποκατάστημα', None)])
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
                   C('CURRENCY', 'Νόμ.', 40, len=3),
                   C('BRANCH_CODE', 'Υποκ.', 46, len=4),
                   C('BALANCE', 'Υπόλοιπο', 110, num=True, mask=MONEY),
                   C('OD_LIMIT', 'Όριο υπεραν.', 100, num=True, mask=MONEY)])],
    ctl=[('C_NAME', 'text', 10, 430, 200, 'Νέος πελάτης: ονοματεπώνυμο', {'len': 100}),
         ('C_AFM', 'text', 216, 430, 90, 'ΑΦΜ', {'len': 9}),
         ('C_PHONE', 'text', 312, 430, 100, 'Τηλέφωνο', {'len': 20}),
         ('C_EMAIL', 'text', 418, 430, 180, 'Email', {'len': 100}),
         ('NEWCUST', 'button', 604, 428, 170, 'Νέος πελάτης', {}),
         ('A_PRODUCT', 'text', 10, 480, 90, 'Προϊόν (λίστα)', {'len': 10, 'upper': True, 'lov': 'LOV_PROD', 'init': 'CUR'}),
         ('A_OD', 'text', 106, 480, 100, 'Όριο υπεραν.', {'num': True, 'init': '0'}),
         ('A_CURRENCY', 'text', 212, 480, 80, 'Νόμισμα (λίστα)', {'len': 3, 'upper': True, 'lov': 'LOV_CUR'}),
         ('A_BRANCH', 'text', 298, 480, 80, 'Υποκ. (λίστα)', {'len': 4, 'lov': 'LOV_ABR'}),
         ('NEWACC', 'button', 384, 478, 300, 'Νέος λογαριασμός (του πελάτη της οθόνης)', {})],
    lovs=[('LOV_PROD', 'Προϊόντα', "select code, name, currencies from bk_product where active = 'Y' order by id",
           [('CODE', 70, 'Προϊόν', 'CTL.A_PRODUCT'), ('NAME', 220, 'Όνομα', None), ('CURRENCIES', 140, 'Νομίσματα', None)]),
          currency_lov('LOV_CUR', 'CTL.A_CURRENCY'), branch_lov('LOV_ABR', 'CTL.A_BRANCH')])

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
                       C('HOLDER', 'Δικαιούχος', 170, len=100),
                       C('STATUS', 'Κατ.', 36, len=1),
                       C('CURRENCY', 'Νόμ.', 40, len=3),
                       C('BRANCH_CODE', 'Υποκ.', 46, len=4),
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
         ('GO_BK_MOVE', 'button', 674, 564, 190, 'Νέα κίνηση', {}),
         # the reports (reports/mkreports.py): the statement and the interest of the account, from - to
         ('P_FROM', 'date', 10, 612, 100, 'Από', {'year_start': True}),
         ('P_TO', 'date', 116, 612, 100, 'Έως', {}),
         ('PRINTST', 'button', 222, 610, 220, 'Εκτύπωση καρτέλας', {}),
         ('PRINTINT', 'button', 448, 610, 220, 'Εκτύπωση τόκων', {}),
         ('B_BRANCH', 'text', 10, 658, 80, 'Υποκ. (λίστα)', {'len': 4, 'lov': 'LOV_BBR'}),
         ('MOVEBR', 'button', 96, 656, 300, 'Μεταφορά σε υποκατάστημα', {'role': 'MANAGER'}),
         ('F_BRANCH', 'text', 448, 658, 80, 'Φίλτρο υποκ. (λίστα)', {'len': 4, 'lov': 'LOV_FBR'}),
         ('FILTERBR', 'button', 534, 656, 220, 'Μόνο αυτού (κενό: όλα)', {})],
    lovs=[branch_lov('LOV_BBR', 'CTL.B_BRANCH'), branch_lov('LOV_FBR', 'CTL.F_BRANCH')])

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
         ('M_AMOUNT', 'text', 10, 124, 120, 'Ποσό (στο νόμισμά του)', {'num': True}),
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

MONEY4 = '990D9999'
OPS = (('DEP', 'Κατάθεση'), ('WDR', 'Ανάληψη'), ('TRO', 'Μεταφορά προς άλλον'), ('TRI', 'Μεταφορά από άλλον'),
       ('OUT', 'Σε άλλη τράπεζα'), ('INC', 'Από άλλη τράπεζα'))
CHANNELS = (('*', 'Όλα'), ('BR', 'Γκισέ'), ('WEB', 'e-banking'), ('ATM', 'ATM'))
ROLES = (('TELLER', 'Γκισέ'), ('MANAGER', 'Διευθυντής'), ('ADMIN', 'Διαχειριστής'))


def words_lov(name, title, pairs, ret_code, ret_text=None, w=200):
    """a LOV of codes and their words (BK_TEXT): the code to ret_code, the words to ret_text"""
    return (name, title, ' union all '.join("select '%s' code, bk_text.t('%s') descr, %d o from dual" % (c, WORDS.key(d), i)
                                           for i, (c, d) in enumerate(pairs)) + ' order by 3',
            [('CODE', 70, 'Κωδικός', ret_code), ('DESCR', w, 'Περιγραφή', ret_text), ('O', 0, '#', None)])


# the rules of the movements (BK_RULE_V): the list, the bank first; a rule set (bk_core.set_rule: again with the
# same keys, all its values replaced) from the fields below, or removed; the one selected to the fields (to change)
RULE_NUMS = [('R_MIN', 'MIN_AMOUNT', 'Ελάχ. ποσό'), ('R_MAX', 'MAX_AMOUNT', 'Μέγ. ποσό'), ('R_DAYAMT', 'DAY_AMOUNT', 'Ποσό ημέρας'),
             ('R_DAYCNT', 'DAY_COUNT', 'Κινήσεις ημ.'), ('R_MONAMT', 'MONTH_AMOUNT', 'Ποσό μήνα'),
             ('R_MONCNT', 'MONTH_COUNT', 'Κινήσεις μήνα'), ('R_FREE', 'FREE_MONTH', 'Δωρεάν/μήνα'), ('R_FEE', 'FEE', 'Προμήθεια'),
             ('R_MINBAL', 'MIN_BALANCE', 'Ελάχ. υπόλοιπο')]
FORMS['BK_RULES'] = dict(
    title='Κανόνες κινήσεων',
    blocks=[dict(name='RULE', table='BK_RULE_V', top=TOP, rows=12, read_only=True,
                 order="decode(lvl, 'BANK', 0, 'PRODUCT', 1, 2), product, account_id, instr('DEP WDR TRO TRI OUT INC', op), "
                       "instr('* BR WEB ATM', channel)",
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('LVL', 'Επίπεδο', 66, len=10),
                       C('PRODUCT', 'Προϊόν', 54, len=10),
                       C('IBAN', 'Λογαριασμός', 200, len=27),
                       C('ACCOUNT_ID', '', 0, num=True, hidden=True),
                       C('OP', 'Κίνηση', 46, len=3),
                       C('CHANNEL', 'Κανάλι', 46, len=3),
                       C('ALLOWED', 'Επιτρ.', 40, len=1)] +
                      [C(col, txt, 66, num=True) for _, col, txt in RULE_NUMS])],
    ctl=[('R_PRODUCT', 'text', 10, 400, 80, 'Προϊόν (λίστα)', {'len': 10, 'upper': True, 'lov': 'LOV_RPROD'}),
         ('R_ACC_TEXT', 'text', 96, 400, 300, 'ή λογαριασμός (λίστα)', {'len': 200, 'lov': 'LOV_RACC'}),
         ('R_ACC_ID', 'hidden', 0, 0, 0, '', {'num': True}),
         ('R_OP', 'text', 402, 400, 60, 'Κίνηση (λίστα)', {'len': 3, 'upper': True, 'lov': 'LOV_ROP', 'init': 'WDR'}),
         ('R_CHANNEL', 'text', 468, 400, 60, 'Κανάλι (λίστα)', {'len': 3, 'upper': True, 'lov': 'LOV_RCH', 'init': '*'}),
         ('R_ALLOWED', 'text', 534, 400, 70, 'Επιτρ. (Y/N)', {'len': 1, 'upper': True})] +
        [(f, 'text', 10 + i * 96, 450, 90, txt, {'num': True}) for i, (f, _, txt) in enumerate(RULE_NUMS)] +
        [('LOADRULE', 'button', 10, 496, 240, 'Ο επιλεγμένος στα πεδία', {}),
         ('SETRULE', 'button', 256, 496, 240, 'Αποθήκευση κανόνα', {'role': 'MANAGER'}),
         ('REMOVERULE', 'button', 502, 496, 240, 'Αφαίρεση του επιλεγμένου', {'role': 'MANAGER'}),
         ('CLEARRULE', 'button', 748, 496, 120, 'Καθαρά πεδία', {})],
    lovs=[('LOV_RPROD', 'Προϊόντα', "select code, name from bk_product order by id",
           [('CODE', 70, 'Προϊόν', 'CTL.R_PRODUCT'), ('NAME', 220, 'Όνομα', None)]),
          ('LOV_RACC', 'Λογαριασμοί', ACCOUNTS_LOV, [('ID', 0, 'Κωδ.', 'CTL.R_ACC_ID'), ('TEXT', 380, 'Λογαριασμός', 'CTL.R_ACC_TEXT')]),
          words_lov('LOV_ROP', 'Κινήσεις', OPS, 'CTL.R_OP'),
          words_lov('LOV_RCH', 'Κανάλια', CHANNELS, 'CTL.R_CHANNEL')])

# the products: their name, tax and overdraft rate corrected by a manager (their day basis and capitalization: as
# they are, the interest counted so); below, their rates (the history); a new rate from the business day on
FORMS['BK_PRODUCTS'] = dict(
    title='Προϊόντα και επιτόκια',
    blocks=[dict(name='PROD', table='BK_PRODUCT', order='id', top=TOP, rows=6, no_insert=True, role='MANAGER', cols=[
        C('ID', '', 0, num=True, hidden=True, query_only=True),
        C('CODE', 'Κωδικός', 60, len=10, query_only=True),
        C('NAME', 'Όνομα', 220, len=60, req=True),
        C('KIND', 'Είδος', 44, len=3, query_only=True),
        C('DAY_BASIS', 'Βάση ημερών', 84, len=6, query_only=True),
        C('CAP_EVERY', 'Κεφαλ.', 50, len=1, query_only=True),
        C('TAX_RATE', 'Φόρος %', 70, num=True, req=True),
        C('OD_RATE', 'Υπεραν. %', 70, num=True, req=True),
        C('ACTIVE', 'Ενεργό', 50, check=True),
        C('CURRENCIES', 'Νομίσματα', 140, len=200, query_only=True)]),
        dict(name='RATE', table='BK_RATE', order="case currency when 'EUR' then 0 else 1 end, currency, valid_from desc, min_balance",
             top=TOP + 6 * ROW_H + 40, rows=10, read_only=True, where='product_id = :PROD.ID',
             cols=[C('CURRENCY', 'Νόμ.', 44, len=3),
                   C('VALID_FROM', 'Από', 90, date=True),
                   C('MIN_BALANCE', 'Κλιμάκιο από', 120, num=True, mask=MONEY),
                   C('RATE', 'Επιτόκιο %', 90, num=True, mask=MONEY4)])],
    ctl=[('N_FROM', 'date', 400, 230, 100, 'Νέο επιτόκιο από', {}),
         ('N_MIN', 'text', 506, 230, 110, 'Κλιμάκιο από (€)', {'num': True, 'init': '0'}),
         ('N_RATE', 'text', 622, 230, 90, 'Επιτόκιο %', {'num': True}),
         ('SETRATE', 'button', 718, 228, 200, 'Νέο επιτόκιο (του προϊόντος)', {'role': 'MANAGER'}),
         ('N_CURRENCY', 'text', 400, 280, 80, 'Νόμισμα (λίστα)', {'len': 3, 'upper': True, 'lov': 'LOV_CUR', 'init': 'EUR'}),
         ('P_CURS', 'text', 400, 330, 220, 'Νομίσματα του προϊόντος (EUR,USD)', {'len': 200, 'upper': True}),
         ('SETCURS', 'button', 626, 328, 200, 'Αλλαγή νομισμάτων', {'role': 'MANAGER'})],
    lovs=[currency_lov('LOV_CUR', 'CTL.N_CURRENCY')])

# the debit cards: all of them, a find by its number; a new card of an account; for the card on the screen: a new
# PIN (shown here once: its hash in the database), blocked; again active, cancelled (MANAGER)
FORMS['BK_CARDS'] = dict(
    title='Κάρτες',
    find_title='Κάρτες', find=("select id, pan || ' ' || iban text, holder from bk_card_v order by id",
                              [('ID', 0, 'Κωδ.', 'FIND_ID'), ('TEXT', 320, 'Κάρτα · λογαριασμός', 'FIND_TEXT'),
                               ('HOLDER', 200, 'Κάτοχος', None)]),
    blocks=[dict(name='CARD', table='BK_CARD_V', order='id', top=TOP, rows=12, read_only=True,
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('PAN', 'Αριθμός', 130, len=16),
                       C('IBAN', 'Λογαριασμός', 220, len=27),
                       C('HOLDER', 'Κάτοχος', 190, len=100),
                       C('EXPIRES', 'Λήξη', 84, date=True),
                       C('STATUS', 'Κατ.', 36, len=1),
                       C('HAS_PIN', 'PIN', 36, len=1),
                       C('PIN_FAILED', 'Λάθη', 40, num=True)])],
    ctl=[('NEWPIN', 'button', 10, 410, 190, 'Νέο PIN', {}),
         ('C_PIN', 'display', 206, 412, 200, 'Το PIN (μία φορά)', {'len': 60}),
         ('BLOCKCARD', 'button', 412, 410, 150, 'Δέσμευση', {}),
         ('ACTIVATE', 'button', 568, 410, 150, 'Ενεργοποίηση', {'role': 'MANAGER'}),
         ('CANCELCARD', 'button', 724, 410, 150, 'Ακύρωση', {'role': 'MANAGER'}),
         ('C_ACC_TEXT', 'text', 10, 460, 400, 'Νέα κάρτα: λογαριασμός (λίστα)', {'len': 200, 'lov': 'LOV_CACC'}),
         ('C_ACC_ID', 'hidden', 0, 0, 0, '', {'num': True}),
         ('NEWCARD', 'button', 416, 458, 220, 'Νέα κάρτα (του κύριου δικαιούχου)', {})],
    lovs=[('LOV_CACC', 'Λογαριασμοί', ACCOUNTS_LOV, [('ID', 0, 'Κωδ.', 'CTL.C_ACC_ID'), ('TEXT', 380, 'Λογαριασμός', 'CTL.C_ACC_TEXT')])])

# the credit cards (BK_CCARD_V): the card on the screen, its statements below (the newest first); its limit
# (MANAGER), a payment from an account of the bank or in cash, a purchase (a test at the counter), the statement
# chosen printed (BK_CC_STATEMENT); a new card for a customer (its account, its card, its PIN once: MANAGER)
CC_PAY_LOV = ("select a.id, a.iban || ' ' || a.holder text from bk_account_v a, bk_product p "
              "where a.status <> 'C' and p.code = a.product and p.kind <> 'CC' order by a.id")
FORMS['BK_CCARDS'] = dict(
    title='Πιστωτικές κάρτες',
    find_title='Πιστωτικές κάρτες', find=("select id, iban || ' ' || holder text, product from bk_ccard_v order by id",
                                         [('ID', 0, 'Κωδ.', 'FIND_ID'), ('TEXT', 380, 'Κάρτα · κάτοχος', 'FIND_TEXT'),
                                          ('PRODUCT', 60, 'Προϊόν', None)]),
    blocks=[dict(name='CC', table='BK_CCARD_V', order='id', top=TOP, rows=6, read_only=True,
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('IBAN', 'Λογαριασμός κάρτας', 220, len=27),
                       C('PRODUCT', 'Προϊόν', 54, len=10),
                       C('HOLDER', 'Κάτοχος', 150, len=100),
                       C('STATUS', 'Κατ.', 36, len=1),
                       C('CURRENCY', 'Νόμ.', 40, len=3),
                       C('BRANCH_CODE', 'Υποκ.', 46, len=4),
                       C('CREDIT_LIMIT', 'Όριο', 96, num=True, mask=MONEY),
                       C('OWED', 'Οφειλή', 96, num=True, mask=MONEY),
                       C('HELD', 'Δεσμευμένα', 86, num=True, mask=MONEY),
                       C('AVAILABLE', 'Διαθέσιμο', 96, num=True, mask=MONEY),
                       C('STMT_DAY', 'Ημ. κίν.', 50, num=True),
                       C('LAST_STMT', 'Τελ. κίνηση', 84, date=True)]),
            dict(name='CST', table='BK_CC_STATEMENT_V', order='stmt_date desc', top=TOP + 6 * ROW_H + 40, rows=5,
                 read_only=True, where='account_id = :CC.ID',
                 cols=[C('STMT_DATE', 'Κίνηση', 84, date=True),
                       C('PERIOD_FROM', 'Από', 84, date=True),
                       C('OPENING', 'Προηγούμενο', 90, num=True, mask=MONEY),
                       C('PURCHASES', 'Αγορές', 90, num=True, mask=MONEY),
                       C('PAYMENTS', 'Πληρωμές', 90, num=True, mask=MONEY),
                       C('INTEREST', 'Τόκοι', 76, num=True, mask=MONEY),
                       C('FEES', 'Τέλη', 66, num=True, mask=MONEY),
                       C('CLOSING', 'Νέο υπόλοιπο', 96, num=True, mask=MONEY),
                       C('MIN_DUE', 'Ελάχιστη', 86, num=True, mask=MONEY),
                       C('DUE_DATE', 'Λήξη', 84, date=True),
                       C('LATE_FEE', 'Καθυστ.', 60, num=True, mask=MONEY),
                       C('STMT_TEXT', '', 0, len=10, hidden=True),
                       C('FROM_TEXT', '', 0, len=10, hidden=True)])],
    ctl=[('L_LIMIT', 'text', 10, 402, 110, 'Νέο όριο (€)', {'num': True}),
         ('SETLIMIT', 'button', 126, 400, 150, 'Αλλαγή ορίου', {'role': 'MANAGER'}),
         ('PRINTSTMT', 'button', 282, 400, 300, 'Εκτύπωση της επιλεγμένης κίνησης', {}),
         ('P_FROM_TEXT', 'text', 10, 452, 400, 'Πληρωμή από λογαριασμό (λίστα)', {'len': 200, 'lov': 'LOV_PACC'}),
         ('P_FROM_ID', 'hidden', 0, 0, 0, '', {'num': True}),
         ('P_AMOUNT', 'text', 416, 452, 110, 'Ποσό (€)', {'num': True}),
         ('PAYCC', 'button', 532, 450, 170, 'Πληρωμή', {}),
         ('PAYCASH', 'button', 708, 450, 170, 'Πληρωμή μετρητοίς', {}),
         ('Q_AMOUNT', 'text', 10, 502, 110, 'Αγορά: ποσό', {'num': True}),
         ('Q_CURRENCY', 'text', 126, 502, 80, 'Νόμισμα (λίστα)', {'len': 3, 'upper': True, 'lov': 'LOV_QCUR'}),
         ('Q_MERCHANT', 'text', 212, 502, 230, 'Κατάστημα', {'len': 100}),
         ('BUY', 'button', 448, 500, 170, 'Αγορά (δοκιμή)', {}),
         ('N_CUST_TEXT', 'text', 10, 552, 300, 'Νέα κάρτα: πελάτης (λίστα)', {'len': 200, 'lov': 'LOV_CUST'}),
         ('N_CUST_ID', 'hidden', 0, 0, 0, '', {'num': True}),
         ('N_PRODUCT', 'text', 316, 552, 70, 'Προϊόν (λίστα)', {'len': 10, 'upper': True, 'lov': 'LOV_CCPROD', 'init': 'VISA'}),
         ('N_LIMIT', 'text', 392, 552, 100, 'Όριο (€)', {'num': True}),
         ('N_DAY', 'text', 498, 552, 70, 'Ημ. κίνησης', {'num': True}),
         ('NEWCC', 'button', 574, 550, 220, 'Νέα πιστωτική κάρτα', {'role': 'MANAGER'}),
         ('C_RESULT', 'display', 10, 602, 860, 'Το PIN της νέας κάρτας (μία φορά)', {'len': 300}),
         ('F_BRANCH', 'text', 10, 652, 80, 'Φίλτρο υποκ. (λίστα)', {'len': 4, 'lov': 'LOV_FBR'}),
         ('FILTERBR', 'button', 96, 650, 220, 'Μόνο αυτού (κενό: όλα)', {})],
    lovs=[('LOV_PACC', 'Λογαριασμοί', CC_PAY_LOV, [('ID', 0, 'Κωδ.', 'CTL.P_FROM_ID'), ('TEXT', 380, 'Λογαριασμός', 'CTL.P_FROM_TEXT')]),
          ('LOV_CUST', 'Πελάτες', "select id, name || ' ' || afm text from bk_customer where active = 'Y' order by name",
           [('ID', 0, 'Κωδ.', 'CTL.N_CUST_ID'), ('TEXT', 320, 'Πελάτης', 'CTL.N_CUST_TEXT')]),
          ('LOV_CCPROD', 'Προϊόντα καρτών', "select code, name from bk_product where kind = 'CC' and active = 'Y' order by id",
           [('CODE', 70, 'Προϊόν', 'CTL.N_PRODUCT'), ('NAME', 220, 'Όνομα', None)]),
          currency_lov('LOV_QCUR', 'CTL.Q_CURRENCY'), branch_lov('LOV_FBR', 'CTL.F_BRANCH')])

# the loans (BK_LOAN_V): the loan on the screen, its schedule below; a new one (MANAGER: paid to an account of the
# bank, its customer the primary holder of it; its installment first: "Δόση"), what pays it off today, a prepayment
# (MANAGER: the same installment and fewer, or a smaller one), paid off (MANAGER), its schedule printed
LOAN_PAY_LOV = ("select a.id, a.iban || ' ' || a.holder || ' ' || a.currency text from bk_account_v a, bk_product p "
                "where a.status = 'O' and p.code = a.product and p.kind not in ('CC', 'LN') order by a.id")
PREPAY_MODES = (('T', 'Ίδια δόση, λιγότερες δόσεις'), ('P', 'Ίδιοι μήνες, μικρότερη δόση'))
FORMS['BK_LOANS'] = dict(
    title='Δάνεια',
    find_title='Δάνεια', find=("select id, iban || ' ' || holder text, product from bk_loan_v order by id",
                              [('ID', 0, 'Κωδ.', 'FIND_ID'), ('TEXT', 380, 'Δάνειο · δικαιούχος', 'FIND_TEXT'),
                               ('PRODUCT', 60, 'Προϊόν', None)]),
    blocks=[dict(name='LN', table='BK_LOAN_V', order='id', top=TOP, rows=6, read_only=True,
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('IBAN', 'Λογαριασμός δανείου', 220, len=27),
                       C('PRODUCT', 'Προϊόν', 50, len=10),
                       C('HOLDER', 'Δικαιούχος', 150, len=100),
                       C('CURRENCY', 'Νόμ.', 40, len=3),
                       C('BRANCH_CODE', 'Υποκ.', 46, len=4),
                       C('STATUS', 'Κατ.', 36, len=1),
                       C('PRINCIPAL', 'Κεφάλαιο', 96, num=True, mask=MONEY),
                       C('MONTHS', 'Μήνες', 46, num=True),
                       C('RATE', 'Επιτ. %', 60, num=True, mask=MONEY4),
                       C('OWED', 'Οφειλή', 96, num=True, mask=MONEY),
                       C('NEXT_DUE', 'Επόμ. δόση', 84, date=True),
                       C('LATE', 'Καθυστ.', 50, num=True)]),
            dict(name='SCH', table='BK_LN_SCHEDULE', order='n', top=TOP + 6 * ROW_H + 40, rows=10, read_only=True,
                 where='account_id = :LN.ID',
                 cols=[C('N', 'Δόση', 40, num=True),
                       C('DUE_DATE', 'Λήξη', 84, date=True),
                       C('RATE', 'Επιτ. %', 60, num=True, mask=MONEY4),
                       C('PRINCIPAL', 'Κεφάλαιο', 90, num=True, mask=MONEY),
                       C('INTEREST', 'Τόκος', 80, num=True, mask=MONEY),
                       C('PAYMENT', 'Δόση', 90, num=True, mask=MONEY),
                       C('BALANCE', 'Υπόλοιπο', 100, num=True, mask=MONEY),
                       C('STATUS', 'Κατ.', 36, len=1),
                       C('PAID', 'Πληρώθηκαν', 90, num=True, mask=MONEY),
                       C('PAID_ON', 'Στις', 84, date=True),
                       C('LATE_FEE', 'Τέλος', 66, num=True, mask=MONEY),
                       C('LATE_BOOKED', 'Τόκοι υπερ.', 76, num=True, mask=MONEY)])],
    ctl=[('PAYOFF', 'button', 10, 580, 200, 'Ποσό εξόφλησης σήμερα', {}),
         ('X_PAYOFF', 'display', 216, 582, 160, '', {'len': 40}),
         ('PRINTSCH', 'button', 382, 580, 260, 'Εκτύπωση προγράμματος', {}),
         ('P_AMOUNT', 'text', 10, 632, 110, 'Πρόωρη εξόφληση: ποσό', {'num': True}),
         ('P_MODE', 'text', 126, 632, 40, 'Τρόπος (λίστα)', {'len': 1, 'upper': True, 'lov': 'LOV_PMODE', 'init': 'T'}),
         ('P_MODE_TEXT', 'display', 172, 632, 220, '', {'len': 60}),
         ('PREPAY', 'button', 398, 630, 180, 'Πρόωρη εξόφληση', {'role': 'MANAGER'}),
         ('PAYALL', 'button', 584, 630, 180, 'Ολική εξόφληση', {'role': 'MANAGER'}),
         ('N_PAY_TEXT', 'text', 10, 684, 330, 'Νέο δάνειο: λογαριασμός του πελάτη (λίστα)', {'len': 200, 'lov': 'LOV_LPAY'}),
         ('N_PAY_ID', 'hidden', 0, 0, 0, '', {'num': True}),
         ('N_PRODUCT', 'text', 346, 684, 70, 'Προϊόν (λίστα)', {'len': 10, 'upper': True, 'lov': 'LOV_LNPROD', 'init': 'CONS'}),
         ('N_AMOUNT', 'text', 422, 684, 100, 'Ποσό', {'num': True}),
         ('N_MONTHS', 'text', 528, 684, 60, 'Μήνες', {'num': True}),
         ('N_DAY', 'text', 594, 684, 60, 'Ημ. δόσης', {'num': True}),
         ('QUOTE', 'button', 660, 682, 100, 'Δόση', {}),
         ('NEWLOAN', 'button', 766, 682, 150, 'Νέο δάνειο', {'role': 'MANAGER'}),
         ('N_RESULT', 'display', 10, 734, 900, 'Αποτέλεσμα', {'len': 300}),
         ('F_BRANCH', 'text', 656, 582, 80, 'Φίλτρο υποκ. (λίστα)', {'len': 4, 'lov': 'LOV_FBR'}),
         ('FILTERBR', 'button', 742, 580, 200, 'Μόνο αυτού (κενό: όλα)', {})],
    lovs=[('LOV_LPAY', 'Λογαριασμοί', LOAN_PAY_LOV, [('ID', 0, 'Κωδ.', 'CTL.N_PAY_ID'), ('TEXT', 400, 'Λογαριασμός', 'CTL.N_PAY_TEXT')]),
          ('LOV_LNPROD', 'Προϊόντα δανείων', "select code, name from bk_product where kind = 'LN' and active = 'Y' order by id",
           [('CODE', 70, 'Προϊόν', 'CTL.N_PRODUCT'), ('NAME', 260, 'Όνομα', None)]),
          words_lov('LOV_PMODE', 'Πρόωρη εξόφληση', PREPAY_MODES, 'CTL.P_MODE', 'CTL.P_MODE_TEXT', w=240),
          branch_lov('LOV_FBR', 'CTL.F_BRANCH')])

# the branches (BK_BRANCH_V: its accounts, users, ATMs, its cash), the accounts of the one on the screen below; a
# branch new or changed, active or not (MANAGER); its cash printed (from - to)
FORMS['BK_BRANCHES'] = dict(
    title='Υποκαταστήματα',
    blocks=[dict(name='BR', table='BK_BRANCH_V', order='code', top=TOP, rows=6, read_only=True,
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('CODE', 'Κωδ.', 50, len=4),
                       C('NAME', 'Υποκατάστημα', 200, len=60),
                       C('CITY', 'Πόλη', 120, len=60),
                       C('ADDRESS', 'Διεύθυνση', 230, len=200),
                       C('ACTIVE', 'Ενεργό', 50, len=1),
                       C('ACCOUNTS', 'Λογαρ.', 56, num=True),
                       C('USERS', 'Χρήστες', 56, num=True),
                       C('ATMS', 'ATM', 40, num=True),
                       C('CASH', 'Ταμείο (€)', 110, num=True, mask=MONEY)]),
            dict(name='BACC', table='BK_ACCOUNT_V', order='id', top=TOP + 6 * ROW_H + 40, rows=10, read_only=True,
                 where='branch_code = :BR.CODE',
                 cols=[C('IBAN', 'IBAN', 220, len=27),
                       C('PRODUCT', 'Προϊόν', 54, len=10),
                       C('HOLDER', 'Δικαιούχος', 200, len=100),
                       C('STATUS', 'Κατ.', 36, len=1),
                       C('CURRENCY', 'Νόμ.', 40, len=3),
                       C('BALANCE', 'Υπόλοιπο', 110, num=True, mask=MONEY)])],
    ctl=[('S_CODE', 'text', 10, 532, 60, 'Κωδικός', {'len': 4}),
         ('S_NAME', 'text', 76, 532, 200, 'Όνομα', {'len': 60}),
         ('S_CITY', 'text', 282, 532, 120, 'Πόλη', {'len': 60}),
         ('S_ADDRESS', 'text', 408, 532, 230, 'Διεύθυνση', {'len': 200}),
         ('SAVEBR', 'button', 644, 530, 220, 'Αποθήκευση υποκαταστήματος', {'role': 'MANAGER'}),
         ('TOGGLEBR', 'button', 644, 566, 220, 'Ενεργό / ανενεργό', {'role': 'MANAGER'}),
         # the report of its cash (reports/mkreports.py: BK_BR_CASH), from - to
         ('P_FROM', 'date', 10, 612, 100, 'Από', {'year_start': True}),
         ('P_TO', 'date', 116, 612, 100, 'Έως', {}),
         ('PRINTCASH', 'button', 222, 610, 240, 'Εκτύπωση ταμείου', {})])

# the suspicious movements (BK_AI_ALERT_V: db/BK_AI.sql, Oracle Machine Learning): the new ones first, the most
# suspicious first; the last moves of the account of the one on the screen below. Not a fraud, or a fraud (its
# account blocked), a note; the scan of a day; the model trained again (ADMIN); the model in a line
FORMS['BK_AI'] = dict(
    title='Ύποπτες κινήσεις',
    blocks=[dict(name='AL', table='BK_AI_ALERT_V', order="case status when 'N' then 0 else 1 end, score desc, id",
                 top=TOP, rows=8, read_only=True,
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('ACCOUNT_ID', '', 0, num=True, hidden=True),
                       C('BOOK_DATE', 'Ημέρα', 80, date=True),
                       C('AT_TIME', 'Ώρα', 44, len=5),
                       C('IBAN', 'Λογαριασμός', 200, len=27),
                       C('HOLDER', 'Δικαιούχος', 130, len=100),
                       C('KIND', 'Είδος', 40, len=3),
                       C('AMOUNT', 'Ποσό', 86, num=True, mask=MONEY),
                       C('CURRENCY', 'Νόμ.', 36, len=3),
                       C('SCORE', 'Βαθμός', 50, num=True, mask='0D000'),
                       C('STATUS', 'Κατ.', 32, len=1),
                       C('REASONS', 'Γιατί (το μοντέλο)', 380, len=400)]),
            dict(name='AST', table='BK_STATEMENT_LINE', order=STATEMENT_ORDER, top=TOP + 8 * ROW_H + 40, rows=8,
                 read_only=True, where='account_id = :AL.ACCOUNT_ID', cols=statement_cols())],
    ctl=[('R_NOTE', 'text', 10, 500, 300, 'Σημείωση', {'len': 200}),
         ('OKAY', 'button', 316, 498, 220, 'Δεν είναι απάτη', {'role': 'MANAGER'}),
         ('FRAUD', 'button', 542, 498, 300, 'Απάτη: δέσμευση λογαριασμού', {'role': 'MANAGER'}),
         ('S_DAY', 'date', 10, 548, 100, 'Ημέρα', {}),
         ('SCAN', 'button', 116, 546, 220, 'Σάρωση της ημέρας', {'role': 'MANAGER'}),
         ('TRAIN', 'button', 342, 546, 260, 'Εκπαίδευση μοντέλου', {'role': 'ADMIN'}),
         ('X_MODEL', 'display', 10, 596, 900, 'Το μοντέλο', {'len': 300})])

# the search by meaning (db/BK_VECTOR.sql, AI Vector Search): a question in own words (Enter), of an account or
# of all; the movements nearest in meaning (BK_AI_HIT: bk_vec.fill_hits), the category of the question and all its
# movements; below, what the account spent in 12 months by category
FORMS['BK_SEARCH'] = dict(
    title='Αναζήτηση με το νόημα',
    blocks=[dict(name='HIT', table='BK_AI_HIT', order='seq', top=TOP, rows=12, read_only=True,
                 cols=[C('SEQ', '', 0, num=True, hidden=True),
                       C('ACCOUNT_ID', '', 0, num=True, hidden=True),
                       C('BOOK_DATE', 'Ημέρα', 80, date=True),
                       C('IBAN', 'Λογαριασμός', 200, len=34),
                       C('HOLDER', 'Δικαιούχος', 140, len=200),
                       C('DESCR', 'Περιγραφή', 260, len=200),
                       C('DEBIT', 'Χρέωση', 86, num=True, mask=MONEY),
                       C('CREDIT', 'Πίστωση', 86, num=True, mask=MONEY),
                       C('CURRENCY', 'Νόμ.', 36, len=3),
                       C('SIMILARITY', 'Ομοιότητα', 64, num=True, mask='0D000'),
                       C('CATEGORY', 'Κατηγορία', 150, len=60)]),
            dict(name='SPEND', table='BK_AI_SPEND12_V', order='amount desc', top=TOP + 12 * ROW_H + 40, rows=6,
                 read_only=True, where='account_id = -1',
                 cols=[C('NAME', 'Κατηγορία (12 μήνες του λογαριασμού)', 260, len=60),
                       C('AMOUNT', 'Έξοδα (€)', 110, num=True, mask=MONEY),
                       C('MOVEMENTS', 'Κινήσεις', 70, num=True)])],
    ctl=[('Q', 'text', 10, 572, 420, 'Τι ψάχνεις, με δικά σου λόγια (Enter)', {'len': 500, 'enter': True}),
         ('S_ACC_TEXT', 'text', 436, 572, 300, 'Λογαριασμός (λίστα· κενό: όλοι)', {'len': 200, 'lov': 'LOV_SACC'}),
         ('S_ACC_ID', 'hidden', 0, 0, 0, '', {'num': True}),
         ('SEARCH', 'button', 742, 570, 140, 'Αναζήτηση', {}),
         ('X_CAT', 'display', 10, 620, 420, 'Η κατηγορία της ερώτησης', {'len': 100}),
         ('X_CAT_CODE', 'hidden', 0, 0, 0, '', {'len': 4}),
         ('CATALL', 'button', 436, 618, 300, 'Όλες οι κινήσεις της κατηγορίας', {}),
         ('X_MODEL', 'display', 10, 668, 870, 'Το μοντέλο', {'len': 300})],
    lovs=[('LOV_SACC', 'Λογαριασμοί', ACCOUNTS_LOV, [('ID', 0, 'Κωδ.', 'CTL.S_ACC_ID'), ('TEXT', 380, 'Λογαριασμός', 'CTL.S_ACC_TEXT')])])

# the assistant of the teller (db/BK_RAG.sql: RAG, a local LLM): a question in Greek (Enter); the answer from the
# pieces of knowledge nearest to it (the facts of the bank, the guides), with their numbers; the pieces below; the
# knowledge again (MANAGER: the products or the rules changed)
FORMS['BK_ASSIST'] = dict(
    title='Βοηθός ταμία',
    blocks=[dict(name='SRC', table='BK_AI_QUESTION_SRC', order='n', top=360, rows=6, read_only=True,
                 where='question_id = -1',
                 cols=[C('N', 'Αρ.', 30, num=True),
                       C('SOURCE', 'Πηγή', 150, len=100),
                       C('TITLE', 'Ενότητα', 230, len=300),
                       C('SIMILARITY', 'Ομοιότητα', 64, num=True, mask='0D000'),
                       C('TEXT', 'Το απόσπασμα', 440, len=4000)])],
    ctl=[('Q', 'text', 10, 40, 760, 'Η ερώτηση (Enter), π.χ. Πόσα μπορεί να σηκώσει ένας πελάτης από ATM την ημέρα;',
          {'len': 1000, 'enter': True}),
         ('ASK', 'button', 776, 38, 140, 'Ρώτα', {}),
         ('Q_ID', 'hidden', 0, 0, 0, '', {'num': True}),
         ('X_ANSWER', 'text', 10, 96, 906, 'Η απάντηση (οι αριθμοί σε αγκύλες: τα αποσπάσματα από κάτω)', {'len': 4000, 'lines': 9}),
         ('X_TIME', 'display', 10, 322, 500, '', {'len': 200}),
         ('KNOW', 'button', 716, 320, 200, 'Ανανέωση γνώσης', {'role': 'MANAGER'}),
         ('X_INFO', 'display', 10, 520, 906, 'Ο βοηθός', {'len': 300})])

# the currencies (BK_CURRENCY_V: the last rate of each) and the rates of the one on the screen below, the newest
# first; a rate from a day on, a currency new or changed, active or not (MANAGER); an amount converted (anyone)
FORMS['BK_FX'] = dict(
    title='Νομίσματα και ισοτιμίες',
    blocks=[dict(name='CURR', table='BK_CURRENCY_V', order="case code when 'EUR' then 0 else 1 end, code", top=TOP,
                 rows=10, read_only=True,
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('CODE', 'Κωδ.', 50, len=3),
                       C('NAME', 'Νόμισμα', 200, len=60),
                       C('DECIMALS', 'Δεκαδικά', 64, num=True),
                       C('SPREAD_PCT', 'Περιθώριο %', 90, num=True, mask='990D000'),
                       C('ACTIVE', 'Ενεργό', 50, len=1),
                       C('MID', '1 EUR =', 120, num=True, mask='999G990D9999'),
                       C('RATE_DAY', 'Από', 84, date=True)]),
            dict(name='FXR', table='BK_FX_RATE', order='day desc', top=TOP + 10 * ROW_H + 40, rows=8,
                 read_only=True, where='currency = :CURR.CODE',
                 cols=[C('DAY', 'Ημέρα', 90, date=True),
                       C('MID', '1 EUR =', 120, num=True, mask='999G990D9999')])],
    ctl=[('R_DAY', 'date', 10, 560, 100, 'Ισοτιμία από', {}),
         ('R_MID', 'text', 116, 560, 110, '1 EUR =', {'num': True}),
         ('SETFX', 'button', 232, 558, 260, 'Νέα ισοτιμία (του νομίσματος)', {'role': 'MANAGER'}),
         ('S_CODE', 'text', 10, 610, 50, 'Κωδικός', {'len': 3, 'upper': True}),
         ('S_NAME', 'text', 66, 610, 200, 'Όνομα', {'len': 60}),
         ('S_DEC', 'text', 272, 610, 60, 'Δεκαδικά', {'num': True, 'init': '2'}),
         ('S_SPREAD', 'text', 338, 610, 80, 'Περιθώριο %', {'num': True, 'init': '0.5'}),
         ('SAVECUR', 'button', 424, 608, 220, 'Αποθήκευση νομίσματος', {'role': 'MANAGER'}),
         ('TOGGLECUR', 'button', 650, 608, 220, 'Ενεργό / ανενεργό', {'role': 'MANAGER'}),
         ('X_AMOUNT', 'text', 10, 660, 110, 'Μετατροπή: ποσό', {'num': True}),
         ('X_FROM', 'text', 126, 660, 60, 'Από (λίστα)', {'len': 3, 'upper': True, 'lov': 'LOV_XFROM', 'init': 'EUR'}),
         ('X_TO', 'text', 192, 660, 60, 'Σε (λίστα)', {'len': 3, 'upper': True, 'lov': 'LOV_XTO', 'init': 'USD'}),
         ('CONVERT', 'button', 258, 658, 150, 'Μετατροπή', {}),
         ('X_RESULT', 'display', 414, 660, 470, 'Αποτέλεσμα (μέση τιμή · ο πελάτης παίρνει)', {'len': 200})],
    lovs=[currency_lov('LOV_XFROM', 'CTL.X_FROM'), currency_lov('LOV_XTO', 'CTL.X_TO')])

# the ATMs and their cassettes (the notes they give: the setting ATM_NOTES); a cassette of the ATM on the screen
# filled (+) or emptied (-); the notes of all the ATMs, the most of one withdrawal (MANAGER)
FORMS['BK_ATMS'] = dict(
    title='ATM',
    blocks=[dict(name='ATMS', table='BK_ATM', order='code', top=TOP, rows=5, read_only=True,
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('CODE', 'Κωδικός', 70, len=10),
                       C('NAME', 'Όνομα', 200, len=60),
                       C('ADDRESS', 'Διεύθυνση', 260, len=200),
                       C('CASH', 'Μετρητά', 110, num=True, mask=MONEY),
                       C('DEPOSITS', 'Καταθέσεις', 110, num=True, mask=MONEY),
                       C('ACTIVE', 'Ενεργό', 50, len=1),
                       C('BRANCH_CODE', 'Υποκ.', 46, len=4)]),
            dict(name='CAS', table='BK_ATM_NOTE', order='note desc', top=TOP + 5 * ROW_H + 40, rows=6, read_only=True,
                 where='atm_id = :ATMS.ID',
                 cols=[C('NOTE', 'Χαρτονόμισμα (€)', 120, num=True),
                       C('PIECES', 'Κομμάτια', 100, num=True)])],
    ctl=[('F_NOTE', 'text', 300, 260, 110, 'Χαρτονόμισμα (λίστα)', {'num': True, 'lov': 'LOV_NOTE'}),
         ('F_PIECES', 'text', 416, 260, 110, 'Κομμάτια (+/-)', {'num': True}),
         ('FILL', 'button', 532, 258, 220, 'Γέμισμα κασέτας', {'role': 'MANAGER'}),
         ('S_NOTES', 'text', 300, 320, 110, 'Χαρτονομίσματα (π.χ. 20,50)', {'len': 40}),
         ('S_MAX', 'text', 416, 320, 110, 'Μέγιστο ανά ανάληψη', {'num': True}),
         ('SETNOTES', 'button', 532, 318, 220, 'Χαρτονομίσματα των ATM', {'role': 'MANAGER'}),
         ('M_BRANCH', 'text', 300, 380, 110, 'Υποκ. (λίστα)', {'len': 4, 'lov': 'LOV_MBR'}),
         ('SETATMBR', 'button', 532, 378, 220, 'Υποκατάστημα του ATM', {'role': 'MANAGER'})],
    lovs=[('LOV_NOTE', 'Χαρτονομίσματα', "select to_number(regexp_substr(v, '[^,]+', 1, level)) note "
                                         "from (select value v from bk_setting where name = 'ATM_NOTES') "
                                         "connect by level <= regexp_count(v, ',') + 1 order by 1 desc",
           [('NOTE', 120, 'Χαρτονόμισμα (€)', 'CTL.F_NOTE')]), branch_lov('LOV_MBR', 'CTL.M_BRANCH')])

# the users (ADMIN): the list; a new one, a new password, the role, active, unlocked (BK_AUTH: the same as the pages)
FORMS['BK_USERS'] = dict(
    title='Χρήστες',
    blocks=[dict(name='USR', table='BK_USER', order='username', top=TOP, rows=10, read_only=True,
                 cols=[C('ID', '', 0, num=True, hidden=True),
                       C('USERNAME', 'Χρήστης', 130, len=30),
                       C('FULL_NAME', 'Ονοματεπώνυμο', 220, len=100),
                       C('ROLE', 'Ρόλος', 80, len=10),
                       C('ACTIVE', 'Ενεργός', 54, len=1),
                       C('FAILED', 'Λάθη', 40, num=True),
                       C('BRANCH_CODE', 'Υποκ.', 46, len=4),
                       C('CREATED_AT', 'Από', 90, date=True)])],
    ctl=[('U_NAME', 'text', 10, 340, 130, 'Νέος χρήστης', {'len': 30, 'lower': True}),
         ('U_FULL', 'text', 146, 340, 200, 'Ονοματεπώνυμο', {'len': 100}),
         ('U_ROLE', 'text', 352, 340, 90, 'Ρόλος (λίστα)', {'len': 10, 'upper': True, 'init': 'TELLER', 'lov': 'LOV_ROLE'}),
         ('U_PW', 'secret', 448, 340, 140, 'Κωδικός', {'len': 200}),
         ('U_PW2', 'secret', 594, 340, 140, 'Ξανά ο κωδικός', {'len': 200}),
         ('NEWUSER', 'button', 10, 380, 200, 'Νέος χρήστης', {}),
         ('SETPW', 'button', 216, 380, 230, 'Νέος κωδικός (επιλεγμένου)', {}),
         ('SETROLE', 'button', 452, 380, 200, 'Ρόλος (επιλεγμένου)', {}),
         ('TOGGLEACT', 'button', 10, 414, 200, 'Ενεργός / ανενεργός', {}),
         ('UNLOCK', 'button', 216, 414, 230, 'Ξεκλείδωμα', {}),
         ('U_BRANCH', 'text', 740, 340, 80, 'Υποκ. (λίστα)', {'len': 4, 'lov': 'LOV_UBR'}),
         ('SETUBR', 'button', 452, 414, 230, 'Υποκατάστημα (επιλεγμένου)', {})],
    lovs=[words_lov('LOV_ROLE', 'Ρόλοι', ROLES, 'CTL.U_ROLE', w=160), branch_lov('LOV_UBR', 'CTL.U_BRANCH')])

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
              'BK_MOVE': 'TELLER', 'BK_DAY': 'TELLER', 'BK_RULES': 'TELLER', 'BK_PRODUCTS': 'TELLER',
              'BK_CARDS': 'TELLER', 'BK_CCARDS': 'TELLER', 'BK_LOANS': 'TELLER', 'BK_FX': 'TELLER', 'BK_BRANCHES': 'TELLER', 'BK_ATMS': 'TELLER', 'BK_USERS': 'ADMIN',
              'BK_AI': 'MANAGER', 'BK_SEARCH': 'TELLER', 'BK_ASSIST': 'TELLER'}

# the first menu: a button for each form (NEW_FORM), the business day, the logout, the exit
MENU_FORMS = [('BK_CUSTOMERS', 'Πελάτες'), ('BK_ACCOUNTS', 'Λογαριασμοί'), ('BK_MOVE', 'Κίνηση'),
              ('BK_CARDS', 'Κάρτες'), ('BK_CCARDS', 'Πιστωτικές κάρτες'), ('BK_LOANS', 'Δάνεια'), ('BK_RULES', 'Κανόνες κινήσεων'), ('BK_PRODUCTS', 'Προϊόντα και επιτόκια'),
              ('BK_FX', 'Νομίσματα και ισοτιμίες'), ('BK_BRANCHES', 'Υποκαταστήματα'),
              ('BK_ATMS', 'ATM'), ('BK_DAY', 'Ημέρα και κλείσιμο'), ('BK_AI', 'Ύποπτες κινήσεις'), ('BK_SEARCH', 'Αναζήτηση με το νόημα'), ('BK_ASSIST', 'Βοηθός ταμία'), ('BK_USERS', 'Χρήστες')]
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
                         ('CARDS', 'Κάρτες', "new_form('BK_CARDS');"),
                         ('CCARDS', 'Πιστωτικές κάρτες', "new_form('BK_CCARDS');"),
                         ('LOANS', 'Δάνεια', "new_form('BK_LOANS');"),
                         ('DAY', 'Ημέρα και κλείσιμο', "new_form('BK_DAY');"),
                         ('AI', 'Ύποπτες κινήσεις', "new_form('BK_AI');"),
                         ('SEARCH', 'Αναζήτηση με το νόημα', "new_form('BK_SEARCH');"),
                         ('ASSIST', 'Βοηθός ταμία', "new_form('BK_ASSIST');")]),
    ('SETUP', 'Ρυθμίσεις', [('RULES', 'Κανόνες κινήσεων', "new_form('BK_RULES');"),
                            ('PRODUCTS', 'Προϊόντα και επιτόκια', "new_form('BK_PRODUCTS');"),
                            ('FX', 'Νομίσματα και ισοτιμίες', "new_form('BK_FX');"),
                            ('BRANCHES', 'Υποκαταστήματα', "new_form('BK_BRANCHES');"),
                            ('ATMS', 'ATM', "new_form('BK_ATMS');"),
                            ('USERS', 'Χρήστες', "new_form('BK_USERS');")]),
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
    the form does); a block of a role, read only below it; the buttons of the first menu and the items of the bar
    to a form of a higher role, off"""
    out = []
    for b in f.get('blocks', []):
        if b.get('role'):
            out.append("IF NOT at_least('%s') THEN read_only_block('%s'); END IF;" % (b['role'], b['name']))
    if FORM_ROLES.get(name):
        for m, _, items in MENU_BAR:
            for i, _, code in items:
                g = re.match(r"new_form\('(\w+)'\);$", code)
                need = FORM_ROLES.get(g.group(1)) if g else None
                if need and need != 'TELLER':
                    out.append("IF NOT at_least('%s') THEN SET_MENU_ITEM_PROPERTY('%s_MENU.%s', ENABLED, PROPERTY_FALSE); END IF;"
                               % (need, m, i))
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
       kind: button (its label), text / date / secret (a prompt on its left), display, hidden;
       lines: n, a text item of n lines (wrapped, a scroll bar)"""
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
    if o.get('lines'):
        # a text of many lines (an answer): wrapped at the words, a scroll bar
        a.update(Height=ROW_H * o['lines'], MultiLine='true', WrapStyle='Word', ShowVerticalScrollbar='true')
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
            height = max(height, c[3] + ROW_H * c[6].get('lines', 1) + 40)

    lovs = ([('LOV_FIND', f['find_title'], f['find'][0],
              [(n, w, t, 'CTL.' + r if r else None) for n, w, t, r in f['find'][1]])] if 'find' in f else []) \
        + f.get('lovs', [])
    groups, lovx = lov_xml(lovs, texts)

    master = blocks[0] if blocks else dict(name='')
    detail = blocks[1]['name'] if len(blocks) > 1 else ''
    detail2 = blocks[2]['name'] if len(blocks) > 2 else ''
    spec, body = program(name, dict(block=master['name'], where=master.get('where', ''), detail=detail,
                                    detail2=detail2, ctl=f.get('ctl', []), blocks=blocks), texts)
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
