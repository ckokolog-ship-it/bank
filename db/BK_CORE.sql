-- BK_CORE.sql -- the rules of the bank, in one package: everything that writes goes through here (the pages,
-- the forms, the scripts), so they all behave the same.
--
-- No COMMIT inside: the caller commits. Errors: raise_application_error -20100 .. -20199, the text in Greek,
-- the code first ("BK-104: ..."), so a page or a form can show it as it is.
--
-- Double entry: every entry has lines, each a debit or a credit of an account of a customer (BK_ACCOUNT) or
-- of the bank (BK_GL), and its debits equal its credits. The balance of a customer is its credits less its
-- debits. An entry is never changed or deleted: reverse() books its opposite.
--
-- The business day (open_day): the day after the last one closed (BK_DAY), else the setting START_DAY. An
-- entry is booked on it; its value date is that day or later (the interest of a day closed is not counted
-- again).
--
-- The interest: by stretches of days (BK_ACCRUAL), not day by day. In a stretch the balance by value date and
-- the rate of an account stay the same, so its interest is its days x the interest of one day (rounded to 6
-- decimals as each day was): the same, to the last decimal, as day by day (interest_by_day: that way, for a
-- check or an explanation). An account is accrued when it is needed (accrue): at the end of its period of
-- capitalization (close_day: all of them at once, set-based, then capitalized with array DML), at its close,
-- or to be shown; a day as any other close_day touches no account. Its balance by value date at the end of a
-- day: its BALANCE less its lines with a later value date (BK_LINE.VALUE_DATE), never all of its history.

create or replace package bk_core as

  -- the check digits: 'Y' or 'N' (not boolean: SQL and the forms read them alike)
  function afm_ok(p_afm varchar2) return varchar2;
  function iban_ok(p_iban varchar2) return varchar2;
  -- the IBAN of an account: GR, its check digits, the bank (BANK_CODE, 3 digits), the branch (4) and the
  -- number of the account (16)
  function new_iban(p_account_id number) return varchar2;

  -- the business day; the first one (before any entry)
  function open_day return date;
  procedure set_start(p_day date);

  -- the customers
  function new_customer(p_name varchar2, p_afm varchar2 default null, p_phone varchar2 default null,
                        p_email varchar2 default null, p_address varchar2 default null,
                        p_birth_date date default null, p_id_card varchar2 default null) return number;
  -- its data corrected (its AFM too, if it has none yet or it was wrong); inactive (N): no new account
  procedure update_customer(p_customer_id number, p_name varchar2, p_afm varchar2, p_phone varchar2,
                            p_email varchar2, p_address varchar2, p_birth_date date, p_id_card varchar2,
                            p_active varchar2 default 'Y');

  -- the currencies: the base currency of the bank (BASE_CURRENCY: every line in it too); a currency, its decimals
  -- and the margin of the bank on a conversion (SPREAD_PCT, each side of the mid rate); its rate from a day on
  -- (MID: how many of it 1 of the base currency buys); the rate of a day (the latest on or before it; the base
  -- currency: 1); an amount converted (at the mid rate; p_customer Y: as the customer gets it, less the margin of
  -- each currency that is not the base one), rounded to the decimals of p_to
  function base_currency return varchar2;
  procedure set_currency(p_code varchar2, p_name varchar2, p_decimals number default 2, p_spread_pct number default 0.5,
                         p_active varchar2 default 'Y');
  procedure set_fx_rate(p_currency varchar2, p_day date, p_mid number);
  function fx_rate(p_currency varchar2, p_day date default null) return number;
  function fx_convert(p_amount number, p_from varchar2, p_to varchar2, p_day date default null,
                      p_customer varchar2 default 'N') return number;
  -- the currencies a product opens in ('EUR,USD': the first one by default)
  procedure set_currencies(p_product_code varchar2, p_currencies varchar2);

  -- the branches: one new or changed (its code 4 digits; not active: no new account in it); an account moved to
  -- another (its IBAN as it was: an IBAN never changes); the branch of a user (its counter), of an ATM. The branch
  -- of what is done now: set_branch_context (a script; null: none), else that of the user of the session
  -- (CLIENT_IDENTIFIER: the forms, the pages)
  procedure set_branch(p_code varchar2, p_name varchar2, p_city varchar2 default null, p_address varchar2 default null,
                       p_active varchar2 default 'Y');
  procedure set_account_branch(p_account_id number, p_branch_code varchar2);
  procedure set_user_branch(p_username varchar2, p_branch_code varchar2);
  procedure set_atm_branch(p_atm_code varchar2, p_branch_code varchar2);
  procedure set_branch_context(p_branch_code varchar2);
  function session_branch return varchar2;

  -- the products and their rates (% a year, from a day on, by tier, in a currency)
  procedure set_rate(p_product_id number, p_valid_from date, p_min_balance number, p_rate number,
                     p_currency varchar2 default 'EUR');
  function rate_of(p_product_id number, p_day date, p_balance number, p_currency varchar2 default 'EUR') return number;

  -- the accounts: opened on the business day for a customer (its primary holder), in a branch (null: that of the
  -- session, else the first one: its code in the IBAN), in a currency of its product (null: the first of them), joint holders, closed (its balance 0: its interest capitalized first), blocked
  -- (nothing out) or open again. Every amount of an account (its movements, its rules, its limits) in its currency
  function open_account(p_product_code varchar2, p_customer_id number, p_od_limit number default 0,
                        p_name varchar2 default null, p_currency varchar2 default null,
                        p_branch_code varchar2 default null) return number;
  procedure add_holder(p_account_id number, p_customer_id number);
  procedure remove_holder(p_account_id number, p_customer_id number);
  procedure set_status(p_account_id number, p_status varchar2);
  procedure set_od_limit(p_account_id number, p_od_limit number);
  procedure close_account(p_account_id number);

  -- the movements of money: their entry back. A value date: the business day or later (null: the business
  -- day). A channel: BR the counter (the default), WEB e-banking, ATM. Out of an account: open (not blocked),
  -- within its balance and its overdraft limit. Every one within the rules of its account (BK_RULE): allowed,
  -- its amount, the limits of the day and of the month, the balance left; a fee after the free ones of the
  -- month, in the same entry
  function deposit(p_account_id number, p_amount number, p_descr varchar2 default null,
                   p_value_date date default null, p_channel varchar2 default 'BR') return number;
  function withdraw(p_account_id number, p_amount number, p_descr varchar2 default null,
                    p_value_date date default null, p_channel varchar2 default 'BR') return number;
  function transfer(p_from_id number, p_to_id number, p_amount number, p_descr varchar2 default null,
                    p_value_date date default null, p_channel varchar2 default 'BR') return number;
  function transfer_out(p_from_id number, p_amount number, p_iban_to varchar2, p_descr varchar2 default null,
                        p_value_date date default null, p_channel varchar2 default 'BR') return number;
  function transfer_in(p_to_id number, p_amount number, p_iban_from varchar2, p_descr varchar2 default null,
                       p_value_date date default null, p_channel varchar2 default 'BR') return number;

  -- the rules of the movements (BK_RULE): for the bank (p_product_code and p_account_id null), a product or an
  -- account; an op (DEP, WDR, TRO, TRI, OUT, INC) and a channel (* all of them, BR, WEB, ATM); the values (null:
  -- none at this level). Again with the same keys: the rule replaced. Its id back
  function set_rule(p_product_code varchar2, p_account_id number, p_op varchar2, p_channel varchar2,
                    p_allowed varchar2 default null, p_min_amount number default null, p_max_amount number default null,
                    p_day_amount number default null, p_day_count number default null,
                    p_month_amount number default null, p_month_count number default null,
                    p_free_month number default null, p_fee number default null,
                    p_min_balance number default null) return number;
  procedure remove_rule(p_rule_id number);
  -- a value of the rules of an account for an op and a channel (ALLOWED 1/0, MIN_AMOUNT, MAX_AMOUNT,
  -- DAY_AMOUNT, DAY_COUNT, MONTH_AMOUNT, MONTH_COUNT, FREE_MONTH, FEE, MIN_BALANCE): the most particular rule
  -- that has it; null: none. rule_used: what is used of a limit (its period, its channel or all of them)
  function rule_value(p_account_id number, p_op varchar2, p_channel varchar2, p_attr varchar2) return number;
  function rule_used(p_account_id number, p_op varchar2, p_channel varchar2, p_attr varchar2) return number;
  -- the opposite of an entry, booked on the business day (once; not of a reversal, not of interest)
  function reverse(p_entry_id number, p_descr varchar2 default null) return number;

  -- the end of the business day: at the end of a period of capitalization (a month: M; a quarter: Q; a year:
  -- Y) the interest of the accounts of the products of that period accrued up to it and capitalized; then the
  -- day closed. p_day: the business day (a check)
  procedure close_day(p_day date default null);
  -- the interest of an account accrued up to a day closed (null: the last one): its stretches written, ACCRUED
  -- and ACCRUED_TO with them. Again: nothing (or the days after)
  procedure accrue(p_account_id number, p_day date default null);
  -- the interest accrued capitalized now (close_account does it): its entry, or null when nothing
  function capitalize(p_account_id number, p_day date) return number;
  -- the interest of an account day by day, as it was counted before the stretches (each day its balance by
  -- value date, its rate, its days): for a check of the stretches, or to explain them
  function interest_by_day(p_account_id number, p_day_from date, p_day_to date) return number;

  -- the balance of an account by value date at the end of a day
  function value_balance(p_account_id number, p_day date) return number;

  -- the debit cards: of an account and one of its holders (the primary, if none given); its number (PAN, 16
  -- digits: 4, the bank, the card, a Luhn check digit), till the end of its month 4 years on. Status: A active,
  -- B blocked (again A by the bank), C cancelled (for good). Its PIN: kept by bk-api (a hash, never itself)
  function luhn_ok(p_number varchar2) return varchar2;
  function new_card(p_account_id number, p_customer_id number default null) return number;
  procedure set_card_status(p_card_id number, p_status varchar2);
  -- the account of a card that may be used now (active, not expired, its account not closed)
  function card_account(p_card_id number) return number;

  -- the ATMs. The notes they give: the setting ATM_NOTES ('20,50'), each ATM a cassette of each; the most notes
  -- of one withdrawal: ATM_MAX_NOTES (40). A cassette filled (+ pieces) or emptied (-) by the bank
  procedure set_atm_notes(p_notes varchar2, p_max_notes number default null);
  procedure atm_fill(p_atm_code varchar2, p_note number, p_pieces number);
  -- the ways an ATM can give an amount now, with the notes in its cassettes: up to 4, the fewest notes first,
  -- each as '50:4,20:5', separated by ';' (null: none)
  function atm_options(p_atm_code varchar2, p_amount number) return varchar2;
  -- a withdrawal (its notes: p_notes, as '50:4,20:5'; null: the first of atm_options), a deposit (to the bin of
  -- the ATM), a transfer to an account of the bank, by a card: the channel ATM, so within the rules of its
  -- account for the ATM. Their entry back
  function atm_withdraw(p_atm_code varchar2, p_card_id number, p_amount number, p_notes varchar2 default null) return number;
  function atm_deposit(p_atm_code varchar2, p_card_id number, p_amount number) return number;
  function atm_transfer(p_atm_code varchar2, p_card_id number, p_to_iban varchar2, p_amount number) return number;

  -- the credit cards (BK_CCARD): an account of a product of kind CC, its BALANCE below 0 what is owed, a card of
  -- it (new_card: its PAN, its PIN, the ATM). What may be spent: its CREDIT_LIMIT + BALANCE - HELD (the
  -- authorizations not posted yet), read and changed with the row of the account locked (lock_account: every
  -- authorization, purchase, payment and change of the limit waits for the one before it), so two purchases at
  -- once never pass the limit together.
  -- A product of credit cards and its terms (again: changed): its id back
  function set_cc_product(p_code varchar2, p_name varchar2, p_rate number, p_min_pct number default 3,
                          p_min_amount number default 20, p_due_days number default 25, p_late_fee number default 0) return number;
  -- a credit card account for a customer, its limit, the day of its month of its statement (1 .. 28; null: the
  -- business day, up to 28): its account back (its card: new_card)
  function cc_open(p_product_code varchar2, p_customer_id number, p_limit number, p_stmt_day number default null) return number;
  procedure cc_set_limit(p_account_id number, p_limit number);
  function cc_available(p_account_id number) return number;
  -- a purchase: its authorization (the amount held, within what may be spent: its id back), then posted (the
  -- amount, up to that held; null: all of it: its entry PUR back) or released. cc_purchase: both at once
  -- p_currency: the currency of the purchase, if not that of the card (abroad): converted at the mid rate, with
  -- the fee of conversion of its product (FX_FEE_PCT); the entry keeps the amount and the currency it was in
  function cc_authorize(p_card_id number, p_amount number, p_merchant varchar2 default null,
                        p_currency varchar2 default null) return number;
  function cc_capture(p_auth_id number, p_amount number default null) return number;
  procedure cc_release(p_auth_id number);
  function cc_purchase(p_card_id number, p_amount number, p_merchant varchar2 default null,
                       p_currency varchar2 default null) return number;
  -- a payment of a card from an account of the bank (a transfer: its rules); in cash: deposit to its account
  function cc_pay(p_account_id number, p_from_account_id number, p_amount number, p_channel varchar2 default 'BR') return number;
  -- the end of a day for the credit cards (close_day calls it): the authorizations older than CC_HOLD_DAYS
  -- released; the statements due that day: the late fee when less than their minimum was paid; the cards of the
  -- statement day: their interest (none in the grace: the statement before paid in full by its due date; else on
  -- what was owed each day of the period, the purchases from their day), then their statement
  procedure cc_close_day(p_day date);

  -- the loans (BK_LOAN): an account of a product of kind LN, its BALANCE below 0 what is owed; paid from an account
  -- of the customer (in its currency). An index of the variable rates (EURIBOR3M) from a day on; its rate on a day.
  -- A product of loans and its terms (again: changed)
  procedure set_ln_index(p_code varchar2, p_day date, p_rate number);
  function ln_index(p_code varchar2, p_day date default null) return number;
  function set_ln_product(p_code varchar2, p_name varchar2, p_rate_type varchar2, p_rate number,
                          p_index_code varchar2 default null, p_reset_months number default 3, p_late_add number default 2.5,
                          p_late_fee number default 0, p_grace_days number default 5, p_prepay_pct number default 0,
                          p_max_months number default 360) return number;
  -- a loan for a customer: the amount paid to its account p_pay_account_id (which pays its installments), months,
  -- the day of the month of its installments (1 .. 28; null: that of the business day); its schedule (annuity: the
  -- interest of a month the balance x rate / 1200). Its account back
  function ln_open(p_product_code varchar2, p_customer_id number, p_amount number, p_months number,
                   p_pay_account_id number, p_pay_day number default null) return number;
  -- a prepayment of its principal (none late): the interest of its days since the last installment and the fee of
  -- the product, from its account; then p_mode T: the same installment, fewer of them; P: the same months, a
  -- smaller installment. All of it (or more): paid off, closed. Its entry back
  function ln_prepay(p_account_id number, p_amount number, p_mode varchar2 default 'T') return number;
  -- what pays it off today: its principal, the interest of its days, the fee, what is due and not paid
  function ln_payoff(p_account_id number) return number;
  -- the installment of a loan of a product (its rate today), before it is opened
  function ln_quote(p_product_code varchar2, p_amount number, p_months number) return number;
  function ln_rate(p_product_code varchar2) return number;
  -- the end of a day for the loans (close_day calls it): the installments due that day (their interest booked; a
  -- variable rate again, and the installments after it), collected from their account (as much as there is: again
  -- every day); late after GRACE_DAYS (the late fee), late interest each day on what is late (booked at the end
  -- of a month and when collected); a loan all paid: closed
  procedure ln_close_day(p_day date);

end bk_core;
/

