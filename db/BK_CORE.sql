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
-- again). close_day: the interest of every open account for the day (its balance by value date, the rate of
-- its tier, its day basis), and at the end of its period the interest capitalized with its tax.

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

  -- the products and their rates (% a year, from a day on, by tier)
  procedure set_rate(p_product_id number, p_valid_from date, p_min_balance number, p_rate number);
  function rate_of(p_product_id number, p_day date, p_balance number) return number;

  -- the accounts: opened on the business day for a customer (its primary holder), joint holders, closed
  -- (its balance 0: its interest capitalized first), blocked (nothing out) or open again
  function open_account(p_product_code varchar2, p_customer_id number, p_od_limit number default 0,
                        p_name varchar2 default null) return number;
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

  -- the end of the business day: the interest of every open account for it, the capitalization at the end
  -- of each period (and of an account closed), then the day closed. p_day: the business day (a check)
  procedure close_day(p_day date default null);
  -- the interest accrued capitalized now (close_account does it): its entry, or null when nothing
  function capitalize(p_account_id number, p_day date) return number;

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

end bk_core;
/

create or replace package body bk_core as

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

  function new_iban(p_account_id number) return varchar2 is
    bban varchar2(23) := lpad(nvl(setting('BANK_CODE'), '999'), 3, '0') || lpad(nvl(setting('BRANCH_CODE'), '0001'), 4, '0')
                         || lpad(p_account_id, 16, '0');
    chk number;
  begin
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
  procedure set_rate(p_product_id number, p_valid_from date, p_min_balance number, p_rate number) is
  begin
    if p_rate is null or p_rate < 0 or p_rate > 100 then
      fail(7, 'Το επιτόκιο: από 0 ως 100 %');
    end if;
    if nvl(p_min_balance, 0) < 0 then
      fail(7, 'Το κλιμάκιο: από 0 και πάνω');
    end if;
    merge into bk_rate r
    using (select p_product_id product_id, trunc(p_valid_from) valid_from, nvl(p_min_balance, 0) min_balance from dual) v
    on (r.product_id = v.product_id and r.valid_from = v.valid_from and r.min_balance = v.min_balance)
    when matched then update set r.rate = p_rate
    when not matched then insert (product_id, valid_from, min_balance, rate) values (v.product_id, v.valid_from, v.min_balance, p_rate);
  end;

  function rate_of(p_product_id number, p_day date, p_balance number) return number is
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
    where r.product_id = p_product_id and r.min_balance <= p_balance
      and r.valid_from = (select max(x.valid_from) from bk_rate x
                          where x.product_id = r.product_id and x.min_balance = r.min_balance and x.valid_from <= p_day);
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
                        p_name varchar2 default null) return number is
    p bk_product%rowtype;
    v number;
  begin
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
    insert into bk_account (iban, product_id, name, opened_on, od_limit)
    values ('GR' || lpad('0', 25, '0'), p.id, p_name, open_day, nvl(p_od_limit, 0))
    returning id into v;
    update bk_account set iban = new_iban(v) where id = v;
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
    insert into bk_entry (kind, book_date, value_date, descr, reversal_of, channel)
    values (p_kind, d, vd, substr(p_descr, 1, 200), p_reversal_of, p_channel) returning id into v;
    return v;
  end;

  procedure line(p_entry_id number, p_account_id number, p_gl_code varchar2, p_debit number, p_credit number,
                 p_op varchar2 default null) is
  begin
    insert into bk_line (entry_id, account_id, gl_code, debit, credit, op)
    values (p_entry_id, p_account_id, p_gl_code, nvl(p_debit, 0), nvl(p_credit, 0), p_op);
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
               || to_char(a.balance + a.od_limit, 'FM999G999G990D00', q'[NLS_NUMERIC_CHARACTERS=',.']') || ' €');
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
  function money_text(p number) return varchar2 is
  begin
    return to_char(p, 'FM999G999G990D00', q'[NLS_NUMERIC_CHARACTERS=',.']') || ' €';
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
  begin
    channel_ok(p_channel);
    select iban into iban_ from bk_account where id = p_account_id;
    resolve(p_account_id, p_op, p_channel, 'ALLOWED', v, sc);
    if v = 0 then
      fail(26, 'Δεν επιτρέπεται ' || op_text(p_op) || ' ' || channel_text(p_channel) || ' στον ' || iban_);
    end if;
    resolve(p_account_id, p_op, p_channel, 'MIN_AMOUNT', v, sc);
    if p_amount < v then
      fail(27, 'Η ' || op_text(p_op) || ' ' || channel_text(p_channel) || ' είναι από ' || money_text(v));
    end if;
    resolve(p_account_id, p_op, p_channel, 'MAX_AMOUNT', v, sc);
    if p_amount > v then
      fail(27, 'Η ' || op_text(p_op) || ' ' || channel_text(p_channel) || ' είναι ως ' || money_text(v));
    end if;
    for k in (select column_value attr from table(sys.odcivarchar2list('DAY_AMOUNT', 'DAY_COUNT', 'MONTH_AMOUNT', 'MONTH_COUNT'))) loop
      resolve(p_account_id, p_op, p_channel, k.attr, v, sc);
      if v is not null then
        u := used(p_account_id, p_op, sc, substr(k.attr, 1, 1), case when k.attr like '%AMOUNT' then 'A' else 'C' end);
        where_ := channel_text(sc);
        if k.attr like '%AMOUNT' and u + p_amount > v then
          fail(case when k.attr like 'DAY%' then 28 else 29 end,
               'Ξεπερνά το ' || case when k.attr like 'DAY%' then 'ημερήσιο' else 'μηνιαίο' end || ' όριο: ' || op_text(p_op)
               || ' ' || where_ || ', έχουν γίνει ' || money_text(u) || ', όριο ' || money_text(v));
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
      fail(30, 'Στον ' || a.iban || ' πρέπει να μένουν τουλάχιστον ' || money_text(v) || ': διαθέσιμα για '
               || op_text(p_op) || ' ' || money_text(greatest(a.balance - v, 0)));
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
    line(e, null, 'CASH', p_amount, 0);
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
  begin
    amount_ok(p_amount);
    if p_from_id = p_to_id then
      fail(20, 'Μεταφορά στον ίδιο λογαριασμό');
    end if;
    lock_accounts(p_from_id, p_to_id);
    into_ok(account_row(p_to_id));
    fee := rules_ok(p_from_id, 'TRO', p_channel, p_amount);
    fee_to := rules_ok(p_to_id, 'TRI', p_channel, p_amount);
    out_ok(p_from_id, p_amount + fee);
    floor_ok(p_from_id, 'TRO', p_channel, p_amount + fee);
    e := new_entry('TRF', p_value_date, nvl(p_descr, 'Μεταφορά'), null, p_channel);
    line(e, p_from_id, null, p_amount, 0, 'TRO');
    line(e, p_to_id, null, 0, p_amount, 'TRI');
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
    line(e, null, 'CLEAR', p_amount, 0);
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
      if l.took > 0 then
        out_ok(l.account_id, l.took);
      else
        into_ok(account_row(l.account_id));
      end if;
    end loop;
    e := new_entry('REV', null, nvl(p_descr, 'Αντιλογισμός της κίνησης ' || p_entry_id), p_entry_id);
    for l in (select account_id, gl_code, debit, credit, op from bk_line where entry_id = p_entry_id order by id) loop
      line(e, l.account_id, l.gl_code, l.credit, l.debit, l.op);
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

  -- the last day of the period of capitalization of a day
  function period_end(p_cap varchar2, p_day date) return boolean is
  begin
    if p_day <> last_day(p_day) then
      return false;
    end if;
    return case p_cap when 'M' then true
                      when 'Q' then to_char(p_day, 'MM') in ('03', '06', '09', '12')
                      else to_char(p_day, 'MM') = '12' end;
  end;

  function capitalize(p_account_id number, p_day date) return number is
    a bk_account%rowtype;
    p bk_product%rowtype;
    gross number;
    tax number := 0;
    e number;
  begin
    select * into a from bk_account where id = p_account_id for update;
    select * into p from bk_product where id = a.product_id;
    gross := round(a.accrued, 2);
    if gross = 0 then
      return null;
    end if;
    if gross > 0 then
      tax := round(gross * p.tax_rate / 100, 2);
    end if;
    -- booked on the day (the business day: close_day), with its value date
    insert into bk_entry (kind, book_date, value_date, channel, descr)
    values ('INT', p_day, p_day, 'SYS',
            case when gross > 0 then 'Τόκοι ' || to_char(p_day, 'MM/YYYY') || case when tax > 0 then ' (φόρος ' || rtrim(rtrim(to_char(p.tax_rate, 'FM990D00', q'[NLS_NUMERIC_CHARACTERS=',.']'), '0'), ',') || '%)' end
                 else 'Χρεωστικοί τόκοι υπερανάληψης ' || to_char(p_day, 'MM/YYYY') end)
    returning id into e;
    if gross > 0 then
      line(e, null, 'INT_EXP', gross, 0);
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

  procedure close_day(p_day date default null) is
    d date := open_day;
    days_ number;
    year_ number;
    rate_ number;
    i number;
    e number;
  begin
    if p_day is not null and trunc(p_day) <> d then
      fail(24, 'Κλείνει μόνο η εργάσιμη ημέρα ' || to_char(d, 'DD/MM/YYYY') || ', όχι η ' || to_char(p_day, 'DD/MM/YYYY'));
    end if;
    for a in (select a.id, a.product_id, p.day_basis, p.cap_every,
                     (select nvl(sum(l.credit - l.debit), 0) from bk_line l join bk_entry x on x.id = l.entry_id
                      where l.account_id = a.id and x.value_date <= d) vb
              from bk_account a join bk_product p on p.id = a.product_id
              where a.status <> 'C' and a.opened_on <= d
              order by a.id) loop
      day_count(a.day_basis, d, days_, year_);
      rate_ := rate_of(a.product_id, d, a.vb);
      i := a.vb * rate_ / 100 * days_ / year_;
      insert into bk_accrual (account_id, day, balance, rate, days, year_days, interest)
      values (a.id, d, a.vb, rate_, days_, year_, round(i, 6));
      update bk_account set accrued = accrued + round(i, 6), accrued_to = d where id = a.id;
      if period_end(a.cap_every, d) then
        e := capitalize(a.id, d);
      end if;
    end loop;
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
               || to_char(a.balance, 'FM999G999G990D00', q'[NLS_NUMERIC_CHARACTERS=',.']') || ' €: ανάληψη ή μεταφορά του πρώτα');
    end if;
    select count(*) into e from bk_entry x join bk_line l on l.entry_id = x.id
    where l.account_id = p_account_id and x.value_date > d;
    if e > 0 then
      fail(25, 'Ο λογαριασμός ' || a.iban || ' έχει κινήσεις με μελλοντική ημερομηνία αξίας');
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
    e := withdraw(a, p_amount, 'Ανάληψη ATM ' || m.code || ' ' || m.name, null, 'ATM');
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
    if mod(p_amount, 5) <> 0 then
      fail(38, 'Το ATM δέχεται χαρτονομίσματα: ένα ποσό σε πεντάδες');
    end if;
    e := deposit(a, p_amount, 'Κατάθεση ATM ' || m.code || ' ' || m.name, null, 'ATM');
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
    return transfer(a, t, p_amount, 'Μεταφορά από ATM ' || m.code, null, 'ATM');
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
