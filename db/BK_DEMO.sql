-- BK_DEMO.sql -- demo rows, all of them made up (random, the same every time: a fixed seed): 40 customers
-- (their AFM with a right check digit, belonging to nobody we know), their accounts (some joint, some with an
-- overdraft), and a year of movements, day by day: salaries, rents, withdrawals, card payments, transfers,
-- transfers to other banks, a few reversals; every day closed (the interest of each day; capitalized at the
-- end of each period, with its tax). A rate of the savings changed in the middle of the year. The rules of the
-- movements: no deposit or withdrawal from the e-banking, the ATM up to 600 € a day, a fee for a transfer to
-- another bank at the counter and for the 4th withdrawal of the month at the counter on, the savings without
-- transfers to another bank and up to 4 withdrawals a month, the savings plus with 100 € left in them always,
-- a lower ATM limit for a few accounts; a movement out of its rules is not done. Run by
-- INSTALL.sql demo; once: a database with entries already is left as it is.
set serveroutput on
declare
  type t_txt is table of varchar2(40);
  firsts_m t_txt := t_txt('Γιώργος', 'Νίκος', 'Κώστας', 'Δημήτρης', 'Γιάννης', 'Παναγιώτης', 'Βασίλης', 'Χρήστος',
                          'Αντώνης', 'Μιχάλης', 'Σπύρος', 'Θανάσης', 'Ηλίας', 'Στέλιος', 'Άγγελος');
  firsts_f t_txt := t_txt('Μαρία', 'Ελένη', 'Κατερίνα', 'Βασιλική', 'Σοφία', 'Αγγελική', 'Δήμητρα', 'Γεωργία',
                          'Ευαγγελία', 'Χριστίνα', 'Αναστασία', 'Ιωάννα', 'Παναγιώτα', 'Ειρήνη', 'Δέσποινα');
  lasts_m t_txt := t_txt('Παπαδόπουλος', 'Γεωργίου', 'Οικονόμου', 'Νικολάου', 'Δημητρίου', 'Παπαγεωργίου',
                         'Αθανασίου', 'Ιωάννου', 'Κωνσταντίνου', 'Βασιλείου', 'Μακρής', 'Αλεξίου', 'Πετρόπουλος',
                         'Σταματόπουλος', 'Κυριακίδης');
  lasts_f t_txt := t_txt('Παπαδοπούλου', 'Γεωργίου', 'Οικονόμου', 'Νικολάου', 'Δημητρίου', 'Παπαγεωργίου',
                         'Αθανασίου', 'Ιωάννου', 'Κωνσταντίνου', 'Βασιλείου', 'Μακρή', 'Αλεξίου', 'Πετροπούλου',
                         'Σταματοπούλου', 'Κυριακίδου');
  latin t_txt := t_txt('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'k', 'l', 'm', 'n', 'p', 's');
  streets t_txt := t_txt('Αγίου Νικολάου', 'Κορίνθου', 'Μαιζώνος', 'Ρήγα Φεραίου', 'Γούναρη', 'Αγίου Ανδρέου',
                         'Καραϊσκάκη', 'Ερμού', 'Πανεπιστημίου', 'Τριών Ναυάρχων');
  cities t_txt := t_txt('Πάτρα', 'Αθήνα', 'Θεσσαλονίκη', 'Αίγιο', 'Πύργος', 'Ναύπακτος');
  type t_num is table of number index by pls_integer;
  cust t_num;
  acc t_num;          -- every account
  salary t_num;       -- by account: the salary that comes in every month (0: none)
  rent t_num;         -- by account: a rent paid every month (0: none)
  n number;
  e number;
  d date;
  first_day date := trunc(sysdate) - 365;
  last_day_ date := trunc(sysdate) - 1;
  k pls_integer;
  a number;
  b number;
  amt number;
  avail number;
  female boolean;

  function pick(p t_txt) return varchar2 is
  begin
    return p(trunc(dbms_random.value(1, p.count + 1)));
  end;

  -- a made-up AFM with a right check digit
  function new_afm return varchar2 is
    s varchar2(9);
    t number := 0;
  begin
    loop
      s := to_char(trunc(dbms_random.value(10000000, 99999999)));
      t := 0;
      for i in 1 .. 8 loop
        t := t + to_number(substr(s, i, 1)) * power(2, 9 - i);
      end loop;
      s := s || to_char(mod(mod(t, 11), 10));
      select count(*) into t from bk_customer where afm = s;
      exit when t = 0;
    end loop;
    return s;
  end;

  function available(p_acc number) return number is
    v number;
  begin
    select case when status = 'O' then balance + od_limit else 0 end into v from bk_account where id = p_acc;
    return v;
  end;

  function money(p_from number, p_to number) return number is
  begin
    return round(dbms_random.value(p_from, p_to), 2);
  end;

  -- a movement out of the rules of its account (or without the money for its fee): not done
  procedure refused is
  begin
    if sqlcode not between -20132 and -20118 then
      raise_application_error(-20000, sqlerrm);
    end if;
  end;
begin
  select count(*) into n from bk_entry;
  if n > 0 then
    dbms_output.put_line('== demo: the database has entries already, nothing done');
    return;
  end if;
  dbms_random.seed(2026);
  bk_core.set_start(first_day);

  -- the customers
  for i in 1 .. 40 loop
    female := mod(i, 2) = 0;
    k := i;
    cust(i) := bk_core.new_customer(
      p_name => case when female then pick(firsts_f) || ' ' || pick(lasts_f) else pick(firsts_m) || ' ' || pick(lasts_m) end,
      p_afm => new_afm,
      p_phone => '69' || to_char(trunc(dbms_random.value(10000000, 99999999))),
      p_email => pick(latin) || pick(latin) || '.' || pick(latin) || pick(latin) || pick(latin) || i || '@example.com',
      p_address => pick(streets) || ' ' || trunc(dbms_random.value(1, 120)) || ', ' || pick(cities),
      p_birth_date => first_day - trunc(dbms_random.value(20 * 365, 75 * 365)),
      p_id_card => chr(65 + trunc(dbms_random.value(0, 26))) || chr(65 + trunc(dbms_random.value(0, 26)))
                   || ' ' || to_char(trunc(dbms_random.value(100000, 999999))));
  end loop;

  -- the accounts: each customer a current one (a third of them with an overdraft), half of them savings too,
  -- some a business one or a savings plus; 8 joint (a second holder)
  k := 0;
  for i in 1 .. 40 loop
    k := k + 1;
    acc(k) := bk_core.open_account('CUR', cust(i), case when mod(i, 3) = 0 then 1000 * trunc(dbms_random.value(1, 4)) else 0 end);
    salary(k) := case when mod(i, 5) <> 4 then money(850, 2600) else 0 end;
    rent(k) := case when mod(i, 4) = 1 then money(250, 650) else 0 end;
    if mod(i, 2) = 1 then
      k := k + 1;
      acc(k) := bk_core.open_account('SAV', cust(i));
      salary(k) := 0; rent(k) := 0;
    end if;
    if mod(i, 7) = 0 then
      k := k + 1;
      acc(k) := bk_core.open_account('BUS', cust(i), 5000, 'Επαγγελματικός');
      salary(k) := 0; rent(k) := 0;
    end if;
    if mod(i, 9) = 0 then
      k := k + 1;
      acc(k) := bk_core.open_account('SAVP', cust(i));
      salary(k) := 0; rent(k) := 0;
    end if;
  end loop;
  for j in 1 .. 8 loop
    bk_core.add_holder(acc(j * 3), cust(41 - j));
  end loop;

  -- the rules of the movements: of the bank, of the products, of a few accounts
  n := bk_core.set_rule(null, null, 'DEP', 'WEB', p_allowed => 'N');
  n := bk_core.set_rule(null, null, 'WDR', 'WEB', p_allowed => 'N');
  n := bk_core.set_rule(null, null, 'WDR', 'ATM', p_min_amount => 20, p_max_amount => 600, p_day_amount => 600);
  n := bk_core.set_rule(null, null, 'WDR', 'BR', p_free_month => 3, p_fee => 1);
  n := bk_core.set_rule(null, null, 'OUT', 'WEB', p_day_amount => 5000);
  n := bk_core.set_rule(null, null, 'OUT', 'BR', p_fee => 3);
  n := bk_core.set_rule('SAV', null, 'OUT', '*', p_allowed => 'N');
  n := bk_core.set_rule('SAV', null, 'WDR', '*', p_month_count => 4);
  for x in (select column_value op from table(sys.odcivarchar2list('WDR', 'TRO', 'OUT'))) loop
    n := bk_core.set_rule('SAVP', null, x.op, '*', p_min_balance => 100);
  end loop;
  for j in 1 .. 3 loop
    n := bk_core.set_rule(null, acc(j * 11), 'WDR', 'ATM', p_max_amount => 200, p_day_amount => 200);
  end loop;

  -- the first money: every account something in, the savings more
  for j in 1 .. acc.count loop
    select case p.kind when 'SAV' then 1 else 0 end into n
    from bk_account x join bk_product p on p.id = x.product_id where x.id = acc(j);
    e := bk_core.deposit(acc(j), case when n = 1 then money(2000, 35000) else money(100, 3000) end, 'Αρχική κατάθεση');
  end loop;

  -- a year, day by day
  d := first_day;
  while d <= last_day_ loop
    -- the rates of the savings up in the middle of the year
    if d = first_day + 180 then
      for p in (select id from bk_product where code = 'SAV') loop
        bk_core.set_rate(p.id, d, 0, 0.10);
        bk_core.set_rate(p.id, d, 5000, 0.20);
        bk_core.set_rate(p.id, d, 20000, 0.40);
      end loop;
    end if;
    for j in 1 .. acc.count loop
      -- the salary, on a day of its own early in the month; the rent a few days later
      if salary(j) > 0 and to_number(to_char(d, 'DD')) = 1 + mod(j, 4) then
        e := bk_core.transfer_in(acc(j), salary(j), 'GR1601101250000000012300695', 'Μισθοδοσία ' || to_char(d, 'MM/YYYY'),
                                 p_channel => 'WEB');
      end if;
      -- the rent from the e-banking, or at the counter now and then (with its fee)
      if rent(j) > 0 and to_number(to_char(d, 'DD')) = 5 + mod(j, 3) and available(acc(j)) >= rent(j) + 3 then
        begin
          e := bk_core.transfer_out(acc(j), rent(j), 'GR1601101250000000012300695', 'Ενοίκιο ' || to_char(d, 'MM/YYYY'),
                                    p_channel => case when dbms_random.value < 0.2 then 'BR' else 'WEB' end);
        exception when others then refused;
        end;
      end if;
      -- now and then: a withdrawal (mostly from an ATM), a card payment, a deposit, a transfer to another
      -- account of the bank
      if dbms_random.value < 0.08 then
        amt := round(dbms_random.value(20, 400) / 10) * 10;
        avail := available(acc(j));
        if avail >= amt then
          begin
            if dbms_random.value < 0.8 then
              e := bk_core.withdraw(acc(j), amt, 'Ανάληψη ΑΤΜ', p_channel => 'ATM');
            else
              e := bk_core.withdraw(acc(j), amt, 'Ανάληψη', p_channel => 'BR');
            end if;
          exception when others then refused;
          end;
        end if;
      end if;
      if dbms_random.value < 0.12 then
        amt := money(5, 180);
        if available(acc(j)) >= amt then
          begin
            e := bk_core.transfer_out(acc(j), amt, 'GR9608100010000001234567890',
                                      'Πληρωμή με κάρτα: ' || case trunc(dbms_random.value(0, 5)) when 0 then 'σούπερ μάρκετ'
                                        when 1 then 'καύσιμα' when 2 then 'φαρμακείο' when 3 then 'εστιατόριο' else 'ηλεκτρονικό κατάστημα' end,
                                      p_channel => 'WEB');
          exception when others then refused;
          end;
        end if;
      end if;
      if dbms_random.value < 0.03 then
        e := bk_core.deposit(acc(j), money(50, 1500), 'Κατάθεση μετρητών');
      end if;
      if dbms_random.value < 0.02 then
        b := acc(trunc(dbms_random.value(1, acc.count + 1)));
        amt := money(10, 800);
        if b <> acc(j) and available(acc(j)) >= amt then
          begin
            e := bk_core.transfer(acc(j), b, amt, 'Μεταφορά', p_channel => 'WEB');
          exception when others then refused;
          end;
        end if;
      end if;
    end loop;
    -- a few reversals: a card payment booked twice by mistake
    if mod(d - first_day, 61) = 30 then
      a := acc(trunc(dbms_random.value(1, acc.count + 1)));
      if available(a) >= 30 then
        begin
          e := bk_core.transfer_out(a, 29.90, 'GR9608100010000001234567890', 'Πληρωμή με κάρτα: ηλεκτρονικό κατάστημα',
                                    p_channel => 'WEB');
          n := bk_core.reverse(e, 'Αντιλογισμός: διπλή χρέωση');
        exception when others then refused;
        end;
      end if;
    end if;
    bk_core.close_day(d);
    d := d + 1;
  end loop;
  commit;
  select count(*) into n from bk_entry;
  dbms_output.put_line('== demo: ' || cust.count || ' customers, ' || acc.count || ' accounts, ' || n || ' entries, '
                       || (last_day_ - first_day + 1) || ' days closed');
end;
/
set serveroutput off
