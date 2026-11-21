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
  -- day). Out of an account: open (not blocked), within its balance and its overdraft limit
  function deposit(p_account_id number, p_amount number, p_descr varchar2 default null,
                   p_value_date date default null) return number;
  function withdraw(p_account_id number, p_amount number, p_descr varchar2 default null,
                    p_value_date date default null) return number;
  function transfer(p_from_id number, p_to_id number, p_amount number, p_descr varchar2 default null,
                    p_value_date date default null) return number;
  function transfer_out(p_from_id number, p_amount number, p_iban_to varchar2, p_descr varchar2 default null,
                        p_value_date date default null) return number;
  function transfer_in(p_to_id number, p_amount number, p_iban_from varchar2, p_descr varchar2 default null,
                       p_value_date date default null) return number;
  -- the opposite of an entry, booked on the business day (once; not of a reversal, not of interest)
  function reverse(p_entry_id number, p_descr varchar2 default null) return number;

  -- the end of the business day: the interest of every open account for it, the capitalization at the end
  -- of each period (and of an account closed), then the day closed. p_day: the business day (a check)
  procedure close_day(p_day date default null);
  -- the interest accrued capitalized now (close_account does it): its entry, or null when nothing
  function capitalize(p_account_id number, p_day date) return number;

  -- the balance of an account by value date at the end of a day
  function value_balance(p_account_id number, p_day date) return number;

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
  function new_entry(p_kind varchar2, p_value_date date, p_descr varchar2, p_reversal_of number default null)
    return number is
    d date := open_day;
    vd date := nvl(trunc(p_value_date), d);
    v number;
  begin
    if vd < d then
      fail(16, 'Η ημερομηνία αξίας ' || to_char(vd, 'DD/MM/YYYY') || ' είναι πριν από την εργάσιμη ημέρα '
               || to_char(d, 'DD/MM/YYYY') || ' (οι τόκοι των κλεισμένων ημερών δεν ξαναμετριούνται)');
    end if;
    insert into bk_entry (kind, book_date, value_date, descr, reversal_of)
    values (p_kind, d, vd, substr(p_descr, 1, 200), p_reversal_of) returning id into v;
    return v;
  end;

  procedure line(p_entry_id number, p_account_id number, p_gl_code varchar2, p_debit number, p_credit number) is
  begin
    insert into bk_line (entry_id, account_id, gl_code, debit, credit)
    values (p_entry_id, p_account_id, p_gl_code, nvl(p_debit, 0), nvl(p_credit, 0));
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

  function deposit(p_account_id number, p_amount number, p_descr varchar2 default null,
                   p_value_date date default null) return number is
    a bk_account%rowtype := account_row(p_account_id);
    e number;
  begin
    amount_ok(p_amount);
    into_ok(a);
    e := new_entry('DEP', p_value_date, nvl(p_descr, 'Κατάθεση'));
    line(e, null, 'CASH', p_amount, 0);
    line(e, p_account_id, null, 0, p_amount);
    return e;
  end;

  function withdraw(p_account_id number, p_amount number, p_descr varchar2 default null,
                    p_value_date date default null) return number is
    e number;
  begin
    amount_ok(p_amount);
    out_ok(p_account_id, p_amount);
    e := new_entry('WDR', p_value_date, nvl(p_descr, 'Ανάληψη'));
    line(e, p_account_id, null, p_amount, 0);
    line(e, null, 'CASH', 0, p_amount);
    return e;
  end;

  function transfer(p_from_id number, p_to_id number, p_amount number, p_descr varchar2 default null,
                    p_value_date date default null) return number is
    t bk_account%rowtype := account_row(p_to_id);
    e number;
  begin
    amount_ok(p_amount);
    if p_from_id = p_to_id then
      fail(20, 'Μεταφορά στον ίδιο λογαριασμό');
    end if;
    into_ok(t);
    out_ok(p_from_id, p_amount);
    e := new_entry('TRF', p_value_date, nvl(p_descr, 'Μεταφορά'));
    line(e, p_from_id, null, p_amount, 0);
    line(e, p_to_id, null, 0, p_amount);
    return e;
  end;

  function transfer_out(p_from_id number, p_amount number, p_iban_to varchar2, p_descr varchar2 default null,
                        p_value_date date default null) return number is
    e number;
  begin
    amount_ok(p_amount);
    if iban_ok(replace(upper(p_iban_to), ' ')) = 'N' then
      fail(21, 'Λάθος IBAN δικαιούχου: ' || p_iban_to);
    end if;
    out_ok(p_from_id, p_amount);
    e := new_entry('OUT', p_value_date, nvl(p_descr, 'Μεταφορά σε ' || replace(upper(p_iban_to), ' ')));
    line(e, p_from_id, null, p_amount, 0);
    line(e, null, 'CLEAR', 0, p_amount);
    return e;
  end;

  function transfer_in(p_to_id number, p_amount number, p_iban_from varchar2, p_descr varchar2 default null,
                       p_value_date date default null) return number is
    t bk_account%rowtype := account_row(p_to_id);
    e number;
  begin
    amount_ok(p_amount);
    if iban_ok(replace(upper(p_iban_from), ' ')) = 'N' then
      fail(21, 'Λάθος IBAN αποστολέα: ' || p_iban_from);
    end if;
    into_ok(t);
    e := new_entry('INC', p_value_date, nvl(p_descr, 'Μεταφορά από ' || replace(upper(p_iban_from), ' ')));
    line(e, null, 'CLEAR', p_amount, 0);
    line(e, p_to_id, null, 0, p_amount);
    return e;
  end;

  function reverse(p_entry_id number, p_descr varchar2 default null) return number is
    o bk_entry%rowtype;
    e number;
    n number;
  begin
    begin
      select * into o from bk_entry where id = p_entry_id;
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
              where entry_id = p_entry_id and account_id is not null group by account_id) loop
      if l.took > 0 then
        out_ok(l.account_id, l.took);
      else
        into_ok(account_row(l.account_id));
      end if;
    end loop;
    e := new_entry('REV', null, nvl(p_descr, 'Αντιλογισμός της κίνησης ' || p_entry_id), p_entry_id);
    for l in (select account_id, gl_code, debit, credit from bk_line where entry_id = p_entry_id order by id) loop
      line(e, l.account_id, l.gl_code, l.credit, l.debit);
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
    insert into bk_entry (kind, book_date, value_date, descr)
    values ('INT', p_day, p_day,
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

end bk_core;
/