create or replace package body bk_core as

  g_branch varchar2(4);                -- set_branch_context: the branch of what is done now (a script)
  g_atm_branch varchar2(4);            -- the branch of the ATM of the movement being done (the ATM functions)

  procedure fail(p_no pls_integer, p_text varchar2) is
  begin
    raise_application_error(-20100 - p_no, 'BK-' || to_char(100 + p_no) || ': ' || p_text);
  end;

  function setting(p_name varchar2) return varchar2 is
    v varchar2(400);
  begin
    select max(value) into v from bk_setting where name = p_name;
    return v;
  end;

  -- ---------------------------------------------------------------------------------------------
  function afm_ok(p_afm varchar2) return varchar2 is
    s number := 0;
  begin
    if p_afm is null or not regexp_like(p_afm, '^[0-9]{9}$') or p_afm = '000000000' then
      return 'N';
    end if;
    for i in 1 .. 8 loop
      s := s + to_number(substr(p_afm, i, 1)) * power(2, 9 - i);
    end loop;
    return case when mod(mod(s, 11), 10) = to_number(substr(p_afm, 9, 1)) then 'Y' else 'N' end;
  end;

  function iban_ok(p_iban varchar2) return varchar2 is
  begin
    if p_iban is null or not regexp_like(p_iban, '^GR[0-9]{25}$') then
      return 'N';
    end if;
    -- the first four to the end, G = 16, R = 27; the whole number mod 97 is 1
    return case when mod(to_number(substr(p_iban, 5) || '1627' || substr(p_iban, 3, 2)), 97) = 1 then 'Y' else 'N' end;
  end;

  -- (the branch: that of the account)
  function new_iban(p_account_id number) return varchar2 is
    br varchar2(4);
    bban varchar2(23);
    chk number;
  begin
    select max(branch_code) into br from bk_account where id = p_account_id;
    bban := lpad(nvl(setting('BANK_CODE'), '999'), 3, '0') || lpad(nvl(br, nvl(setting('BRANCH_CODE'), '0001')), 4, '0')
            || lpad(p_account_id, 16, '0');
    chk := 98 - mod(to_number(bban || '162700'), 97);
    return 'GR' || lpad(chk, 2, '0') || bban;
  end;

  -- ---------------------------------------------------------------------------------------------
  function open_day return date is
    d date;
  begin
    select max(day) + 1 into d from bk_day;
    if d is null then
      d := to_date(setting('START_DAY'), 'YYYY-MM-DD');
    end if;
    if d is null then
      fail(1, 'Δεν έχει οριστεί η πρώτη εργάσιμη ημέρα (set_start)');
    end if;
    return d;
  end;

  procedure set_start(p_day date) is
    n number;
  begin
    select count(*) into n from dual where exists (select 1 from bk_entry) or exists (select 1 from bk_day);
    if n > 0 then
      fail(2, 'Η πρώτη ημέρα δεν αλλάζει: υπάρχουν ήδη κινήσεις ή κλεισμένες ημέρες');
    end if;
    merge into bk_setting s using (select 'START_DAY' name, to_char(trunc(p_day), 'YYYY-MM-DD') value from dual) v
    on (s.name = v.name)
    when matched then update set s.value = v.value
    when not matched then insert (name, value) values (v.name, v.value);
  end;

  -- ---------------------------------------------------------------------------------------------
  function new_customer(p_name varchar2, p_afm varchar2 default null, p_phone varchar2 default null,
                        p_email varchar2 default null, p_address varchar2 default null,
                        p_birth_date date default null, p_id_card varchar2 default null) return number is
    v number;
  begin
    if trim(p_name) is null then
      fail(3, 'Ο πελάτης θέλει ονοματεπώνυμο');
    end if;
    if p_afm is not null and afm_ok(p_afm) = 'N' then
      fail(4, 'Λάθος ΑΦΜ: ' || p_afm);
    end if;
    if p_email is not null and not regexp_like(p_email, '^[^@ ]+@[^@ ]+\.[^@ ]+$') then
      fail(5, 'Λάθος email: ' || p_email);
    end if;
    insert into bk_customer (code, name, afm, phone, email, address, birth_date, id_card)
    values ('T' || substr(rawtohex(sys_guid()), 1, 11), trim(p_name), p_afm, p_phone, p_email, p_address, p_birth_date, p_id_card)
    returning id into v;
    update bk_customer set code = 'C' || lpad(v, 6, '0') where id = v;
    return v;
  exception
    when dup_val_on_index then
      fail(6, 'Υπάρχει ήδη πελάτης με ΑΦΜ ' || p_afm);
  end;

  procedure update_customer(p_customer_id number, p_name varchar2, p_afm varchar2, p_phone varchar2,
                            p_email varchar2, p_address varchar2, p_birth_date date, p_id_card varchar2,
                            p_active varchar2 default 'Y') is
  begin
    if trim(p_name) is null then
      fail(3, 'Ο πελάτης θέλει ονοματεπώνυμο');
    end if;
    if p_afm is not null and afm_ok(p_afm) = 'N' then
      fail(4, 'Λάθος ΑΦΜ: ' || p_afm);
    end if;
    if p_email is not null and not regexp_like(p_email, '^[^@ ]+@[^@ ]+\.[^@ ]+$') then
      fail(5, 'Λάθος email: ' || p_email);
    end if;
    if nvl(p_active, 'Y') not in ('Y', 'N') then
      fail(9, 'Ενεργός: Y ή N');
    end if;
    update bk_customer set name = trim(p_name), afm = p_afm, phone = p_phone, email = p_email, address = p_address,
           birth_date = p_birth_date, id_card = p_id_card, active = nvl(p_active, 'Y')
    where id = p_customer_id;
    if sql%rowcount = 0 then
      fail(9, 'Δεν υπάρχει πελάτης ' || p_customer_id);
    end if;
  exception
    when dup_val_on_index then
      fail(6, 'Υπάρχει ήδη πελάτης με ΑΦΜ ' || p_afm);
  end;

  -- ---------------------------------------------------------------------------------------------
  -- the currencies
  function base_currency return varchar2 is
  begin
    return nvl(setting('BASE_CURRENCY'), 'EUR');
  end;

  procedure currency_ok(p_code varchar2) is
    n number;
  begin
    select count(*) into n from bk_currency where code = upper(p_code) and active = 'Y';
    if n = 0 then
      fail(52, 'Δεν υπάρχει ενεργό νόμισμα ' || p_code);
    end if;
  end;

  procedure set_currency(p_code varchar2, p_name varchar2, p_decimals number default 2, p_spread_pct number default 0.5,
                         p_active varchar2 default 'Y') is
  begin
    if p_code is null or not regexp_like(upper(p_code), '^[A-Z]{3}$') or p_name is null
       or nvl(p_decimals, -1) not between 0 and 3 or nvl(p_spread_pct, -1) not between 0 and 10
       or nvl(p_active, '-') not in ('Y', 'N') then
      fail(52, 'Νόμισμα: κωδικός 3 γραμμάτων (ISO), όνομα, δεκαδικά 0 - 3, περιθώριο 0 - 10 %');
    end if;
    if upper(p_code) = base_currency and (p_active = 'N' or p_spread_pct <> 0) then
      fail(52, 'Το βασικό νόμισμα ' || base_currency || ' μένει ενεργό, χωρίς περιθώριο');
    end if;
    merge into bk_currency c
    using (select upper(p_code) code from dual) v on (c.code = v.code)
    when matched then update set name = p_name, decimals = p_decimals, spread_pct = p_spread_pct, active = p_active
    when not matched then insert (code, name, decimals, spread_pct, active)
                          values (v.code, p_name, p_decimals, p_spread_pct, p_active);
  end;

  procedure set_fx_rate(p_currency varchar2, p_day date, p_mid number) is
  begin
    currency_ok(p_currency);
    if upper(p_currency) = base_currency then
      fail(52, 'Το βασικό νόμισμα ' || base_currency || ' δεν έχει ισοτιμία (1)');
    end if;
    if p_day is null or nvl(p_mid, 0) <= 0 then
      fail(52, 'Η ισοτιμία: μια ημέρα και μια τιμή πάνω από 0');
    end if;
    merge into bk_fx_rate r
    using (select upper(p_currency) currency, trunc(p_day) day from dual) v on (r.currency = v.currency and r.day = v.day)
    when matched then update set mid = p_mid
    when not matched then insert (currency, day, mid) values (v.currency, v.day, p_mid);
  end;

  function fx_rate(p_currency varchar2, p_day date default null) return number is
    d date := trunc(nvl(p_day, open_day));
    v number;
  begin
    if upper(p_currency) = base_currency then
      return 1;
    end if;
    select max(mid) keep (dense_rank last order by day) into v
    from bk_fx_rate where currency = upper(p_currency) and day <= d;
    if v is null then
      fail(52, 'Δεν υπάρχει ισοτιμία του ' || p_currency || ' για τις ' || to_char(d, 'DD/MM/YYYY'));
    end if;
    return v;
  end;

  function fx_convert(p_amount number, p_from varchar2, p_to varchar2, p_day date default null,
                      p_customer varchar2 default 'N') return number is
    v number;
    s1 number := 0;
    s2 number := 0;
    dec_ number;
  begin
    select decimals into dec_ from bk_currency where code = upper(p_to);
    if upper(p_from) = upper(p_to) then
      return round(p_amount, dec_);
    end if;
    v := p_amount / fx_rate(p_from, p_day) * fx_rate(p_to, p_day);
    if p_customer = 'Y' then
      select spread_pct into s1 from bk_currency where code = upper(p_from);
      select spread_pct into s2 from bk_currency where code = upper(p_to);
      v := v * (1 - s1 / 100) * (1 - s2 / 100);
    end if;
    return round(v, dec_);
  exception
    when no_data_found then
      fail(52, 'Δεν υπάρχει νόμισμα ' || p_from || ' ή ' || p_to);
  end;

  procedure set_currencies(p_product_code varchar2, p_currencies varchar2) is
    l varchar2(200) := upper(regexp_replace(p_currencies, '\s', ''));
    c varchar2(3);
    n number;
  begin
    if l is null or not regexp_like(l, '^[A-Z]{3}(,[A-Z]{3})*$') then
      fail(53, 'Τα νομίσματα του προϊόντος: κωδικοί με κόμμα (π.χ. EUR,USD)');
    end if;
    for i in 1 .. regexp_count(l, ',') + 1 loop
      c := regexp_substr(l, '[^,]+', 1, i);
      currency_ok(c);
      if instr(',' || l || ',', ',' || c || ',', 1, 2) > 0 then          -- (instr: the commas shared)
        fail(53, 'Το νόμισμα ' || c || ' δύο φορές');
      end if;
    end loop;
    update bk_product set currencies = l where code = upper(p_product_code);
    if sql%rowcount = 0 then
      fail(10, 'Δεν υπάρχει προϊόν ' || p_product_code);
    end if;
    select count(*) into n from bk_product where code = upper(p_product_code) and kind = 'CC' and l like '%,%';
    if n > 0 then
      fail(53, 'Μια πιστωτική κάρτα έχει ένα νόμισμα');
    end if;
  end;

  function cur_of(p_account_id number) return varchar2 is
    c varchar2(3);
  begin
    select currency into c from bk_account where id = p_account_id;
    return c;
  end;

  -- ---------------------------------------------------------------------------------------------
  -- the branches
  procedure branch_ok(p_code varchar2) is
    n number;
  begin
    select count(*) into n from bk_branch where code = p_code and active = 'Y';
    if n = 0 then
      fail(60, 'Δεν υπάρχει ενεργό υποκατάστημα ' || p_code);
    end if;
  end;

  procedure set_branch(p_code varchar2, p_name varchar2, p_city varchar2 default null, p_address varchar2 default null,
                       p_active varchar2 default 'Y') is
  begin
    if p_code is null or not regexp_like(p_code, '^[0-9]{4}$') or p_name is null or nvl(p_active, '-') not in ('Y', 'N') then
      fail(60, 'Υποκατάστημα: κωδικός 4 ψηφίων, όνομα, ενεργό Y ή N');
    end if;
    merge into bk_branch b
    using (select p_code code from dual) v on (b.code = v.code)
    when matched then update set name = p_name, city = p_city, address = p_address, active = p_active
    when not matched then insert (code, name, city, address, active) values (p_code, p_name, p_city, p_address, p_active);
  end;

  procedure set_account_branch(p_account_id number, p_branch_code varchar2) is
    a bk_account%rowtype;
  begin
    begin
      select * into a from bk_account where id = p_account_id;
    exception
      when no_data_found then fail(8, 'Δεν υπάρχει λογαριασμός ' || p_account_id);
    end;
    branch_ok(p_branch_code);
    if a.status = 'C' then
      fail(12, 'Ο λογαριασμός ' || a.iban || ' είναι κλειστός');
    end if;
    update bk_account set branch_code = p_branch_code where id = p_account_id;
  end;

  procedure set_user_branch(p_username varchar2, p_branch_code varchar2) is
  begin
    branch_ok(p_branch_code);
    update bk_user set branch_code = p_branch_code where username = lower(p_username);
    if sql%rowcount = 0 then
      fail(60, 'Δεν υπάρχει χρήστης ' || p_username);
    end if;
  end;

  procedure set_atm_branch(p_atm_code varchar2, p_branch_code varchar2) is
  begin
    branch_ok(p_branch_code);
    update bk_atm set branch_code = p_branch_code where code = upper(p_atm_code);
    if sql%rowcount = 0 then
      fail(60, 'Δεν υπάρχει ATM ' || p_atm_code);
    end if;
  end;

  procedure set_branch_context(p_branch_code varchar2) is
  begin
    if p_branch_code is not null then
      branch_ok(p_branch_code);
    end if;
    g_branch := p_branch_code;
  end;

  function session_branch return varchar2 is
    v varchar2(4);
  begin
    if g_branch is not null then
      return g_branch;
    end if;
    select max(branch_code) into v from bk_user where username = sys_context('userenv', 'client_identifier');
    return v;
  end;

  -- ---------------------------------------------------------------------------------------------
  procedure set_rate(p_product_id number, p_valid_from date, p_min_balance number, p_rate number,
                     p_currency varchar2 default 'EUR') is
  begin
    currency_ok(p_currency);
    if p_rate is null or p_rate < 0 or p_rate > 100 then
      fail(7, 'Το επιτόκιο: από 0 ως 100 %');
    end if;
    if nvl(p_min_balance, 0) < 0 then
      fail(7, 'Το κλιμάκιο: από 0 και πάνω');
    end if;
    merge into bk_rate r
    using (select p_product_id product_id, upper(p_currency) currency, trunc(p_valid_from) valid_from,
                  nvl(p_min_balance, 0) min_balance from dual) v
    on (r.product_id = v.product_id and r.currency = v.currency and r.valid_from = v.valid_from and r.min_balance = v.min_balance)
    when matched then update set r.rate = p_rate
    when not matched then insert (product_id, currency, valid_from, min_balance, rate)
                          values (v.product_id, v.currency, v.valid_from, v.min_balance, p_rate);
  end;

  function rate_of(p_product_id number, p_day date, p_balance number, p_currency varchar2 default 'EUR') return number is
    v number;
    od number;
  begin
    if p_balance < 0 then
      select od_rate into od from bk_product where id = p_product_id;
      return od;
    end if;
    -- the rates in force that day (the latest VALID_FROM of each tier), the highest tier it reaches
    select max(rate) keep (dense_rank last order by min_balance) into v
    from bk_rate r
    where r.product_id = p_product_id and r.currency = upper(p_currency) and r.min_balance <= p_balance
      and r.valid_from = (select max(x.valid_from) from bk_rate x
                          where x.product_id = r.product_id and x.currency = r.currency and x.min_balance = r.min_balance
                            and x.valid_from <= p_day);
    return nvl(v, 0);
  end;

  -- ---------------------------------------------------------------------------------------------
  function account_row(p_account_id number) return bk_account%rowtype is
    a bk_account%rowtype;
  begin
    select * into a from bk_account where id = p_account_id;
    return a;
  exception
    when no_data_found then
      fail(8, 'Δεν υπάρχει λογαριασμός ' || p_account_id);
  end;

  procedure customer_ok(p_customer_id number) is
    a varchar2(1);
  begin
    select active into a from bk_customer where id = p_customer_id;
    if a = 'N' then
      fail(9, 'Ο πελάτης ' || p_customer_id || ' δεν είναι ενεργός');
    end if;
  exception
    when no_data_found then
      fail(9, 'Δεν υπάρχει πελάτης ' || p_customer_id);
  end;

  function open_account(p_product_code varchar2, p_customer_id number, p_od_limit number default 0,
                        p_name varchar2 default null, p_currency varchar2 default null,
                        p_branch_code varchar2 default null) return number is
    p bk_product%rowtype;
    v number;
    cur varchar2(3);
    br varchar2(4) := nvl(p_branch_code, nvl(session_branch, nvl(setting('BRANCH_CODE'), '0001')));
  begin
    branch_ok(br);
    begin
      select * into p from bk_product where code = upper(p_product_code) and active = 'Y';
    exception
      when no_data_found then fail(10, 'Δεν υπάρχει ενεργό προϊόν ' || p_product_code);
    end;
    customer_ok(p_customer_id);
    if nvl(p_od_limit, 0) < 0 then
      fail(11, 'Το όριο υπερανάληψης: από 0 και πάνω');
    end if;
    if nvl(p_od_limit, 0) > 0 and p.kind <> 'CUR' then
      fail(11, 'Υπερανάληψη μόνο σε λογαριασμό όψεως');
    end if;
    cur := upper(nvl(p_currency, regexp_substr(p.currencies, '[^,]+', 1, 1)));
    if instr(',' || p.currencies || ',', ',' || cur || ',') = 0 then
      fail(53, 'Το προϊόν ' || p.code || ' ανοίγει σε ' || replace(p.currencies, ',', ', ') || ', όχι σε ' || cur);
    end if;
    currency_ok(cur);
    v := fx_rate(cur);                            -- (a rate of it there: every line in the base currency too)
    insert into bk_account (iban, product_id, name, opened_on, od_limit, currency, branch_code)
    values ('GR' || lpad('0', 25, '0'), p.id, p_name, open_day, nvl(p_od_limit, 0), cur, br)
    returning id into v;
    -- (the IBAN first, then the row: new_iban reads the branch of the account)
    declare
      ib varchar2(27) := new_iban(v);
    begin
      update bk_account set iban = ib where id = v;
    end;
    insert into bk_holder (account_id, customer_id, role) values (v, p_customer_id, 'P');
    return v;
  end;

  procedure add_holder(p_account_id number, p_customer_id number) is
    a bk_account%rowtype := account_row(p_account_id);
  begin
    customer_ok(p_customer_id);
    if a.status = 'C' then
      fail(12, 'Ο λογαριασμός ' || a.iban || ' είναι κλειστός');
    end if;
    insert into bk_holder (account_id, customer_id, role) values (p_account_id, p_customer_id, 'J');
  exception
    when dup_val_on_index then
      fail(13, 'Ο πελάτης είναι ήδη δικαιούχος του ' || a.iban);
  end;

  procedure remove_holder(p_account_id number, p_customer_id number) is
  begin
    delete from bk_holder where account_id = p_account_id and customer_id = p_customer_id and role = 'J';
    if sql%rowcount = 0 then
      fail(14, 'Δεν είναι συνδικαιούχος (ο κύριος δικαιούχος δεν βγαίνει)');
    end if;
  end;

  procedure set_status(p_account_id number, p_status varchar2) is
    a bk_account%rowtype := account_row(p_account_id);
  begin
    if p_status not in ('O', 'B') then
      fail(15, 'Κατάσταση: O (ανοιχτός) ή B (δεσμευμένος)· το κλείσιμο με close_account');
    end if;
    if a.status = 'C' then
      fail(12, 'Ο λογαριασμός ' || a.iban || ' είναι κλειστός');
    end if;
    update bk_account set status = p_status where id = p_account_id;
  end;

  procedure set_od_limit(p_account_id number, p_od_limit number) is
    a bk_account%rowtype := account_row(p_account_id);
    k varchar2(3);
  begin
    select kind into k from bk_product where id = a.product_id;
    if nvl(p_od_limit, -1) < 0 then
      fail(11, 'Το όριο υπερανάληψης: από 0 και πάνω');
    end if;
    if p_od_limit > 0 and k <> 'CUR' then
      fail(11, 'Υπερανάληψη μόνο σε λογαριασμό όψεως');
    end if;
    update bk_account set od_limit = p_od_limit where id = p_account_id;
  end;

  -- ---------------------------------------------------------------------------------------------
  -- an entry and its lines
  function new_entry(p_kind varchar2, p_value_date date, p_descr varchar2, p_reversal_of number default null,
                     p_channel varchar2 default 'BR') return number is
    d date := open_day;
    vd date := nvl(trunc(p_value_date), d);
    v number;
  begin
    if vd < d then
      fail(16, 'Η ημερομηνία αξίας ' || to_char(vd, 'DD/MM/YYYY') || ' είναι πριν από την εργάσιμη ημέρα '
               || to_char(d, 'DD/MM/YYYY') || ' (οι τόκοι των κλεισμένων ημερών δεν ξαναμετριούνται)');
    end if;
    -- (where: at a counter the branch of the session, at an ATM its branch; e-banking and the bank: none)
    insert into bk_entry (kind, book_date, value_date, descr, reversal_of, channel, branch_code)
    values (p_kind, d, vd, substr(p_descr, 1, 200), p_reversal_of, p_channel,
            case p_channel when 'ATM' then g_atm_branch when 'BR' then session_branch end) returning id into v;
    return v;
  end;

  -- a line in the currency of its account; of an account of the bank in p_currency (null: that of the last line
  -- of an account of the entry, else the base currency); and in the base currency, at the rate of its book date
  procedure line(p_entry_id number, p_account_id number, p_gl_code varchar2, p_debit number, p_credit number,
                 p_op varchar2 default null, p_currency varchar2 default null) is
    cur varchar2(3) := upper(p_currency);
    bd date;
    vd date;
    r number;
  begin
    select book_date, value_date into bd, vd from bk_entry where id = p_entry_id;
    if p_account_id is not null then
      cur := cur_of(p_account_id);
    elsif cur is null then
      select max(currency) keep (dense_rank last order by id) into cur
      from bk_line where entry_id = p_entry_id and account_id is not null;
    end if;
    cur := nvl(cur, base_currency);
    r := fx_rate(cur, bd);
    insert into bk_line (entry_id, account_id, gl_code, debit, credit, op, value_date, currency, base_debit, base_credit)
    values (p_entry_id, p_account_id, p_gl_code, nvl(p_debit, 0), nvl(p_credit, 0), p_op, vd, cur,
            round(nvl(p_debit, 0) / r, 2), round(nvl(p_credit, 0) / r, 2));
    if p_account_id is not null then
      update bk_account set balance = balance + nvl(p_credit, 0) - nvl(p_debit, 0) where id = p_account_id;
    end if;
  end;

  procedure amount_ok(p_amount number) is
  begin
    if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
      fail(17, 'Το ποσό: πάνω από 0, με ως δύο δεκαδικά');
    end if;
  end;

  -- an account money goes into: not closed (a blocked one takes money in)
  procedure into_ok(a bk_account%rowtype) is
  begin
    if a.status = 'C' then
      fail(12, 'Ο λογαριασμός ' || a.iban || ' είναι κλειστός');
    end if;
  end;

  -- an account money goes out of: open, within its balance and its overdraft limit (locked meanwhile: two
  -- withdrawals at once never both pass)
  procedure out_ok(p_account_id number, p_amount number) is
    a bk_account%rowtype;
  begin
    select * into a from bk_account where id = p_account_id for update;
    if a.status = 'C' then
      fail(12, 'Ο λογαριασμός ' || a.iban || ' είναι κλειστός');
    elsif a.status = 'B' then
      fail(18, 'Ο λογαριασμός ' || a.iban || ' είναι δεσμευμένος: δεν βγαίνουν χρήματα');
    end if;
    if a.balance + a.od_limit < p_amount then
      fail(19, 'Δεν φτάνει το υπόλοιπο του ' || a.iban || ': διαθέσιμα '
               || to_char(a.balance + a.od_limit, 'FM999G999G990D00', q'[NLS_NUMERIC_CHARACTERS=',.']')
               || case when a.currency = 'EUR' then ' €' else ' ' || a.currency end);
    end if;
  exception
    when no_data_found then
      fail(8, 'Δεν υπάρχει λογαριασμός ' || p_account_id);
  end;

  -- ---------------------------------------------------------------------------------------------
  -- the lock of the accounts of a movement, first of all (before its rules are read): two movements of one
  -- account wait for each other, one after the other, so each sees what the other left (its balance, its limits
  -- of the day and of the month). Two accounts: the lower id first, so two transfers in opposite directions
  -- wait for each other and never deadlock. Held till the commit (or the rollback) of the caller
  procedure lock_account(p_account_id number) is
    v number;
  begin
    select id into v from bk_account where id = p_account_id for update;
  exception
    when no_data_found then
      fail(8, 'Δεν υπάρχει λογαριασμός ' || p_account_id);
  end;

  procedure lock_accounts(p_a number, p_b number default null) is
  begin
    if p_b is null or p_a = p_b then
      lock_account(p_a);
    else
      lock_account(least(p_a, p_b));
      lock_account(greatest(p_a, p_b));
    end if;
  end;

  -- ---------------------------------------------------------------------------------------------
  -- the rules of the movements
  -- (in another currency than the euro: its code)
  function money_text(p number, p_cur varchar2 default null) return varchar2 is
  begin
    return to_char(p, 'FM999G999G990D00', q'[NLS_NUMERIC_CHARACTERS=',.']')
           || case when nvl(p_cur, 'EUR') = 'EUR' then ' €' else ' ' || p_cur end;
  end;

  function op_text(p_op varchar2) return varchar2 is
  begin
    return case p_op when 'DEP' then 'κατάθεση' when 'WDR' then 'ανάληψη'
                     when 'TRO' then 'μεταφορά προς άλλον λογαριασμό' when 'TRI' then 'μεταφορά από άλλον λογαριασμό'
                     when 'OUT' then 'μεταφορά σε άλλη τράπεζα' when 'INC' then 'μεταφορά από άλλη τράπεζα' else p_op end;
  end;

  function channel_text(p_channel varchar2) return varchar2 is
  begin
    return case p_channel when 'BR' then 'στο γκισέ' when 'WEB' then 'από το e-banking' when 'ATM' then 'από ΑΤΜ'
                          else 'από όλα τα κανάλια' end;
  end;

  procedure channel_ok(p_channel varchar2) is
  begin
    if p_channel is null or p_channel not in ('BR', 'WEB', 'ATM') then
      fail(31, 'Κανάλι: BR (γκισέ), WEB (e-banking) ή ATM');
    end if;
  end;

  -- a value of the rules and where it is from (o_scope: its channel; null: all of them)
  procedure resolve(p_account_id number, p_op varchar2, p_channel varchar2, p_attr varchar2,
                    o_value out number, o_scope out varchar2) is
    prod number;
  begin
    select product_id into prod from bk_account where id = p_account_id;
    select v, sc into o_value, o_scope from (
      select case p_attr when 'ALLOWED' then case r.allowed when 'Y' then 1 when 'N' then 0 end
                         when 'MIN_AMOUNT' then r.min_amount when 'MAX_AMOUNT' then r.max_amount
                         when 'DAY_AMOUNT' then r.day_amount when 'DAY_COUNT' then r.day_count
                         when 'MONTH_AMOUNT' then r.month_amount when 'MONTH_COUNT' then r.month_count
                         when 'FREE_MONTH' then r.free_month when 'FEE' then r.fee
                         when 'MIN_BALANCE' then r.min_balance end v,
             case when r.channel = '*' then null else r.channel end sc,
             case when r.account_id is not null then 0 when r.product_id is not null then 2 else 4 end
             + case when r.channel = '*' then 1 else 0 end lvl
      from bk_rule r
      where r.op = p_op and r.channel in (p_channel, '*')
        and (r.account_id = p_account_id or r.product_id = prod or (r.account_id is null and r.product_id is null)))
    where v is not null
    order by lvl fetch first 1 rows only;
  exception
    when no_data_found then
      o_value := null;
      o_scope := null;
  end;

  function rule_value(p_account_id number, p_op varchar2, p_channel varchar2, p_attr varchar2) return number is
    v number;
    sc varchar2(3);
  begin
    resolve(p_account_id, p_op, p_channel, p_attr, v, sc);
    return v;
  end;

  -- the movements of an op on an account in the business day (D) or its month (M), of a channel or of all
  -- of them (null), not reversed: their amount (A) or their count (C)
  function used(p_account_id number, p_op varchar2, p_scope varchar2, p_period varchar2, p_what varchar2) return number is
    d date := open_day;
    a number;
    n number;
  begin
    select nvl(sum(l.debit + l.credit), 0), count(*) into a, n
    from bk_line l join bk_entry e on e.id = l.entry_id
    where l.account_id = p_account_id and l.op = p_op
      and (p_scope is null or e.channel = p_scope)
      and e.kind <> 'REV'
      and e.book_date between case p_period when 'D' then d else trunc(d, 'MM') end and d
      and not exists (select 1 from bk_entry r where r.reversal_of = e.id);
    return case p_what when 'A' then a else n end;
  end;

  function rule_used(p_account_id number, p_op varchar2, p_channel varchar2, p_attr varchar2) return number is
    v number;
    sc varchar2(3);
  begin
    resolve(p_account_id, p_op, p_channel, p_attr, v, sc);
    return used(p_account_id, p_op, sc, case when p_attr like 'DAY%' then 'D' else 'M' end,
                case when p_attr like '%AMOUNT' then 'A' else 'C' end);
  end;

  -- a movement within the rules of its account; its fee back (0: none)
  function rules_ok(p_account_id number, p_op varchar2, p_channel varchar2, p_amount number) return number is
    v number;
    sc varchar2(3);
    u number;
    fee number;
    iban_ varchar2(27);
    where_ varchar2(40);
    cur varchar2(3);
  begin
    channel_ok(p_channel);
    select iban, currency into iban_, cur from bk_account where id = p_account_id;
    resolve(p_account_id, p_op, p_channel, 'ALLOWED', v, sc);
    if v = 0 then
      fail(26, 'Δεν επιτρέπεται ' || op_text(p_op) || ' ' || channel_text(p_channel) || ' στον ' || iban_);
    end if;
    resolve(p_account_id, p_op, p_channel, 'MIN_AMOUNT', v, sc);
    if p_amount < v then
      fail(27, 'Η ' || op_text(p_op) || ' ' || channel_text(p_channel) || ' είναι από ' || money_text(v, cur));
    end if;
    resolve(p_account_id, p_op, p_channel, 'MAX_AMOUNT', v, sc);
    if p_amount > v then
      fail(27, 'Η ' || op_text(p_op) || ' ' || channel_text(p_channel) || ' είναι ως ' || money_text(v, cur));
    end if;
    for k in (select column_value attr from table(sys.odcivarchar2list('DAY_AMOUNT', 'DAY_COUNT', 'MONTH_AMOUNT', 'MONTH_COUNT'))) loop
      resolve(p_account_id, p_op, p_channel, k.attr, v, sc);
      if v is not null then
        u := used(p_account_id, p_op, sc, substr(k.attr, 1, 1), case when k.attr like '%AMOUNT' then 'A' else 'C' end);
        where_ := channel_text(sc);
        if k.attr like '%AMOUNT' and u + p_amount > v then
          fail(case when k.attr like 'DAY%' then 28 else 29 end,
               'Ξεπερνά το ' || case when k.attr like 'DAY%' then 'ημερήσιο' else 'μηνιαίο' end || ' όριο: ' || op_text(p_op)
               || ' ' || where_ || ', έχουν γίνει ' || money_text(u, cur) || ', όριο ' || money_text(v, cur));
        elsif k.attr like '%COUNT' and u + 1 > v then
          fail(case when k.attr like 'DAY%' then 28 else 29 end,
               'Ξεπερνά το ' || case when k.attr like 'DAY%' then 'ημερήσιο' else 'μηνιαίο' end || ' όριο: ' || op_text(p_op)
               || ' ' || where_ || ', έχουν γίνει ' || u || ', όριο ' || v);
        end if;
      end if;
    end loop;
    -- the fee: after the free ones of the month (none given: every time)
    resolve(p_account_id, p_op, p_channel, 'FEE', fee, sc);
    if nvl(fee, 0) > 0 then
      resolve(p_account_id, p_op, p_channel, 'FREE_MONTH', v, sc);
      if v is not null and used(p_account_id, p_op, sc, 'M', 'C') < v then
        fee := 0;
      end if;
    end if;
    return nvl(fee, 0);
  end;

  -- what is left in an account after money out: not under its MIN_BALANCE (the overdraft does not count)
  procedure floor_ok(p_account_id number, p_op varchar2, p_channel varchar2, p_out number) is
    v number;
    sc varchar2(3);
    a bk_account%rowtype := account_row(p_account_id);
  begin
    resolve(p_account_id, p_op, p_channel, 'MIN_BALANCE', v, sc);
    if v is not null and a.balance - p_out < v then
      fail(30, 'Στον ' || a.iban || ' πρέπει να μένουν τουλάχιστον ' || money_text(v, a.currency) || ': διαθέσιμα για '
               || op_text(p_op) || ' ' || money_text(greatest(a.balance - v, 0), a.currency));
    end if;
  end;

  -- the fee of a movement, in its entry: from the account to FEE
  procedure charge(p_entry_id number, p_account_id number, p_fee number) is
  begin
    if p_fee > 0 then
      line(p_entry_id, p_account_id, null, p_fee, 0, 'FEE');
      line(p_entry_id, null, 'FEE', 0, p_fee);
    end if;
  end;

  -- ---------------------------------------------------------------------------------------------
  function deposit(p_account_id number, p_amount number, p_descr varchar2 default null,
                   p_value_date date default null, p_channel varchar2 default 'BR') return number is
    e number;
    fee number;
  begin
    amount_ok(p_amount);
    lock_accounts(p_account_id);
    into_ok(account_row(p_account_id));
    fee := rules_ok(p_account_id, 'DEP', p_channel, p_amount);
    e := new_entry('DEP', p_value_date, nvl(p_descr, 'Κατάθεση'), null, p_channel);
    line(e, null, 'CASH', p_amount, 0, null, cur_of(p_account_id));
    line(e, p_account_id, null, 0, p_amount, 'DEP');
    charge(e, p_account_id, fee);
    return e;
  end;

  function withdraw(p_account_id number, p_amount number, p_descr varchar2 default null,
                    p_value_date date default null, p_channel varchar2 default 'BR') return number is
    e number;
    fee number;
  begin
    amount_ok(p_amount);
    lock_accounts(p_account_id);
    fee := rules_ok(p_account_id, 'WDR', p_channel, p_amount);
    out_ok(p_account_id, p_amount + fee);
    floor_ok(p_account_id, 'WDR', p_channel, p_amount + fee);
    e := new_entry('WDR', p_value_date, nvl(p_descr, 'Ανάληψη'), null, p_channel);
    line(e, p_account_id, null, p_amount, 0, 'WDR');
    line(e, null, 'CASH', 0, p_amount);
    charge(e, p_account_id, fee);
    return e;
  end;

  function transfer(p_from_id number, p_to_id number, p_amount number, p_descr varchar2 default null,
                    p_value_date date default null, p_channel varchar2 default 'BR') return number is
    e number;
    fee number;
    fee_to number;
    ca varchar2(3);
    cb varchar2(3);
    amt_to number;
    mid_to number;
  begin
    amount_ok(p_amount);
    if p_from_id = p_to_id then
      fail(20, 'Μεταφορά στον ίδιο λογαριασμό');
    end if;
    lock_accounts(p_from_id, p_to_id);
    into_ok(account_row(p_to_id));
    -- two currencies: the amount of the other one as the customer gets it (less the margin of the bank)
    ca := cur_of(p_from_id);
    cb := cur_of(p_to_id);
    amt_to := case when ca = cb then p_amount else fx_convert(p_amount, ca, cb, null, 'Y') end;
    if amt_to <= 0 then
      fail(17, 'Το ποσό: πάνω από 0 και σε ' || cb);
    end if;
    fee := rules_ok(p_from_id, 'TRO', p_channel, p_amount);
    fee_to := rules_ok(p_to_id, 'TRI', p_channel, amt_to);
    out_ok(p_from_id, p_amount + fee);
    floor_ok(p_from_id, 'TRO', p_channel, p_amount + fee);
    e := new_entry('TRF', p_value_date, nvl(p_descr, 'Μεταφορά'), null, p_channel);
    line(e, p_from_id, null, p_amount, 0, 'TRO');
    if ca = cb then
      line(e, p_to_id, null, 0, p_amount, 'TRI');
    else
      -- each currency balanced through the position of the bank in it (FX_POS, at the mid rate); the margin its
      -- income (FX_INC)
      mid_to := fx_convert(p_amount, ca, cb);
      line(e, null, 'FX_POS', 0, p_amount, null, ca);
      line(e, null, 'FX_POS', mid_to, 0, null, cb);
      line(e, p_to_id, null, 0, amt_to, 'TRI');
      if mid_to > amt_to then
        line(e, null, 'FX_INC', 0, mid_to - amt_to, null, cb);
      elsif mid_to < amt_to then
        line(e, null, 'FX_INC', amt_to - mid_to, 0, null, cb);
      end if;
      update bk_entry set orig_amount = p_amount, orig_currency = ca, fx_rate = round(amt_to / p_amount, 8) where id = e;
    end if;
    charge(e, p_from_id, fee);
    charge(e, p_to_id, fee_to);
    return e;
  end;

  function transfer_out(p_from_id number, p_amount number, p_iban_to varchar2, p_descr varchar2 default null,
                        p_value_date date default null, p_channel varchar2 default 'BR') return number is
    e number;
    fee number;
  begin
    amount_ok(p_amount);
    if iban_ok(replace(upper(p_iban_to), ' ')) = 'N' then
      fail(21, 'Λάθος IBAN δικαιούχου: ' || p_iban_to);
    end if;
    lock_accounts(p_from_id);
    fee := rules_ok(p_from_id, 'OUT', p_channel, p_amount);
    out_ok(p_from_id, p_amount + fee);
    floor_ok(p_from_id, 'OUT', p_channel, p_amount + fee);
    e := new_entry('OUT', p_value_date, nvl(p_descr, 'Μεταφορά σε ' || replace(upper(p_iban_to), ' ')), null, p_channel);
    line(e, p_from_id, null, p_amount, 0, 'OUT');
    line(e, null, 'CLEAR', 0, p_amount);
    charge(e, p_from_id, fee);
    return e;
  end;

  function transfer_in(p_to_id number, p_amount number, p_iban_from varchar2, p_descr varchar2 default null,
                       p_value_date date default null, p_channel varchar2 default 'BR') return number is
    e number;
    fee number;
  begin
    amount_ok(p_amount);
    if iban_ok(replace(upper(p_iban_from), ' ')) = 'N' then
      fail(21, 'Λάθος IBAN αποστολέα: ' || p_iban_from);
    end if;
    lock_accounts(p_to_id);
    into_ok(account_row(p_to_id));
    fee := rules_ok(p_to_id, 'INC', p_channel, p_amount);
    e := new_entry('INC', p_value_date, nvl(p_descr, 'Μεταφορά από ' || replace(upper(p_iban_from), ' ')), null, p_channel);
    line(e, null, 'CLEAR', p_amount, 0, null, cur_of(p_to_id));
    line(e, p_to_id, null, 0, p_amount, 'INC');
    charge(e, p_to_id, fee);
    return e;
  end;

  -- ---------------------------------------------------------------------------------------------
  function set_rule(p_product_code varchar2, p_account_id number, p_op varchar2, p_channel varchar2,
                    p_allowed varchar2 default null, p_min_amount number default null, p_max_amount number default null,
                    p_day_amount number default null, p_day_count number default null,
                    p_month_amount number default null, p_month_count number default null,
                    p_free_month number default null, p_fee number default null,
                    p_min_balance number default null) return number is
    prod number;
    v number;
    ch varchar2(3) := nvl(p_channel, '*');
  begin
    if p_product_code is not null and p_account_id is not null then
      fail(32, 'Ο κανόνας είναι για ένα προϊόν ή για έναν λογαριασμό, όχι και για τα δύο');
    end if;
    if p_product_code is not null then
      begin
        select id into prod from bk_product where code = upper(p_product_code);
      exception
        when no_data_found then fail(10, 'Δεν υπάρχει προϊόν ' || p_product_code);
      end;
    end if;
    if p_account_id is not null then
      v := account_row(p_account_id).id;
    end if;
    if p_op is null or p_op not in ('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC') then
      fail(32, 'Κίνηση: DEP, WDR, TRO, TRI, OUT ή INC');
    end if;
    if ch not in ('*', 'BR', 'WEB', 'ATM') then
      fail(31, 'Κανάλι: * (όλα), BR (γκισέ), WEB (e-banking) ή ATM');
    end if;
    if p_allowed is not null and p_allowed not in ('Y', 'N') then
      fail(32, 'Επιτρέπεται: Y ή N');
    end if;
    if least(nvl(p_min_amount, 0), nvl(p_max_amount, 0), nvl(p_day_amount, 0), nvl(p_day_count, 0), nvl(p_month_amount, 0),
             nvl(p_month_count, 0), nvl(p_free_month, 0), nvl(p_fee, 0)) < 0 then
      fail(32, 'Τα ποσά και οι αριθμοί του κανόνα: από 0 και πάνω');
    end if;
    if p_min_amount > p_max_amount then
      fail(32, 'Το ελάχιστο ποσό είναι πάνω από το μέγιστο');
    end if;
    if p_day_count <> trunc(p_day_count) or p_month_count <> trunc(p_month_count) or p_free_month <> trunc(p_free_month) then
      fail(32, 'Ο αριθμός κινήσεων: ακέραιος');
    end if;
    select max(id) into v from bk_rule
    where (product_id = prod or (product_id is null and prod is null))
      and (account_id = p_account_id or (account_id is null and p_account_id is null))
      and op = p_op and channel = ch;
    if v is null then
      insert into bk_rule (product_id, account_id, op, channel) values (prod, p_account_id, p_op, ch) returning id into v;
    end if;
    update bk_rule set allowed = p_allowed, min_amount = p_min_amount, max_amount = p_max_amount,
           day_amount = p_day_amount, day_count = p_day_count, month_amount = p_month_amount,
           month_count = p_month_count, free_month = p_free_month, fee = p_fee, min_balance = p_min_balance
    where id = v;
    return v;
  end;

  procedure remove_rule(p_rule_id number) is
  begin
    delete from bk_rule where id = p_rule_id;
    if sql%rowcount = 0 then
      fail(32, 'Δεν υπάρχει κανόνας ' || p_rule_id);
    end if;
  end;

  function is_cc(p_account_id number) return boolean;

  function reverse(p_entry_id number, p_descr varchar2 default null) return number is
    o bk_entry%rowtype;
    e number;
    n number;
  begin
    begin
      select * into o from bk_entry where id = p_entry_id for update;     -- (a second reversal waits here)
    exception
      when no_data_found then fail(22, 'Δεν υπάρχει κίνηση ' || p_entry_id);
    end;
    if o.kind in ('REV', 'INT') then
      fail(22, 'Δεν αντιλογίζεται: ' || case o.kind when 'REV' then 'είναι αντιλογισμός' else 'τόκοι (κεφαλαιοποίηση)' end);
    end if;
    select count(*) into n from bk_entry where reversal_of = p_entry_id;
    if n > 0 then
      fail(23, 'Η κίνηση ' || p_entry_id || ' έχει ήδη αντιλογιστεί');
    end if;
    -- money back out of an account that took it: within its balance (as any withdrawal)
    for l in (select account_id, sum(credit) - sum(debit) took from bk_line
              where entry_id = p_entry_id and account_id is not null group by account_id order by account_id) loop
      if l.took > 0 and is_cc(l.account_id) then
        lock_account(l.account_id);                -- (a payment of a card back: owed again)
      elsif l.took > 0 then
        out_ok(l.account_id, l.took);
      else
        into_ok(account_row(l.account_id));
      end if;
    end loop;
    e := new_entry('REV', null, nvl(p_descr, 'Αντιλογισμός της κίνησης ' || p_entry_id), p_entry_id);
    for l in (select account_id, gl_code, debit, credit, op, currency from bk_line where entry_id = p_entry_id order by id) loop
      line(e, l.account_id, l.gl_code, l.credit, l.debit, l.op, l.currency);
    end loop;
    return e;
  end;

  -- ---------------------------------------------------------------------------------------------
  function value_balance(p_account_id number, p_day date) return number is
    v number;
  begin
    select nvl(sum(l.credit - l.debit), 0) into v
    from bk_line l join bk_entry e on e.id = l.entry_id
    where l.account_id = p_account_id and e.value_date <= p_day;
    return v;
  end;

  -- the days of a day in its day basis, and the days of its year
  procedure day_count(p_basis varchar2, p_day date, o_days out number, o_year out number) is
    dd number := to_number(to_char(p_day, 'DD'));
  begin
    if p_basis = '30360' then
      o_year := 360;
      if dd = 31 then
        o_days := 0;                                         -- (a month of 30 days)
      elsif to_char(p_day, 'MM') = '02' and p_day = last_day(p_day) then
        o_days := 30 - dd + 1;                               -- (February up to 30 days)
      else
        o_days := 1;
      end if;
    else
      o_days := 1;
      o_year := case p_basis when 'ACT360' then 360 else 365 end;
    end if;
  end;

  function int_descr(p_gross number, p_tax number, p_tax_rate number, p_day date) return varchar2 is
  begin
    return case when p_gross > 0 then 'Τόκοι ' || to_char(p_day, 'MM/YYYY') || case when p_tax > 0 then ' (φόρος '
                     || rtrim(rtrim(to_char(p_tax_rate, 'FM990D00', q'[NLS_NUMERIC_CHARACTERS=',.']'), '0'), ',') || '%)' end
                else 'Χρεωστικοί τόκοι υπερανάληψης ' || to_char(p_day, 'MM/YYYY') end;
  end;

  -- the interest of the open accounts p_lo .. p_hi of the products capitalized every p_caps (M, Q, Y: any of
  -- them) accrued up to p_day: their stretches after their ACCRUED_TO, in one statement (so it reads their
  -- balance and their lines at one moment), written; their ACCRUED and ACCRUED_TO with them
  procedure accrue_range(p_lo number, p_hi number, p_day date, p_caps varchar2) is
  begin
    delete from bk_accrual_new;
    insert into bk_accrual_new (account_id, day_from, day_to, balance, rate, days, year_days, interest)
    with acc as (
      select a.id, a.product_id, a.currency, a.balance, p.day_basis, p.od_rate, nvl(a.accrued_to, a.opened_on - 1) at0
      from bk_account a join bk_product p on p.id = a.product_id
      where a.id between p_lo and p_hi and a.status <> 'C' and a.opened_on <= p_day and p.kind not in ('CC', 'LN')
        and nvl(a.accrued_to, a.opened_on - 1) < p_day and instr(p_caps, p.cap_every) > 0),
    -- the changes of its balance by value date after ACCRUED_TO (the later ones too: its balance is now)
    ev as (
      select l.account_id id, l.value_date day, sum(l.credit - l.debit) amt
      from bk_line l join acc on acc.id = l.account_id
      where l.value_date > acc.at0
      group by l.account_id, l.value_date),
    -- where a stretch starts: the day after ACCRUED_TO, a value date, a new rate of its product
    pts as (
      select id, at0 + 1 b from acc
      union
      select id, day from ev where day <= p_day
      union
      select acc.id, r.valid_from from acc join bk_rate r on r.product_id = acc.product_id and r.currency = acc.currency
      where r.valid_from > acc.at0 + 1 and r.valid_from <= p_day),
    seg as (
      select id, b f, nvl(lead(b) over (partition by id order by b) - 1, p_day) t from pts),
    -- its balance by value date in a stretch: its balance now less what has a later value date
    sv as (
      select s.id, s.f, s.t, acc.product_id, acc.currency, acc.day_basis, acc.od_rate, acc.balance - nvl(sum(ev.amt), 0) vb
      from seg s join acc on acc.id = s.id left join ev on ev.id = s.id and ev.day > s.f
      group by s.id, s.f, s.t, acc.product_id, acc.currency, acc.day_basis, acc.od_rate, acc.balance),
    -- the rates: each tier from its VALID_FROM to the next one of it (rate_of)
    rt as (
      select product_id, currency, min_balance, rate, valid_from vf,
             lead(valid_from) over (partition by product_id, currency, min_balance order by valid_from) vn
      from bk_rate),
    sr as (
      select sv.*,
             case when sv.vb < 0 then sv.od_rate
                  else nvl((select max(rt.rate) keep (dense_rank last order by rt.min_balance) from rt
                            where rt.product_id = sv.product_id and rt.currency = sv.currency and rt.min_balance <= sv.vb and rt.vf <= sv.f
                              and (rt.vn is null or rt.vn > sv.f)), 0) end rate,
             case sv.day_basis when 'ACT365' then 365 else 360 end yd
      from sv),
    -- the days of each kind (30/360) in it
    x as (
      select sr.*, ct.c1 - cf.c1 n1, ct.c2 - cf.c2 n2, ct.c3 - cf.c3 n3
      from sr join bk_calendar ct on ct.day = sr.t join bk_calendar cf on cf.day = sr.f - 1)
    select id, f, t, vb, rate,
           case when day_basis = '30360' then n1 + 2 * n2 + 3 * n3 else t - f + 1 end,
           yd,
           case when day_basis = '30360'
                then n1 * round(vb * rate / 100 * 1 / yd, 6) + n2 * round(vb * rate / 100 * 2 / yd, 6)
                     + n3 * round(vb * rate / 100 * 3 / yd, 6)
                else (t - f + 1) * round(vb * rate / 100 * 1 / yd, 6) end
    from x;
    insert into bk_accrual (account_id, day_from, day_to, balance, rate, days, year_days, interest)
    select account_id, day_from, day_to, balance, rate, days, year_days, interest from bk_accrual_new;
    merge into bk_account a
    using (select account_id, sum(interest) i from bk_accrual_new group by account_id) s
    on (a.id = s.account_id)
    when matched then update set a.accrued = a.accrued + s.i, a.accrued_to = p_day;
  end;

  procedure accrue(p_account_id number, p_day date default null) is
    d date := nvl(trunc(p_day), open_day - 1);
    a bk_account%rowtype := account_row(p_account_id);
  begin
    if d >= open_day then
      fail(24, 'Οι τόκοι μετριούνται ως μια κλεισμένη ημέρα (ως ' || to_char(open_day - 1, 'DD/MM/YYYY') || ')');
    end if;
    lock_accounts(p_account_id);
    accrue_range(p_account_id, p_account_id, d, 'MQY');
  end;

  -- the interest accrued of the accounts p_lo .. p_hi of the products of p_caps capitalized on p_day: as
  -- capitalize, set-based (a statement for all their entries, one for all their lines, ...). The ids of their
  -- entries from the sequence of BK_ENTRY itself (its identity), to tie their lines to them
  procedure capitalize_range(p_lo number, p_hi number, p_day date, p_caps varchar2) is
    seq varchar2(128);
    b varchar2(3) := base_currency;
  begin
    select sequence_name into seq from user_tab_identity_cols where table_name = 'BK_ENTRY' and column_name = 'ID';
    delete from bk_capital_new;
    execute immediate
      'insert into bk_capital_new (account_id, gross, tax, tax_rate, entry_id)
       select id, gross, case when gross > 0 then round(gross * tax_rate / 100, 2) else 0 end, tax_rate, ' || seq || '.nextval
       from (select a.id, round(a.accrued, 2) gross, p.tax_rate
             from bk_account a join bk_product p on p.id = a.product_id
             where a.id between :lo and :hi and a.status <> ''C'' and p.kind not in (''CC'', ''LN'') and instr(:caps, p.cap_every) > 0
               and round(a.accrued, 2) <> 0)'
      using p_lo, p_hi, p_caps;
    -- (the words as int_descr: a function of the package is not called in SQL)
    insert into bk_entry (id, kind, book_date, value_date, channel, descr)
    select entry_id, 'INT', p_day, p_day, 'SYS',
           case when gross > 0 then 'Τόκοι ' || to_char(p_day, 'MM/YYYY') || case when tax > 0 then ' (φόρος '
                     || rtrim(rtrim(to_char(tax_rate, 'FM990D00', q'[NLS_NUMERIC_CHARACTERS=',.']'), '0'), ',') || '%)' end
                else 'Χρεωστικοί τόκοι υπερανάληψης ' || to_char(p_day, 'MM/YYYY') end
    from bk_capital_new;
    -- its lines, in the order of capitalize: INT_EXP, the account (gross), the account (tax), TAX; or the account
    -- and INT_INC
    -- (each in the currency of its account, and in the base currency at the rate of the day)
    insert into bk_line (entry_id, account_id, gl_code, debit, credit, value_date, currency, base_debit, base_credit)
    select entry_id, account_id, gl_code, debit, credit, p_day, cur,
           case when r is null then debit else round(debit / r, 2) end, case when r is null then credit else round(credit / r, 2) end
    from (select c.entry_id, k.n, a.currency cur,
                 case when a.currency <> b then (select max(f.mid) keep (dense_rank last order by f.day) from bk_fx_rate f
                                                 where f.currency = a.currency and f.day <= p_day) end r,
                 case when k.n in (2, 3, 5) then c.account_id end account_id,
                 case k.n when 1 then 'INT_EXP' when 4 then 'TAX' when 6 then 'INT_INC' end gl_code,
                 case k.n when 1 then c.gross when 3 then c.tax when 5 then -c.gross else 0 end debit,
                 case k.n when 2 then c.gross when 4 then c.tax when 6 then -c.gross else 0 end credit
          from bk_capital_new c
          join bk_account a on a.id = c.account_id
          join (select level n from dual connect by level <= 6) k
            on (c.gross > 0 and (k.n in (1, 2) or (k.n in (3, 4) and c.tax > 0))) or (c.gross < 0 and k.n in (5, 6))
          order by c.entry_id, k.n);
    insert into bk_capital (account_id, day, gross, tax, entry_id)
    select account_id, p_day, gross, tax, entry_id from bk_capital_new;
    -- (the rest of the rounding stays, for the next time)
    merge into bk_account a
    using bk_capital_new c on (a.id = c.account_id)
    when matched then update set a.accrued = a.accrued - c.gross, a.balance = a.balance + c.gross - c.tax;
  end;

  function capitalize(p_account_id number, p_day date) return number is
    a bk_account%rowtype;
    p bk_product%rowtype;
    gross number;
    tax number := 0;
    e number;
    descr_ varchar2(200);
  begin
    lock_accounts(p_account_id);
    -- its interest up to the last day closed first (p_day itself, if it is closed: a day before the business day)
    if least(trunc(p_day), open_day - 1) >= account_row(p_account_id).opened_on then
      accrue_range(p_account_id, p_account_id, least(trunc(p_day), open_day - 1), 'MQY');
    end if;
    select * into a from bk_account where id = p_account_id;
    select * into p from bk_product where id = a.product_id;
    gross := round(a.accrued, 2);
    if gross = 0 then
      return null;
    end if;
    if gross > 0 then
      tax := round(gross * p.tax_rate / 100, 2);
    end if;
    -- booked on the day, with its value date
    descr_ := int_descr(gross, tax, p.tax_rate, p_day);                 -- (not in SQL: PLS-00231)
    insert into bk_entry (kind, book_date, value_date, channel, descr)
    values ('INT', p_day, p_day, 'SYS', descr_)
    returning id into e;
    if gross > 0 then
      line(e, null, 'INT_EXP', gross, 0, null, a.currency);
      line(e, p_account_id, null, 0, gross);
      if tax > 0 then
        line(e, p_account_id, null, tax, 0);
        line(e, null, 'TAX', 0, tax);
      end if;
    else
      line(e, p_account_id, null, -gross, 0);
      line(e, null, 'INT_INC', 0, -gross);
    end if;
    insert into bk_capital (account_id, day, gross, tax, entry_id) values (p_account_id, p_day, gross, tax, e);
    -- (the rest of the rounding stays, for the next time)
    update bk_account set accrued = accrued - gross where id = p_account_id;
    return e;
  end;

  -- the balance of an account by value date for the interest of a day: without the interest capitalized that
  -- day (booked after the interest of its day was counted)
  function interest_by_day(p_account_id number, p_day_from date, p_day_to date) return number is
    a bk_account%rowtype := account_row(p_account_id);
    basis varchar2(6);
    s number := 0;
    vb number;
    days_ number;
    year_ number;
    d date := trunc(p_day_from);
  begin
    select day_basis into basis from bk_product where id = a.product_id;
    while d <= trunc(p_day_to) loop
      select nvl(sum(l.credit - l.debit), 0) into vb
      from bk_line l join bk_entry e on e.id = l.entry_id
      where l.account_id = p_account_id and l.value_date <= d and not (e.kind = 'INT' and e.book_date = d);
      day_count(basis, d, days_, year_);
      s := s + round(vb * rate_of(a.product_id, d, vb, a.currency) / 100 * days_ / year_, 6);
      d := d + 1;
    end loop;
    return s;
  end;

  -- the end of the business day: at the end of a period, its accounts accrued and capitalized (by 200.000); the
  -- credit cards (cc_close_day)
  procedure close_day(p_day date default null) is
    d date := open_day;
    caps varchar2(3);
    lo number;
    hi number;
  begin
    if p_day is not null and trunc(p_day) <> d then
      fail(24, 'Κλείνει μόνο η εργάσιμη ημέρα ' || to_char(d, 'DD/MM/YYYY') || ', όχι η ' || to_char(p_day, 'DD/MM/YYYY'));
    end if;
    -- the cards and the loans first: what they book today (an installment collected from an account) is in the
    -- balance of the day of that account, when its interest is counted below
    cc_close_day(d);
    ln_close_day(d);
    if d = last_day(d) then
      caps := 'M' || case when to_char(d, 'MM') in ('03', '06', '09', '12') then 'Q' end
                  || case when to_char(d, 'MM') = '12' then 'Y' end;
      select min(id), max(id) into lo, hi from bk_account;
      while lo <= hi loop
        accrue_range(lo, lo + 199999, d, caps);
        capitalize_range(lo, lo + 199999, d, caps);
        lo := lo + 200000;
      end loop;
    end if;
    insert into bk_day (day) values (d);
  end;

  procedure close_account(p_account_id number) is
    a bk_account%rowtype := account_row(p_account_id);
    d date := open_day;
    e number;
  begin
    if a.status = 'C' then
      fail(12, 'Ο λογαριασμός ' || a.iban || ' είναι ήδη κλειστός');
    end if;
    -- the interest of the days closed: capitalized now (booked on the business day)
    e := capitalize(p_account_id, d);
    select * into a from bk_account where id = p_account_id;
    if a.balance <> 0 then
      fail(25, 'Ο λογαριασμός ' || a.iban || ' έχει υπόλοιπο '
               || money_text(a.balance, a.currency) || ': ανάληψη ή μεταφορά του πρώτα');
    end if;
    select count(*) into e from bk_entry x join bk_line l on l.entry_id = x.id
    where l.account_id = p_account_id and x.value_date > d;
    if e > 0 then
      fail(25, 'Ο λογαριασμός ' || a.iban || ' έχει κινήσεις με μελλοντική ημερομηνία αξίας');
    end if;
    select nvl(max(held), 0) into e from bk_ccard where account_id = p_account_id;
    if e > 0 then
      fail(25, 'Η κάρτα του ' || a.iban || ' έχει εγκρίσεις σε εκκρεμότητα: ' || money_text(e));
    end if;
    update bk_account set status = 'C', closed_on = d where id = p_account_id;
  end;

  -- ---------------------------------------------------------------------------------------------
  -- the cards
  function luhn_sum(p_number varchar2) return number is
    s number := 0;
    d number;
  begin
    for i in 1 .. length(p_number) loop
      d := to_number(substr(p_number, length(p_number) - i + 1, 1));
      if mod(i, 2) = 0 then
        d := d * 2;
        if d > 9 then
          d := d - 9;
        end if;
      end if;
      s := s + d;
    end loop;
    return s;
  end;

  function luhn_ok(p_number varchar2) return varchar2 is
  begin
    if p_number is null or not regexp_like(p_number, '^[0-9]{12,19}$') then
      return 'N';
    end if;
    return case when mod(luhn_sum(p_number), 10) = 0 then 'Y' else 'N' end;
  end;

  function new_card(p_account_id number, p_customer_id number default null) return number is
    a bk_account%rowtype := account_row(p_account_id);
    c number := p_customer_id;
    n number;
    v number;
    body_ varchar2(16);
  begin
    if a.status = 'C' then
      fail(12, 'Ο λογαριασμός ' || a.iban || ' είναι κλειστός');
    end if;
    if c is null then
      select customer_id into c from bk_holder where account_id = p_account_id and role = 'P';
    end if;
    select count(*) into n from bk_holder where account_id = p_account_id and customer_id = c;
    if n = 0 then
      fail(36, 'Ο πελάτης ' || c || ' δεν είναι δικαιούχος του ' || a.iban);
    end if;
    insert into bk_card (pan, account_id, customer_id, expires)
    values ('T' || substr(rawtohex(sys_guid()), 1, 15), p_account_id, c, last_day(add_months(open_day, 48)))
    returning id into v;
    body_ := '4' || lpad(nvl(setting('BANK_CODE'), '999'), 3, '0') || lpad(v, 11, '0');
    body_ := body_ || to_char(mod(10 - mod(luhn_sum(body_ || '0'), 10), 10));      -- (not in SQL: PLS-00231)
    update bk_card set pan = body_ where id = v;
    return v;
  end;

  function card_row(p_card_id number) return bk_card%rowtype is
    k bk_card%rowtype;
  begin
    select * into k from bk_card where id = p_card_id;
    return k;
  exception
    when no_data_found then
      fail(33, 'Δεν υπάρχει η κάρτα');
  end;

  procedure set_card_status(p_card_id number, p_status varchar2) is
    k bk_card%rowtype := card_row(p_card_id);
  begin
    if p_status is null or p_status not in ('A', 'B', 'C') then
      fail(34, 'Κατάσταση κάρτας: A ενεργή, B δεσμευμένη, C ακυρωμένη');
    end if;
    if k.status = 'C' then
      fail(34, 'Η κάρτα είναι ακυρωμένη: μια νέα κάρτα');
    end if;
    update bk_card set status = p_status where id = p_card_id;
  end;

  function card_account(p_card_id number) return number is
    k bk_card%rowtype := card_row(p_card_id);
    a bk_account%rowtype;
  begin
    if k.status = 'B' then
      fail(34, 'Η κάρτα είναι δεσμευμένη: επικοινωνήστε με την τράπεζα');
    elsif k.status = 'C' then
      fail(34, 'Η κάρτα είναι ακυρωμένη');
    end if;
    if k.expires < open_day then
      fail(35, 'Η κάρτα έληξε στις ' || to_char(k.expires, 'MM/YY'));
    end if;
    a := account_row(k.account_id);
    if a.status = 'C' then
      fail(12, 'Ο λογαριασμός της κάρτας είναι κλειστός');
    end if;
    return k.account_id;
  end;

  -- ---------------------------------------------------------------------------------------------
  -- the ATMs
  function atm_row(p_atm_code varchar2, p_lock boolean default false) return bk_atm%rowtype is
    m bk_atm%rowtype;
  begin
    if p_lock then
      select * into m from bk_atm where code = upper(p_atm_code) for update;
    else
      select * into m from bk_atm where code = upper(p_atm_code);
    end if;
    if m.active <> 'Y' then
      fail(37, 'Το ATM ' || m.code || ' δεν λειτουργεί');
    end if;
    return m;
  exception
    when no_data_found then
      fail(37, 'Δεν υπάρχει ATM ' || p_atm_code);
  end;

  -- the notes the ATMs give, the highest first (the setting ATM_NOTES)
  function atm_notes return sys.odcinumberlist is
    s varchar2(400) := nvl(setting('ATM_NOTES'), '20,50');       -- (not in SQL: PLS-00231)
    l sys.odcinumberlist;
  begin
    select to_number(trim(regexp_substr(s, '[^,]+', 1, level))) bulk collect into l
    from dual connect by level <= regexp_count(s, ',') + 1
    order by 1 desc;
    return l;
  end;

  function notes_text(p sys.odcinumberlist) return varchar2 is
    v varchar2(200);
  begin
    for i in 1 .. p.count loop
      v := v || case when i = p.count and i > 1 then ' και ' when i > 1 then ', ' end || p(i);
    end loop;
    return v || ' €';
  end;

  procedure set_atm_notes(p_notes varchar2, p_max_notes number default null) is
    l sys.odcinumberlist;
    s varchar2(400) := regexp_replace(p_notes, '\s', '');
    n number;
    v varchar2(400);
  begin
    if s is null or not regexp_like(s, '^[0-9]+(,[0-9]+)*$') then
      fail(40, 'Τα χαρτονομίσματα των ATM: τιμές σε €, με κόμμα (π.χ. 20,50)');
    end if;
    select to_number(regexp_substr(s, '[^,]+', 1, level)) bulk collect into l
    from dual connect by level <= regexp_count(s, ',') + 1;
    for i in 1 .. l.count loop
      if l(i) not in (5, 10, 20, 50, 100, 200, 500) then
        fail(40, 'Δεν υπάρχει χαρτονόμισμα των ' || l(i) || ' €: 5, 10, 20, 50, 100, 200, 500');
      end if;
      for j in 1 .. i - 1 loop
        if l(j) = l(i) then
          fail(40, 'Το χαρτονόμισμα των ' || l(i) || ' € δύο φορές');
        end if;
      end loop;
    end loop;
    if p_max_notes is not null and (p_max_notes < 1 or p_max_notes > 200 or p_max_notes <> trunc(p_max_notes)) then
      fail(40, 'Τα περισσότερα χαρτονομίσματα μιας ανάληψης: από 1 ως 200');
    end if;
    -- a note no more: its cassettes empty first
    for c in (select m.code, n.note, n.pieces from bk_atm_note n join bk_atm m on m.id = n.atm_id
              where n.pieces > 0 and n.note not in (select column_value from table(l)) order by m.code) loop
      fail(40, 'Πρώτα αδειάζουν οι κασέτες των ' || c.note || ' € (' || c.code || ': ' || c.pieces || ' χαρτονομίσματα)');
    end loop;
    delete from bk_atm_note where note not in (select column_value from table(l));
    insert into bk_atm_note (atm_id, note, pieces)
    select m.id, x.column_value, 0 from bk_atm m cross join table(l) x
    where not exists (select 1 from bk_atm_note n where n.atm_id = m.id and n.note = x.column_value);
    select listagg(column_value, ',') within group (order by column_value) into v from table(l);
    merge into bk_setting t using (select 'ATM_NOTES' name, v value from dual) x on (t.name = x.name)
    when matched then update set t.value = x.value when not matched then insert (name, value) values (x.name, x.value);
    if p_max_notes is not null then
      merge into bk_setting t using (select 'ATM_MAX_NOTES' name, to_char(p_max_notes) value from dual) x on (t.name = x.name)
      when matched then update set t.value = x.value when not matched then insert (name, value) values (x.name, x.value);
    end if;
    n := l.count;
  end;

  procedure atm_fill(p_atm_code varchar2, p_note number, p_pieces number) is
    m bk_atm%rowtype;
    have number;
  begin
    begin
      select * into m from bk_atm where code = upper(p_atm_code) for update;
    exception
      when no_data_found then fail(37, 'Δεν υπάρχει ATM ' || p_atm_code);
    end;
    begin
      select pieces into have from bk_atm_note where atm_id = m.id and note = p_note;
    exception
      when no_data_found then fail(40, 'Το ATM ' || m.code || ' δεν έχει κασέτα για χαρτονομίσματα των ' || p_note || ' €');
    end;
    if p_pieces is null or p_pieces = 0 or p_pieces <> trunc(p_pieces) then
      fail(38, 'Χαρτονομίσματα: ένας ακέραιος αριθμός (αρνητικός: αφαίρεση)');
    end if;
    if have + p_pieces < 0 then
      fail(39, 'Η κασέτα των ' || p_note || ' € του ' || m.code || ' έχει ' || have || ' χαρτονομίσματα');
    end if;
    update bk_atm_note set pieces = pieces + p_pieces where atm_id = m.id and note = p_note;
    update bk_atm set cash = cash + p_note * p_pieces where id = m.id;
  end;

  -- the ways to give p_rem with the notes p_d(p_i ..) (p_av of each), at most p_max notes in all
  procedure combos(p_d sys.odcinumberlist, p_av sys.odcinumberlist, p_i pls_integer, p_rem number, p_spec varchar2,
                   p_n number, p_max number, o_spec in out nocopy sys.odcivarchar2list, o_n in out nocopy sys.odcinumberlist,
                   o_steps in out nocopy number) is
  begin
    o_steps := o_steps + 1;
    if o_spec.count >= 200 or o_steps > 20000 then
      return;
    end if;
    if p_rem = 0 then
      o_spec.extend;
      o_spec(o_spec.count) := p_spec;
      o_n.extend;
      o_n(o_n.count) := p_n;
      return;
    end if;
    if p_i > p_d.count then
      return;
    end if;
    for k in reverse 0 .. least(p_av(p_i), trunc(p_rem / p_d(p_i)), p_max - p_n) loop
      combos(p_d, p_av, p_i + 1, p_rem - k * p_d(p_i),
             case when k > 0 then p_spec || case when p_spec is not null then ',' end || p_d(p_i) || ':' || k else p_spec end,
             p_n + k, p_max, o_spec, o_n, o_steps);
    end loop;
  end;

  function atm_options(p_atm_code varchar2, p_amount number) return varchar2 is
    m bk_atm%rowtype := atm_row(p_atm_code);
    d sys.odcinumberlist := atm_notes;
    av sys.odcinumberlist := sys.odcinumberlist();
    sp sys.odcivarchar2list := sys.odcivarchar2list();
    nn sys.odcinumberlist := sys.odcinumberlist();
    steps number := 0;
    mx number := to_number(nvl(setting('ATM_MAX_NOTES'), '40'));
    idx sys.odcinumberlist := sys.odcinumberlist();
    t number;
    v varchar2(1000);
    pick number;
  begin
    if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount) then
      return null;
    end if;
    av.extend(d.count);
    for i in 1 .. d.count loop
      select nvl(max(pieces), 0) into av(i) from bk_atm_note where atm_id = m.id and note = d(i);
    end loop;
    combos(d, av, 1, p_amount, null, 0, mx, sp, nn, steps);
    if sp.count = 0 then
      return null;
    end if;
    -- the fewest notes first (as they were found: the higher notes first, for the same number)
    idx.extend(sp.count);
    for i in 1 .. sp.count loop
      idx(i) := i;
    end loop;
    for i in 2 .. idx.count loop
      for j in reverse 1 .. i - 1 loop
        exit when nn(idx(j)) <= nn(idx(j + 1));
        t := idx(j); idx(j) := idx(j + 1); idx(j + 1) := t;
      end loop;
    end loop;
    -- up to 4: the fewest notes, the most, and between them evenly
    for j in 0 .. least(idx.count, 4) - 1 loop
      pick := case when idx.count <= 4 then j + 1 else round(j * (idx.count - 1) / 3) + 1 end;
      v := v || case when j > 0 then ';' end || sp(idx(pick));
    end loop;
    return v;
  end;

  function atm_withdraw(p_atm_code varchar2, p_card_id number, p_amount number, p_notes varchar2 default null) return number is
    m bk_atm%rowtype := atm_row(p_atm_code, true);
    a number := card_account(p_card_id);
    d sys.odcinumberlist := atm_notes;
    spec varchar2(400) := regexp_replace(p_notes, '\s', '');
    mx number := to_number(nvl(setting('ATM_MAX_NOTES'), '40'));
    note_ number;
    pcs number;
    have number;
    total number := 0;
    cnt number := 0;
    seen varchar2(400) := ',';
    e number;
  begin
    amount_ok(p_amount);
    if cur_of(a) <> base_currency then
      fail(54, 'Το ATM δίνει μόνο ' || base_currency || ': ο λογαριασμός της κάρτας είναι σε ' || cur_of(a));
    end if;
    if m.cash < p_amount then
      fail(39, 'Το ATM δεν έχει αρκετά μετρητά: ως ' || money_text(m.cash));
    end if;
    if spec is null then
      spec := regexp_substr(atm_options(p_atm_code, p_amount), '[^;]+', 1, 1);
      if spec is null then
        fail(38, 'Το ATM δεν μπορεί να δώσει ' || money_text(p_amount) || ' με χαρτονομίσματα των ' || notes_text(d));
      end if;
    end if;
    if not regexp_like(spec, '^[0-9]+:[0-9]+(,[0-9]+:[0-9]+)*$') then
      fail(38, 'Τα χαρτονομίσματα: χαρτονόμισμα:πλήθος, με κόμμα (π.χ. 50:4,20:5)');
    end if;
    for i in 1 .. regexp_count(spec, ',') + 1 loop
      note_ := to_number(regexp_substr(regexp_substr(spec, '[^,]+', 1, i), '[0-9]+', 1, 1));
      pcs := to_number(regexp_substr(regexp_substr(spec, '[^,]+', 1, i), '[0-9]+', 1, 2));
      if instr(seen, ',' || note_ || ',') > 0 then
        fail(38, 'Το χαρτονόμισμα των ' || note_ || ' € δύο φορές');
      end if;
      seen := seen || note_ || ',';
      select count(*) into have from table(d) where column_value = note_;
      if have = 0 then
        fail(38, 'Το ATM δίνει χαρτονομίσματα των ' || notes_text(d) || ', όχι των ' || note_ || ' €');
      end if;
      select nvl(max(pieces), 0) into have from bk_atm_note where atm_id = m.id and note = note_;
      if pcs > have then
        fail(39, 'Το ATM έχει ' || have || ' χαρτονομίσματα των ' || note_ || ' €');
      end if;
      total := total + note_ * pcs;
      cnt := cnt + pcs;
    end loop;
    if total <> p_amount then
      fail(38, 'Τα χαρτονομίσματα κάνουν ' || money_text(total) || ', όχι ' || money_text(p_amount));
    end if;
    if cnt > mx then
      fail(38, 'Ως ' || mx || ' χαρτονομίσματα σε μία ανάληψη');
    end if;
    g_atm_branch := m.branch_code;
    begin
      e := withdraw(a, p_amount, 'Ανάληψη ATM ' || m.code || ' ' || m.name, null, 'ATM');
    exception
      when others then
        g_atm_branch := null;
        raise;
    end;
    g_atm_branch := null;
    for i in 1 .. regexp_count(spec, ',') + 1 loop
      note_ := to_number(regexp_substr(regexp_substr(spec, '[^,]+', 1, i), '[0-9]+', 1, 1));
      pcs := to_number(regexp_substr(regexp_substr(spec, '[^,]+', 1, i), '[0-9]+', 1, 2));
      update bk_atm_note set pieces = pieces - pcs where atm_id = m.id and note = note_;
    end loop;
    update bk_atm set cash = cash - p_amount where id = m.id;
    return e;
  end;

  function atm_deposit(p_atm_code varchar2, p_card_id number, p_amount number) return number is
    m bk_atm%rowtype := atm_row(p_atm_code, true);
    a number := card_account(p_card_id);
    e number;
  begin
    amount_ok(p_amount);
    if cur_of(a) <> base_currency then
      fail(54, 'Το ATM δέχεται μόνο ' || base_currency || ': ο λογαριασμός της κάρτας είναι σε ' || cur_of(a));
    end if;
    if mod(p_amount, 5) <> 0 then
      fail(38, 'Το ATM δέχεται χαρτονομίσματα: ένα ποσό σε πεντάδες');
    end if;
    g_atm_branch := m.branch_code;
    begin
      e := deposit(a, p_amount, 'Κατάθεση ATM ' || m.code || ' ' || m.name, null, 'ATM');
    exception
      when others then
        g_atm_branch := null;
        raise;
    end;
    g_atm_branch := null;
    update bk_atm set deposits = deposits + p_amount where id = m.id;       -- (its bin: not given out again)
    return e;
  end;

  function atm_transfer(p_atm_code varchar2, p_card_id number, p_to_iban varchar2, p_amount number) return number is
    m bk_atm%rowtype := atm_row(p_atm_code);
    a number := card_account(p_card_id);
    t number;
    iban_ varchar2(40) := replace(upper(p_to_iban), ' ');
  begin
    begin
      select id into t from bk_account where iban = iban_;
    exception
      when no_data_found then
        fail(21, 'Δεν υπάρχει λογαριασμός ' || p_to_iban || ' στην τράπεζα');
    end;
    g_atm_branch := m.branch_code;
    begin
      t := transfer(a, t, p_amount, 'Μεταφορά από ATM ' || m.code, null, 'ATM');
    exception
      when others then
        g_atm_branch := null;
        raise;
    end;
    g_atm_branch := null;
    return t;
  end;

  -- ---------------------------------------------------------------------------------------------
  -- the credit cards
  function is_cc(p_account_id number) return boolean is
    n number;
  begin
    select count(*) into n from bk_ccard where account_id = p_account_id;
    return n > 0;
  end;

  -- the card account (locked first, when p_lock: what may be spent read after the one before it)
  function cc_row(p_account_id number, p_lock boolean default false) return bk_ccard%rowtype is
    k bk_ccard%rowtype;
  begin
    if p_lock then
      lock_account(p_account_id);
    end if;
    select * into k from bk_ccard where account_id = p_account_id;
    return k;
  exception
    when no_data_found then
      fail(46, 'Ο λογαριασμός ' || p_account_id || ' δεν είναι πιστωτικής κάρτας');
  end;

  procedure limit_ok(p_limit number) is
  begin
    if p_limit is null or p_limit < 0 or p_limit <> round(p_limit, 2) then
      fail(51, 'Το όριο της κάρτας: από 0 και πάνω, με ως δύο δεκαδικά');
    end if;
  end;

  function set_cc_product(p_code varchar2, p_name varchar2, p_rate number, p_min_pct number default 3,
                          p_min_amount number default 20, p_due_days number default 25, p_late_fee number default 0) return number is
    id_ number;
    k varchar2(3);
  begin
    if p_code is null or p_name is null or nvl(p_rate, -1) < 0 or nvl(p_min_pct, -1) not between 0 and 100
       or nvl(p_min_amount, -1) < 0 or nvl(p_due_days, 0) not between 1 and 27 or nvl(p_late_fee, -1) < 0 then
      fail(50, 'Όροι κάρτας: κωδικός, όνομα, επιτόκιο από 0, ελάχιστη καταβολή 0 - 100 % και ποσό από 0, '
               || 'προθεσμία 1 - 27 ημέρες, τέλος καθυστέρησης από 0');
    end if;
    begin
      select id, kind into id_, k from bk_product where code = upper(p_code);
      if k <> 'CC' then
        fail(46, 'Το προϊόν ' || upper(p_code) || ' δεν είναι πιστωτικής κάρτας');
      end if;
      update bk_product set name = p_name where id = id_;
    exception
      when no_data_found then
        insert into bk_product (code, name, kind, tax_rate, od_rate) values (upper(p_code), p_name, 'CC', 0, 0)
        returning id into id_;
    end;
    merge into bk_cc_product c
    using (select id_ product_id from dual) v on (c.product_id = v.product_id)
    when matched then update set rate = p_rate, min_pct = p_min_pct, min_amount = p_min_amount, due_days = p_due_days,
                                 late_fee = p_late_fee
    when not matched then insert (product_id, rate, min_pct, min_amount, due_days, late_fee)
                          values (id_, p_rate, p_min_pct, p_min_amount, p_due_days, p_late_fee);
    return id_;
  end;

  function cc_open(p_product_code varchar2, p_customer_id number, p_limit number, p_stmt_day number default null) return number is
    n number;
    sd number := nvl(p_stmt_day, least(to_number(to_char(open_day, 'DD')), 28));
    a number;
  begin
    select count(*) into n from bk_product p join bk_cc_product c on c.product_id = p.id
    where p.code = upper(p_product_code) and p.kind = 'CC';
    if n = 0 then
      fail(46, 'Το προϊόν ' || p_product_code || ' δεν είναι πιστωτικής κάρτας');
    end if;
    limit_ok(p_limit);
    if sd is null or sd not between 1 and 28 or sd <> trunc(sd) then
      fail(50, 'Η ημέρα της κίνησης (statement) της κάρτας: 1 - 28 του μήνα');
    end if;
    a := open_account(p_product_code, p_customer_id, 0);
    insert into bk_ccard (account_id, credit_limit, stmt_day) values (a, p_limit, sd);
    return a;
  end;

  procedure cc_set_limit(p_account_id number, p_limit number) is
    k bk_ccard%rowtype;
  begin
    limit_ok(p_limit);
    k := cc_row(p_account_id, true);
    if account_row(p_account_id).status = 'C' then
      fail(12, 'Ο λογαριασμός της κάρτας είναι κλειστός');
    end if;
    -- (lower than what is owed: allowed; nothing more may be spent till it is paid)
    update bk_ccard set credit_limit = p_limit where account_id = p_account_id;
  end;

  function cc_available(p_account_id number) return number is
    k bk_ccard%rowtype := cc_row(p_account_id);
  begin
    return k.credit_limit + account_row(p_account_id).balance - k.held;
  end;

  function cc_authorize(p_card_id number, p_amount number, p_merchant varchar2 default null,
                        p_currency varchar2 default null) return number is
    acc number;
    k bk_ccard%rowtype;
    a bk_account%rowtype;
    v number;
    cur varchar2(3) := upper(p_currency);
    amt number := p_amount;
    conv number;
    fxf number := 0;
    pct number;
  begin
    amount_ok(p_amount);
    acc := card_account(p_card_id);
    k := cc_row(acc, true);                    -- (another authorization of the card waits here)
    a := account_row(acc);
    if a.status = 'B' then
      fail(18, 'Ο λογαριασμός της κάρτας είναι δεσμευμένος');
    end if;
    -- a purchase in another currency: in that of the card at the mid rate, and the fee of conversion
    if cur is not null and cur <> a.currency then
      currency_ok(cur);
      conv := fx_convert(p_amount, cur, a.currency);
      if conv <= 0 then
        fail(17, 'Το ποσό: πάνω από 0 και σε ' || a.currency);
      end if;
      select fx_fee_pct into pct from bk_cc_product where product_id = a.product_id;
      fxf := round(conv * pct / 100, 2);
      amt := conv + fxf;
    else
      cur := null;
    end if;
    v := k.credit_limit + a.balance - k.held;
    if amt > v then
      fail(47, 'Δεν φτάνει το όριο της κάρτας: διαθέσιμα ' || money_text(greatest(v, 0), a.currency));
    end if;
    insert into bk_cc_auth (account_id, card_id, amount, merchant, day, orig_amount, orig_currency, fx_fee)
    values (acc, p_card_id, amt, substr(p_merchant, 1, 100), open_day, case when cur is not null then p_amount end, cur, fxf)
    returning id into v;
    update bk_ccard set held = held + amt where account_id = acc;
    return v;
  end;

  -- an authorization held (its account locked first)
  function auth_row(p_auth_id number) return bk_cc_auth%rowtype is
    h bk_cc_auth%rowtype;
    acc number;
  begin
    begin
      select account_id into acc from bk_cc_auth where id = p_auth_id;
    exception
      when no_data_found then fail(48, 'Δεν υπάρχει έγκριση ' || p_auth_id);
    end;
    lock_account(acc);
    select * into h from bk_cc_auth where id = p_auth_id;
    if h.status <> 'H' then
      fail(48, 'Η έγκριση ' || p_auth_id || ' δεν εκκρεμεί: ' || case h.status when 'P' then 'χρεώθηκε' else 'αποδεσμεύτηκε' end);
    end if;
    return h;
  end;

  function cc_capture(p_auth_id number, p_amount number default null) return number is
    h bk_cc_auth%rowtype := auth_row(p_auth_id);
    amt number := nvl(p_amount, h.amount);
    e number;
    fee_ number;
    orig_ number;
  begin
    amount_ok(amt);
    if amt > h.amount then
      fail(49, 'Η χρέωση είναι ως το ποσό της έγκρισης, ' || money_text(h.amount));
    end if;
    -- (abroad: its part of the fee of conversion, a fee of its own; the amount and the currency it was in)
    fee_ := case when h.orig_currency is not null then round(h.fx_fee * amt / h.amount, 2) else 0 end;
    e := new_entry('PUR', null, 'Αγορά' || case when h.merchant is not null then ': ' || h.merchant end, null, 'SYS');
    line(e, h.account_id, null, amt - fee_, 0);
    line(e, null, 'CC_MERCH', 0, amt - fee_);
    if fee_ > 0 then
      line(e, h.account_id, null, fee_, 0, 'FEE');
      line(e, null, 'FEE', 0, fee_);
    end if;
    if h.orig_currency is not null then
      orig_ := round(h.orig_amount * amt / h.amount, 2);
      update bk_entry set orig_amount = orig_, orig_currency = h.orig_currency, fx_rate = round((amt - fee_) / orig_, 8)
      where id = e;
    end if;
    update bk_cc_auth set status = 'P', amount = amt, fx_fee = fee_, orig_amount = nvl2(h.orig_currency, orig_, null),
                          entry_id = e where id = p_auth_id;
    update bk_ccard set held = held - h.amount where account_id = h.account_id;
    return e;
  end;

  procedure cc_release(p_auth_id number) is
    h bk_cc_auth%rowtype := auth_row(p_auth_id);
  begin
    update bk_cc_auth set status = 'R' where id = p_auth_id;
    update bk_ccard set held = held - h.amount where account_id = h.account_id;
  end;

  function cc_purchase(p_card_id number, p_amount number, p_merchant varchar2 default null,
                       p_currency varchar2 default null) return number is
    h number;
  begin
    h := cc_authorize(p_card_id, p_amount, p_merchant, p_currency);
    return cc_capture(h);
  end;

  function cc_pay(p_account_id number, p_from_account_id number, p_amount number, p_channel varchar2 default 'BR') return number is
    k bk_ccard%rowtype := cc_row(p_account_id);
  begin
    return transfer(p_from_account_id, p_account_id, p_amount, 'Πληρωμή κάρτας', null, p_channel);
  end;

  -- the credits of a card account booked in p_from .. p_to (payments, refunds)
  function cc_paid(p_account_id number, p_from date, p_to date) return number is
    v number;
  begin
    select nvl(sum(l.credit), 0) into v
    from bk_line l join bk_entry e on e.id = l.entry_id
    where l.account_id = p_account_id and e.book_date between p_from and p_to;
    return v;
  end;

  -- the statement of a card on p_day: its interest first (out of the grace), then its sums
  procedure cc_cycle(p_account_id number, p_day date) is
    k bk_ccard%rowtype := cc_row(p_account_id, true);
    a bk_account%rowtype := account_row(p_account_id);
    t bk_cc_product%rowtype;
    s bk_cc_statement%rowtype;
    f date := nvl(k.last_stmt, a.opened_on - 1) + 1;
    grace boolean := true;
    i number := 0;
    e number;
    v number;
  begin
    select * into t from bk_cc_product where product_id = a.product_id;
    if k.last_stmt is not null then
      select * into s from bk_cc_statement where account_id = p_account_id and stmt_date = k.last_stmt;
      v := cc_paid(p_account_id, s.stmt_date + 1, s.due_date);
      grace := s.closing <= 0 or v >= s.closing;
    end if;
    if not grace then
      -- what was owed at the end of each day of the period (by value date), at the rate of the card
      select nvl(round(sum(greatest(-(select nvl(sum(l.credit - l.debit), 0) from bk_line l
                                      where l.account_id = p_account_id and l.value_date <= c.day), 0)) * t.rate / 100 / 365, 2), 0)
      into i from bk_calendar c where c.day between f and p_day;
      if i > 0 then
        e := new_entry('INT', null, 'Τόκοι κάρτας ' || to_char(p_day, 'MM/YYYY'), null, 'SYS');
        line(e, p_account_id, null, i, 0);
        line(e, null, 'CC_INT', 0, i);
      end if;
    end if;
    s.opening := nvl(s.closing, 0);
    s.account_id := p_account_id;
    s.stmt_date := p_day;
    s.period_from := f;
    select nvl(sum(case when e.kind = 'INT' then l.debit end), 0),
           nvl(sum(case when e.kind = 'FEE' or l.op = 'FEE' then l.debit end), 0),
           nvl(sum(case when e.kind <> 'INT' and e.kind <> 'FEE' and nvl(l.op, '-') <> 'FEE' then l.debit end), 0),
           nvl(sum(l.credit), 0)
    into s.interest, s.fees, s.purchases, s.payments
    from bk_line l join bk_entry e on e.id = l.entry_id
    where l.account_id = p_account_id and e.book_date between f and p_day;
    s.closing := -account_row(p_account_id).balance;
    s.min_due := case when s.closing <= 0 then 0
                      else least(s.closing, greatest(t.min_amount, round(s.closing * t.min_pct / 100, 2))) end;
    s.due_date := p_day + t.due_days;
    s.late_fee := null;
    insert into bk_cc_statement values s;
    update bk_ccard set last_stmt = p_day where account_id = p_account_id;
  end;

  procedure cc_close_day(p_day date) is
    hold_days number := nvl(to_number(setting('CC_HOLD_DAYS')), 7);
    v number;
    fee number;
    e number;
    dd number := to_number(to_char(p_day, 'DD'));
  begin
    -- (held its day and the CC_HOLD_DAYS - 1 after it: released at the close of the last of them)
    for h in (select id from bk_cc_auth where status = 'H' and day <= p_day - hold_days + 1 order by account_id, id) loop
      cc_release(h.id);
    end loop;
    -- the statements due today: their minimum paid?
    for s in (select s.account_id, s.stmt_date, s.min_due, c.late_fee
              from bk_cc_statement s, bk_account a, bk_cc_product c
              where s.due_date = p_day and s.late_fee is null and a.id = s.account_id and c.product_id = a.product_id
              order by s.account_id) loop
      lock_account(s.account_id);
      v := cc_paid(s.account_id, s.stmt_date + 1, p_day);
      fee := case when s.min_due > 0 and v < s.min_due then s.late_fee else 0 end;
      if fee > 0 then
        e := new_entry('FEE', null, 'Καθυστέρηση πληρωμής κάρτας: ελάχιστη καταβολή ' || money_text(s.min_due)
                                    || ' ως ' || to_char(p_day, 'DD/MM/YYYY'), null, 'SYS');
        line(e, s.account_id, null, fee, 0, 'FEE');
        line(e, null, 'FEE', 0, fee);
      end if;
      update bk_cc_statement set late_fee = fee where account_id = s.account_id and stmt_date = s.stmt_date;
    end loop;
    for k in (select c.account_id from bk_ccard c, bk_account a
              where c.stmt_day = dd and a.id = c.account_id and a.status <> 'C' and a.opened_on <= p_day
                and (c.last_stmt is null or c.last_stmt < p_day)
              order by c.account_id) loop
      cc_cycle(k.account_id, p_day);
    end loop;
  end;

  -- ---------------------------------------------------------------------------------------------
  -- the loans
  procedure set_ln_index(p_code varchar2, p_day date, p_rate number) is
  begin
    if p_code is null or p_day is null or p_rate is null or p_rate not between -5 and 50 then
      fail(59, 'Ο δείκτης: κωδικός, ημέρα, επιτόκιο -5 ως 50 %');
    end if;
    merge into bk_ln_index x
    using (select upper(p_code) code, trunc(p_day) day from dual) v on (x.code = v.code and x.day = v.day)
    when matched then update set rate = p_rate
    when not matched then insert (code, day, rate) values (v.code, v.day, p_rate);
  end;

  function ln_index(p_code varchar2, p_day date default null) return number is
    v number;
    d date := trunc(nvl(p_day, open_day));
  begin
    select max(rate) keep (dense_rank last order by day) into v from bk_ln_index where code = upper(p_code) and day <= d;
    if v is null then
      fail(59, 'Δεν υπάρχει τιμή του δείκτη ' || p_code || ' για τις ' || to_char(d, 'DD/MM/YYYY'));
    end if;
    return v;
  end;

  function set_ln_product(p_code varchar2, p_name varchar2, p_rate_type varchar2, p_rate number,
                          p_index_code varchar2 default null, p_reset_months number default 3, p_late_add number default 2.5,
                          p_late_fee number default 0, p_grace_days number default 5, p_prepay_pct number default 0,
                          p_max_months number default 360) return number is
    id_ number;
    k varchar2(3);
    v number;
  begin
    if p_code is null or p_name is null or nvl(p_rate_type, '-') not in ('F', 'V') or nvl(p_rate, -1) < 0
       or (p_rate_type = 'V' and p_index_code is null) or nvl(p_reset_months, 0) not between 1 and 12
       or nvl(p_late_add, -1) not between 0 and 10 or nvl(p_late_fee, -1) < 0 or nvl(p_grace_days, -1) not between 0 and 30
       or nvl(p_prepay_pct, -1) not between 0 and 10 or nvl(p_max_months, 0) not between 1 and 480 then
      fail(56, 'Όροι δανείου: κωδικός, όνομα, επιτόκιο F σταθερό ή V κυμαινόμενο (με δείκτη: το επιτόκιο το περιθώριο), '
               || 'αναπροσαρμογή 1 - 12 μήνες, υπερημερία 0 - 10 %, προθεσμία 0 - 30 ημέρες, προμήθεια πρόωρης 0 - 10 %, '
               || 'ως 480 μήνες');
    end if;
    if p_rate_type = 'V' then
      v := ln_index(p_index_code);                 -- (a rate of it there)
    end if;
    begin
      select id, kind into id_, k from bk_product where code = upper(p_code);
      if k <> 'LN' then
        fail(55, 'Το προϊόν ' || upper(p_code) || ' δεν είναι δανείου');
      end if;
      update bk_product set name = p_name where id = id_;
    exception
      when no_data_found then
        insert into bk_product (code, name, kind, day_basis, tax_rate, od_rate) values (upper(p_code), p_name, 'LN', '30360', 0, 0)
        returning id into id_;
    end;
    merge into bk_ln_product x
    using (select id_ product_id from dual) v on (x.product_id = v.product_id)
    when matched then update set rate_type = p_rate_type, rate = p_rate, index_code = upper(p_index_code),
                                 reset_months = p_reset_months, late_add = p_late_add, late_fee = p_late_fee,
                                 grace_days = p_grace_days, prepay_pct = p_prepay_pct, max_months = p_max_months
    when not matched then insert (product_id, rate_type, rate, index_code, reset_months, late_add, late_fee, grace_days,
                                  prepay_pct, max_months)
                          values (id_, p_rate_type, p_rate, upper(p_index_code), p_reset_months, p_late_add, p_late_fee,
                                  p_grace_days, p_prepay_pct, p_max_months);
    return id_;
  end;

  function loan_row(p_account_id number) return bk_loan%rowtype is
    l bk_loan%rowtype;
  begin
    select * into l from bk_loan where account_id = p_account_id;
    return l;
  exception
    when no_data_found then
      fail(55, 'Ο λογαριασμός ' || p_account_id || ' δεν είναι δανείου');
  end;

  function ln_terms(p_account_id number) return bk_ln_product%rowtype is
    t bk_ln_product%rowtype;
  begin
    select x.* into t from bk_ln_product x join bk_account a on a.product_id = x.product_id where a.id = p_account_id;
    return t;
  end;

  -- the installment of an annuity: p_balance in p_count months at p_rate % a year
  function annuity(p_balance number, p_rate number, p_count number) return number is
    r number := p_rate / 1200;
  begin
    if r = 0 then
      return round(p_balance / p_count, 2);
    end if;
    return round(p_balance * r / (1 - power(1 + r, -p_count)), 2);
  end;

  -- the installments of a loan from n p_n0 on, the first due p_due0, of p_balance at p_rate: p_count of them (an
  -- annuity), or (p_payment) of that installment, as many as it takes; the last one what is left
  procedure ln_schedule(p_account_id number, p_n0 number, p_due0 date, p_balance number, p_rate number,
                        p_count number, p_payment number default null) is
    r number := p_rate / 1200;
    pay number := p_payment;
    cnt number := p_count;
    bal number := p_balance;
    i_ number;
    p_ number;
  begin
    if pay is null then
      pay := annuity(p_balance, p_rate, cnt);
    elsif r = 0 then
      cnt := ceil(p_balance / pay);
    elsif p_balance * r >= pay then
      fail(58, 'Η δόση δεν φτάνει ούτε για τους τόκους');
    else
      cnt := ceil(-ln(1 - p_balance * r / pay) / ln(1 + r) - 0.0000001);
    end if;
    for k in 1 .. cnt loop
      i_ := round(bal * r, 2);
      p_ := case when k = cnt then bal else least(pay - i_, bal) end;
      bal := bal - p_;
      insert into bk_ln_schedule (account_id, n, due_date, rate, principal, interest, payment, balance)
      values (p_account_id, p_n0 + k - 1, add_months(p_due0, k - 1), p_rate, p_, i_, p_ + i_, bal);
      exit when bal = 0;
    end loop;
  end;

  -- the principal left of a loan: after its last installment that fell due (or paid before), else all of it
  function ln_left(p_account_id number) return number is
    v number;
  begin
    select max(balance) keep (dense_rank last order by n) into v from bk_ln_schedule
    where account_id = p_account_id and status <> 'D';
    return nvl(v, loan_row(p_account_id).principal);
  end;

  function ln_open(p_product_code varchar2, p_customer_id number, p_amount number, p_months number,
                   p_pay_account_id number, p_pay_day number default null) return number is
    t bk_ln_product%rowtype;
    p bk_product%rowtype;
    b bk_account%rowtype;
    a number;
    e number;
    n number;
    rate_ number;
    pd number := nvl(p_pay_day, least(to_number(to_char(open_day, 'DD')), 28));
    first_ date;
  begin
    begin
      select * into p from bk_product where code = upper(p_product_code) and kind = 'LN';
      select * into t from bk_ln_product where product_id = p.id;
    exception
      when no_data_found then fail(55, 'Το προϊόν ' || p_product_code || ' δεν είναι δανείου');
    end;
    amount_ok(p_amount);
    if nvl(p_months, 0) not between 1 and t.max_months or p_months <> trunc(p_months) then
      fail(56, 'Η διάρκεια του δανείου: 1 ως ' || t.max_months || ' μήνες');
    end if;
    if pd not between 1 and 28 or pd <> trunc(pd) then
      fail(56, 'Η ημέρα της δόσης: 1 - 28 του μήνα');
    end if;
    -- the account it is paid to and from: of the customer, open, not of a card or of a loan
    b := account_row(p_pay_account_id);
    select count(*) into n from bk_holder h join bk_product x on x.id = b.product_id
    where h.account_id = b.id and h.customer_id = p_customer_id and x.kind not in ('CC', 'LN');
    if n = 0 or b.status <> 'O' then
      fail(57, 'Ο λογαριασμός της δόσης: ανοιχτός λογαριασμός του πελάτη (όχι κάρτας ή δανείου)');
    end if;
    rate_ := case t.rate_type when 'V' then greatest(ln_index(t.index_code) + t.rate, 0) else t.rate end;
    a := open_account(p.code, p_customer_id, 0, null, b.currency);
    first_ := trunc(add_months(open_day, 1), 'MM') + pd - 1;
    insert into bk_loan (account_id, pay_account_id, principal, months, start_date, pay_day, rate, next_reset)
    values (a, b.id, p_amount, p_months, open_day, pd, rate_,
            -- (variable: again at the last installment of each period of it: of 3 months, at the 3rd, the 6th, ...)
            case when t.rate_type = 'V' then add_months(first_, t.reset_months - 1) end);
    ln_schedule(a, 1, first_, p_amount, rate_, p_months);
    -- paid to its account
    lock_accounts(a, b.id);
    e := new_entry('TRF', null, 'Εκταμίευση δανείου ' || account_row(a).iban, null, 'SYS');
    line(e, a, null, p_amount, 0);
    line(e, b.id, null, 0, p_amount, 'TRI');
    return a;
  end;

  -- an entry of a loan: its interest (INT, to LN_INT) or a fee (FEE, to FEE), debited to it
  procedure ln_charge(p_account_id number, p_kind varchar2, p_amount number, p_descr varchar2) is
    e number;
  begin
    if p_amount > 0 then
      e := new_entry(p_kind, null, p_descr, null, 'SYS');
      line(e, p_account_id, null, p_amount, 0, case when p_kind = 'FEE' then 'FEE' end);
      line(e, null, case when p_kind = 'FEE' then 'FEE' else 'LN_INT' end, 0, p_amount);
    end if;
  end;

  -- what is due of an installment, collected from the account of the loan: as much as it has
  procedure ln_collect(p_account_id number, p_n number) is
    l bk_loan%rowtype := loan_row(p_account_id);
    s bk_ln_schedule%rowtype;
    b bk_account%rowtype;
    x number;
    e number;
  begin
    lock_accounts(p_account_id, l.pay_account_id);
    select * into s from bk_ln_schedule where account_id = p_account_id and n = p_n;
    -- (late: its late interest accrued booked first)
    if s.status = 'L' then
      x := round(s.late_int, 2) - s.late_booked;
      if x > 0 then
        ln_charge(p_account_id, 'INT', x, 'Τόκοι υπερημερίας δόσης ' || p_n);
        update bk_ln_schedule set late_booked = late_booked + x where account_id = p_account_id and n = p_n;
        s.late_booked := s.late_booked + x;
      end if;
    end if;
    b := account_row(l.pay_account_id);
    x := least(s.payment + s.late_fee + s.late_booked - s.paid,
               case when b.status = 'O' then greatest(b.balance + b.od_limit, 0) else 0 end);
    if x > 0 then
      e := new_entry('TRF', null, 'Δόση ' || p_n || ' δανείου ' || account_row(p_account_id).iban, null, 'SYS');
      line(e, l.pay_account_id, null, x, 0, 'TRO');
      line(e, p_account_id, null, 0, x, 'TRI');
      update bk_ln_schedule set paid = paid + x,
             status = case when paid + x >= payment + late_fee + late_booked then 'P' else status end,
             paid_on = case when paid + x >= payment + late_fee + late_booked then open_day end
      where account_id = p_account_id and n = p_n;
    end if;
  end;

  -- a loan all paid (nothing to come, nothing due): closed
  procedure ln_done(p_account_id number) is
    n number;
  begin
    select count(*) into n from bk_ln_schedule where account_id = p_account_id and status <> 'P';
    if n = 0 and account_row(p_account_id).balance = 0 then
      update bk_loan set status = 'C' where account_id = p_account_id;
      close_account(p_account_id);
    end if;
  end;

  procedure ln_close_day(p_day date) is
    t bk_ln_product%rowtype;
    l bk_loan%rowtype;
    r number;
    cnt number;
    due0 date;
    x number;
  begin
    -- the installments due today: their interest; a variable rate again (the installments after it again)
    for s in (select account_id, n, due_date, interest, balance from bk_ln_schedule
              where status = 'D' and due_date <= p_day order by account_id, n) loop
      lock_account(s.account_id);
      ln_charge(s.account_id, 'INT', s.interest, 'Τόκοι δόσης ' || s.n);
      update bk_ln_schedule set status = 'O' where account_id = s.account_id and n = s.n;
      l := loan_row(s.account_id);
      t := ln_terms(s.account_id);
      if t.rate_type = 'V' and l.next_reset <= s.due_date then
        r := greatest(ln_index(t.index_code, p_day) + t.rate, 0);
        select count(*), min(due_date) into cnt, due0 from bk_ln_schedule where account_id = s.account_id and status = 'D';
        if cnt > 0 and r <> l.rate then
          delete from bk_ln_schedule where account_id = s.account_id and status = 'D';
          ln_schedule(s.account_id, s.n + 1, due0, s.balance, r, cnt);
        end if;
        update bk_loan set rate = r, next_reset = add_months(next_reset, t.reset_months) where account_id = s.account_id;
      end if;
    end loop;
    -- what is due: collected; late after its days of grace (the fee)
    for s in (select account_id, n from bk_ln_schedule where status in ('O', 'L') order by account_id, n) loop
      ln_collect(s.account_id, s.n);
    end loop;
    for s in (select s.account_id, s.n, x.late_fee from bk_ln_schedule s, bk_account a, bk_ln_product x
              where s.status = 'O' and s.due_date + x.grace_days <= p_day and a.id = s.account_id
                and x.product_id = a.product_id order by s.account_id, s.n) loop
      lock_account(s.account_id);
      ln_charge(s.account_id, 'FEE', s.late_fee, 'Καθυστέρηση δόσης ' || s.n);
      update bk_ln_schedule set status = 'L', late_fee = late_fee + s.late_fee where account_id = s.account_id and n = s.n;
    end loop;
    -- the late interest of the day on what is late (the rate of the loan and LATE_ADD); booked at the end of a month
    for s in (select s.account_id, s.n, s.payment + s.late_fee + s.late_booked - s.paid owed, l.rate + x.late_add r
              from bk_ln_schedule s, bk_loan l, bk_account a, bk_ln_product x
              where s.status = 'L' and l.account_id = s.account_id and a.id = s.account_id and x.product_id = a.product_id) loop
      update bk_ln_schedule set late_int = late_int + round(s.owed * s.r / 36000, 6) where account_id = s.account_id and n = s.n;
    end loop;
    if p_day = last_day(p_day) then
      for s in (select account_id, n, round(late_int, 2) - late_booked x from bk_ln_schedule
                where status = 'L' and round(late_int, 2) > late_booked order by account_id, n) loop
        lock_account(s.account_id);
        ln_charge(s.account_id, 'INT', s.x, 'Τόκοι υπερημερίας δόσης ' || s.n);
        update bk_ln_schedule set late_booked = late_booked + s.x where account_id = s.account_id and n = s.n;
      end loop;
    end if;
    for k in (select l.account_id from bk_loan l where l.status = 'A'
              and not exists (select 1 from bk_ln_schedule s where s.account_id = l.account_id and s.status <> 'P')
              order by l.account_id) loop
      ln_done(k.account_id);
    end loop;
  end;

  -- the days of interest of a prepayment: since the last installment due (or the start)
  function ln_days(p_account_id number) return number is
    d date;
  begin
    select max(due_date) into d from bk_ln_schedule where account_id = p_account_id and status <> 'D';
    return greatest(open_day - nvl(d, loan_row(p_account_id).start_date), 0);
  end;

  function ln_rate(p_product_code varchar2) return number is
    t bk_ln_product%rowtype;
  begin
    select x.* into t from bk_ln_product x join bk_product p on p.id = x.product_id where p.code = upper(p_product_code);
    return case t.rate_type when 'V' then greatest(ln_index(t.index_code) + t.rate, 0) else t.rate end;
  exception
    when no_data_found then
      fail(55, 'Το προϊόν ' || p_product_code || ' δεν είναι δανείου');
  end;

  function ln_quote(p_product_code varchar2, p_amount number, p_months number) return number is
  begin
    amount_ok(p_amount);
    if nvl(p_months, 0) < 1 or p_months <> trunc(p_months) then
      fail(56, 'Η διάρκεια του δανείου: από 1 μήνα');
    end if;
    return annuity(p_amount, ln_rate(p_product_code), p_months);
  end;

  function ln_payoff(p_account_id number) return number is
    l bk_loan%rowtype := loan_row(p_account_id);
    t bk_ln_product%rowtype := ln_terms(p_account_id);
    b number := ln_left(p_account_id);
    due_ number;
  begin
    if l.status = 'C' then
      return 0;
    end if;
    select nvl(sum(payment + late_fee + round(late_int, 2) - paid), 0) into due_
    from bk_ln_schedule where account_id = p_account_id and status in ('O', 'L');
    return b + round(b * l.rate / 36000 * ln_days(p_account_id), 2) + round(b * t.prepay_pct / 100, 2) + due_;
  end;

  function ln_prepay(p_account_id number, p_amount number, p_mode varchar2 default 'T') return number is
    l bk_loan%rowtype := loan_row(p_account_id);
    t bk_ln_product%rowtype := ln_terms(p_account_id);
    b number;
    a number;
    int_ number;
    fee number;
    n number;
    cnt number;
    due0 date;
    pay number;
    nn number;
    e number;
  begin
    if l.status = 'C' then
      fail(55, 'Το δάνειο έχει εξοφληθεί');
    end if;
    if nvl(p_mode, '-') not in ('T', 'P') then
      fail(58, 'Πρόωρη εξόφληση: T (ίδια δόση, λιγότερες) ή P (ίδιοι μήνες, μικρότερη δόση)');
    end if;
    amount_ok(p_amount);
    lock_accounts(p_account_id, l.pay_account_id);
    select count(*) into n from bk_ln_schedule where account_id = p_account_id and status in ('O', 'L');
    if n > 0 then
      fail(58, 'Πρώτα οι δόσεις που οφείλονται (' || n || ')');
    end if;
    b := ln_left(p_account_id);
    a := least(p_amount, b);
    int_ := round(a * l.rate / 36000 * ln_days(p_account_id), 2);
    fee := round(a * t.prepay_pct / 100, 2);
    out_ok(l.pay_account_id, a + int_ + fee);
    select nvl(max(n), 0) + 1 into nn from bk_ln_schedule where account_id = p_account_id and status <> 'D';
    select count(*), min(due_date), max(payment) keep (dense_rank first order by n)
    into cnt, due0, pay from bk_ln_schedule where account_id = p_account_id and status = 'D';
    delete from bk_ln_schedule where account_id = p_account_id and status = 'D';
    -- the prepayment: an installment of its own, paid (its fee in it), then the rest of the schedule again
    insert into bk_ln_schedule (account_id, n, due_date, rate, principal, interest, payment, balance, status, paid, paid_on, late_fee)
    values (p_account_id, nn, open_day, l.rate, a, int_, a + int_, b - a, 'P', a + int_ + fee, open_day, fee);
    ln_charge(p_account_id, 'INT', int_, 'Τόκοι πρόωρης εξόφλησης');
    ln_charge(p_account_id, 'FEE', fee, 'Προμήθεια πρόωρης εξόφλησης');
    e := new_entry('TRF', null, 'Πρόωρη εξόφληση δανείου ' || account_row(p_account_id).iban, null, 'SYS');
    line(e, l.pay_account_id, null, a + int_ + fee, 0, 'TRO');
    line(e, p_account_id, null, 0, a + int_ + fee, 'TRI');
    if b - a > 0 then
      if p_mode = 'T' then
        ln_schedule(p_account_id, nn + 1, due0, b - a, l.rate, null, pay);
      else
        ln_schedule(p_account_id, nn + 1, due0, b - a, l.rate, cnt);
      end if;
    else
      ln_done(p_account_id);
    end if;
    return e;
  end;

end bk_core;
/

-- the limits of every open account, for each movement and channel: allowed (1/0), the values of its rules (the
-- most particular one of each) and what is used of each limit now (its day, its month); no rule: null
create or replace view bk_limits as
select a.id account_id, a.iban, cast(o.column_value as varchar2(3)) op, cast(c.column_value as varchar2(3)) channel,
       nvl(bk_core.rule_value(a.id, o.column_value, c.column_value, 'ALLOWED'), 1) allowed,
       bk_core.rule_value(a.id, o.column_value, c.column_value, 'MIN_AMOUNT') min_amount,
       bk_core.rule_value(a.id, o.column_value, c.column_value, 'MAX_AMOUNT') max_amount,
       bk_core.rule_value(a.id, o.column_value, c.column_value, 'DAY_AMOUNT') day_amount,
       bk_core.rule_used(a.id, o.column_value, c.column_value, 'DAY_AMOUNT') day_amount_used,
       bk_core.rule_value(a.id, o.column_value, c.column_value, 'DAY_COUNT') day_count,
       bk_core.rule_used(a.id, o.column_value, c.column_value, 'DAY_COUNT') day_count_used,
       bk_core.rule_value(a.id, o.column_value, c.column_value, 'MONTH_AMOUNT') month_amount,
       bk_core.rule_used(a.id, o.column_value, c.column_value, 'MONTH_AMOUNT') month_amount_used,
       bk_core.rule_value(a.id, o.column_value, c.column_value, 'MONTH_COUNT') month_count,
       bk_core.rule_used(a.id, o.column_value, c.column_value, 'MONTH_COUNT') month_count_used,
       bk_core.rule_value(a.id, o.column_value, c.column_value, 'FREE_MONTH') free_month,
       bk_core.rule_used(a.id, o.column_value, c.column_value, 'FREE_MONTH') free_month_used,
       bk_core.rule_value(a.id, o.column_value, c.column_value, 'FEE') fee,
       bk_core.rule_value(a.id, o.column_value, c.column_value, 'MIN_BALANCE') min_balance
from bk_account a
cross join table(sys.odcivarchar2list('DEP', 'WDR', 'TRO', 'TRI', 'OUT', 'INC')) o
cross join table(sys.odcivarchar2list('BR', 'WEB', 'ATM')) c
where a.status <> 'C';
