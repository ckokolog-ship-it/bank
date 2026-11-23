-- BK_DEMO.sql -- demo rows, all of them made up (random, the same every time: a fixed seed): 40 customers
-- (their AFM with a right check digit, belonging to nobody we know), their accounts (some joint, some with an
-- overdraft), and a year of movements, day by day: salaries, rents, withdrawals, card payments, transfers,
-- transfers to other banks, a few reversals; every day closed (the interest of each day; capitalized at the
-- end of each period, with its tax). A rate of the savings changed in the middle of the year. The rules of the
-- movements: no deposit or withdrawal from the e-banking, the ATM up to 600 € a day, a fee for a transfer to
-- another bank at the counter and for the 4th withdrawal of the month at the counter on, the savings without
-- transfers to another bank and up to 4 withdrawals a month, the savings plus with 100 € left in them always,
-- a lower ATM limit for a few accounts; a movement out of its rules is not done. 12 credit cards (Classic, Gold):
-- purchases, a hotel held and released now and then, a statement a month, paid from the current account of the
-- customer a couple of days before it is due (in full, the minimum, or a part), or not at all: the fee; now and
-- then a purchase abroad (USD, GBP, CHF, JPY). The rates of the currencies every day (a random walk); 8 accounts in
-- USD or GBP, money changed into them every month. 8 loans (home: variable on the Euribor of 3 months, which moves
-- every month; consumer: fixed), paid from the current account of the customer (late when it has not the money:
-- its fee, its late interest), a prepayment and a payoff. Run by
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
  curacc t_num;       -- by customer: its current account
  cca t_num;          -- the credit cards: their account, their card, how they are paid (F in full, M the
  cck t_num;          --   minimum, P a part, 0 F, 1 M, 2 P)
  ccpay t_num;
  ccx number;
  fx t_txt := t_txt('USD', 'GBP', 'CHF', 'JPY', 'SEK', 'NOK', 'DKK', 'CAD', 'AUD');
  fxa t_num;          -- the accounts in another currency, and the current account in EUR of their customer
  fxf t_num;
  mid number;
  lna t_num;          -- the loans
  eur3 number := 2.5;
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

  -- the branch of a customer (its accounts, cards, loans there): of the three, by its number
  function brof(p_i number) return varchar2 is
  begin
    return case mod(p_i, 3) when 1 then '0001' when 2 then '0002' else '0003' end;
  end;

  -- what is done at a counter for an account: in its branch
  procedure at_branch(p_acc number) is
    b varchar2(4);
  begin
    select branch_code into b from bk_account where id = p_acc;
    bk_core.set_branch_context(b);
  end;

  function available(p_acc number) return number is
    v number;
  begin
    select case when status = 'O' then balance + od_limit else 0 end into v from bk_account where id = p_acc;
    return v;
  end;

  -- a shop of a kind, by a number (the day, the account): its name as a bank sees it (for the search by meaning:
  -- db/BK_VECTOR.sql); no random draw of its own (the rest of the demo the same as before)
  function shop(p_kind varchar2, p_n number) return varchar2 is
    k pls_integer := mod(p_n, 4);
  begin
    return case p_kind
      when 'σούπερ μάρκετ' then case k when 0 then 'ΣΚΛΑΒΕΝΙΤΗΣ σούπερ μάρκετ' when 1 then 'ΑΒ Βασιλόπουλος τρόφιμα'
                                       when 2 then 'Lidl σούπερ μάρκετ' else 'Μανάβικο Η Λαϊκή φρούτα και λαχανικά' end
      when 'καύσιμα' then case k when 0 then 'SHELL πρατήριο Ρίου' when 1 then 'EKO βενζίνη Πατρών'
                                 when 2 then 'AVIN καύσιμα Αθήνας' else 'BP πρατήριο καυσίμων Αιγίου' end
      when 'φαρμακείο' then case k when 0 then 'Φαρμακείο Παπαδοπούλου' when 1 then 'Φαρμακείο Κέντρου'
                                   when 2 then 'Διαγνωστικό κέντρο Υγεία' else 'Οδοντίατρος Κ. Λάμπρου' end
      when 'εστιατόριο' then case k when 0 then 'Ταβέρνα Ο Μπάμπης' when 1 then 'Ψητοπωλείο Το Κάρβουνο'
                                    when 2 then 'Pizza Fan πιτσαρία Πάτρα' else 'Καφέ Μπουκάλι καφετέρια' end
      when 'ηλεκτρονικό κατάστημα' then case k when 0 then 'Skroutz.gr ηλεκτρονική παραγγελία' when 1 then 'Public.gr βιβλία'
                                               when 2 then 'Κωτσόβολος ηλεκτρικές συσκευές' else 'e-shop.gr υπολογιστές' end
      when 'ρούχα' then case k when 0 then 'ZARA ρούχα' when 1 then 'HM Hennes ένδυση'
                               when 2 then 'Intersport αθλητικά είδη' else 'Υποδήματα Βογιατζής παπούτσια' end
      when 'αεροπορικά' then case k when 0 then 'AEGEAN αεροπορικά εισιτήρια' when 1 then 'Ryanair πτήση'
                                    when 2 then 'Blue Star Ferries εισιτήριο πλοίου' else 'Booking.com ξενοδοχείο' end
      else p_kind end;
  end;

  function money(p_from number, p_to number) return number is
  begin
    return round(dbms_random.value(p_from, p_to), 2);
  end;

  -- a movement out of the rules of its account (or without the money for its fee): not done
  procedure refused is
  begin
    if sqlcode not between -20132 and -20118 and sqlcode <> -20147 then
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
    bk_core.set_branch_context(brof(i));
    k := k + 1;
    acc(k) := bk_core.open_account('CUR', cust(i), case when mod(i, 3) = 0 then 1000 * trunc(dbms_random.value(1, 4)) else 0 end);
    curacc(i) := acc(k);
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
  -- 8 current accounts in another currency (USD, GBP)
  for j in 1 .. 8 loop
    bk_core.set_branch_context(brof(j * 5 - 3));
    k := k + 1;
    acc(k) := bk_core.open_account('CUR', cust(j * 5 - 3), 0, null, case when mod(j, 2) = 0 then 'GBP' else 'USD' end);
    salary(k) := 0; rent(k) := 0;
    fxa(j) := acc(k);
    fxf(j) := curacc(j * 5 - 3);
  end loop;

  -- the debit cards: one for each current account, of its primary holder; their PIN given at the counter
  for x in (select a.id from bk_account a join bk_product p on p.id = a.product_id where p.kind = 'CUR' order by a.id) loop
    n := bk_core.new_card(x.id);
  end loop;

  -- the credit cards: every third customer, Gold every 4th of them; their statement on a day of their own
  for j in 1 .. 12 loop
    bk_core.set_branch_context(brof(j * 3));
    cca(j) := bk_core.cc_open(case when mod(j, 4) = 0 then 'GOLD' else 'VISA' end, cust(j * 3),
                              case when mod(j, 4) = 0 then 1000 * trunc(dbms_random.value(5, 11))
                                   else 500 * trunc(dbms_random.value(2, 9)) end,
                              1 + mod(j * 5, 28));
    cck(j) := bk_core.new_card(cca(j));
    ccpay(j) := mod(j, 3);
  end loop;

  -- the loans: of every 4th customer from the 5th, home (3 of them) or consumer; the money paid at once (a house, a car)
  for j in 1 .. 8 loop
    bk_core.set_branch_context(brof(j * 4 + 1));
    if mod(j, 3) = 1 then
      lna(j) := bk_core.ln_open('HOME', cust(j * 4 + 1), 1000 * trunc(dbms_random.value(60, 121)), 300, curacc(j * 4 + 1),
                                1 + mod(j * 7, 28));
    else
      lna(j) := bk_core.ln_open('CONS', cust(j * 4 + 1), 500 * trunc(dbms_random.value(8, 41)), 12 * trunc(dbms_random.value(2, 6)),
                                curacc(j * 4 + 1), 1 + mod(j * 7, 28));
    end if;
    select l.principal into amt from bk_loan l where l.account_id = lna(j);
    e := bk_core.transfer_out(curacc(j * 4 + 1), amt, 'GR9608100010000001234567890',
                              case when mod(j, 3) = 1 then 'Αγορά κατοικίας' else 'Αγορά αυτοκινήτου' end, p_channel => 'WEB');
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
    at_branch(acc(j));
    select case p.kind when 'SAV' then 1 else 0 end into n
    from bk_account x join bk_product p on p.id = x.product_id where x.id = acc(j);
    e := bk_core.deposit(acc(j), case when n = 1 then money(2000, 35000) else money(100, 3000) end, 'Αρχική κατάθεση');
  end loop;

  -- a year, day by day
  d := first_day;
  while d <= last_day_ loop
    -- the rates of the day: each a little up or down
    for c in 1 .. fx.count loop
      mid := bk_core.fx_rate(fx(c), d);
      -- (the krone of Denmark tied to the euro: hardly)
      bk_core.set_fx_rate(fx(c), d, round(mid * exp(dbms_random.normal * case when fx(c) = 'DKK' then 0.0003 else 0.003 end),
                                          case when fx(c) = 'JPY' then 2 else 4 end));
    end loop;
    -- the Euribor of 3 months on the 1st of each month: a little up or down
    if to_number(to_char(d, 'DD')) = 1 then
      eur3 := greatest(round(eur3 + dbms_random.normal * 0.08, 3), 0);
      bk_core.set_ln_index('EURIBOR3M', d, eur3);
    end if;
    -- a prepayment of a consumer loan in the middle of the year; another one paid off after 9 months
    if d = first_day + 180 or d = first_day + 270 then
      a := lna(case when d = first_day + 180 then 2 else 3 end);
      begin
        select pay_account_id into b from bk_loan where account_id = a;
        amt := case when d = first_day + 180 then 1500 else bk_core.ln_payoff(a) end;
        e := bk_core.deposit(b, amt + 50, case when d = first_day + 180 then 'Κατάθεση για πρόωρη εξόφληση' else 'Κατάθεση για εξόφληση' end);
        e := bk_core.ln_prepay(a, amt, 'T');
      exception when others then
        if sqlcode not in (-20158, -20119) then raise; end if;
      end;
    end if;
    -- money changed into the accounts in another currency, on the 10th
    if to_number(to_char(d, 'DD')) = 10 then
      for j in 1 .. fxa.count loop
        amt := money(100, 400);
        if available(fxf(j)) >= amt then
          begin
            e := bk_core.transfer(fxf(j), fxa(j), amt, 'Αγορά συναλλάγματος', p_channel => 'WEB');
          exception when others then refused;
          end;
        end if;
      end loop;
    end if;
    -- the rates of the savings up in the middle of the year
    if d = first_day + 180 then
      for p in (select id from bk_product where code = 'SAV') loop
        bk_core.set_rate(p.id, d, 0, 0.10);
        bk_core.set_rate(p.id, d, 5000, 0.20);
        bk_core.set_rate(p.id, d, 20000, 0.40);
      end loop;
    end if;
    for j in 1 .. acc.count loop
      at_branch(acc(j));
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
      -- the bills of the month from the e-banking (the accounts with a salary): the power every month, the water every
      -- other month, the mobile, a subscription or two (amounts of their own: no random draw)
      if salary(j) > 0 and to_number(to_char(d, 'DD')) = 10 + mod(j, 5) then
        for b_ in (select 'ΔΕΗ λογαριασμός ρεύματος' w, 38 + mod(j * 7 + to_number(to_char(d, 'MM')) * 11, 70) a, 1 ok from dual
                   union all select 'ΕΥΔΑΠ λογαριασμός νερού', 18 + mod(j * 5, 25), mod(to_number(to_char(d, 'MM')), 2) from dual
                   union all select 'COSMOTE κινητή τηλεφωνία', 25 + mod(j * 3, 20), case when mod(j, 3) = 0 then 1 else 0 end from dual
                   union all select 'Vodafone internet σπιτιού', 32, case when mod(j, 3) = 1 then 1 else 0 end from dual
                   union all select 'Netflix συνδρομή ταινιών', 11.99, case when mod(j, 4) = 0 then 1 else 0 end from dual
                   union all select 'Spotify συνδρομή μουσικής', 10.99, case when mod(j, 5) = 0 then 1 else 0 end from dual) loop
          if b_.ok = 1 and available(acc(j)) >= b_.a + 50 then
            begin
              e := bk_core.transfer_out(acc(j), b_.a, 'GR9608100010000001234567890', rtrim(b_.w), p_channel => 'WEB');
            exception when others then refused;
            end;
          end if;
        end loop;
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
                                      'Πληρωμή με κάρτα: ' || shop(case trunc(dbms_random.value(0, 5)) when 0 then 'σούπερ μάρκετ'
                                        when 1 then 'καύσιμα' when 2 then 'φαρμακείο' when 3 then 'εστιατόριο' else 'ηλεκτρονικό κατάστημα' end,
                                        j + to_number(to_char(d, 'DDD'))),
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
    -- the credit cards: purchases; a hotel held, released a few days on (CC_HOLD_DAYS); the statements due in 2
    -- days paid (from the current account, as much as it has)
    for j in 1 .. cca.count loop
      if dbms_random.value < 0.08 then
        begin
          if dbms_random.value < 0.1 then
            -- abroad
            n := trunc(dbms_random.value(1, 5));
            e := bk_core.cc_purchase(cck(j), case n when 4 then round(dbms_random.value(1000, 30000)) else money(10, 250) end,
                   case n when 1 then 'Amazon US' when 2 then 'London hotel' when 3 then 'Zürich restaurant' else 'Tokyo shop' end,
                   case n when 1 then 'USD' when 2 then 'GBP' when 3 then 'CHF' else 'JPY' end);
          else
            e := bk_core.cc_purchase(cck(j), money(8, 250),
                   shop(case trunc(dbms_random.value(0, 6)) when 0 then 'σούπερ μάρκετ' when 1 then 'καύσιμα'
                     when 2 then 'ηλεκτρονικό κατάστημα' when 3 then 'εστιατόριο' when 4 then 'ρούχα' else 'αεροπορικά' end,
                     j + to_number(to_char(d, 'DDD'))));
          end if;
        exception when others then refused;
        end;
      end if;
      if dbms_random.value < 0.01 then
        begin
          n := bk_core.cc_authorize(cck(j), money(100, 400), 'ξενοδοχείο (εγγύηση)');
        exception when others then refused;
        end;
      end if;
      for s in (select closing, min_due from bk_cc_statement where account_id = cca(j) and due_date = d + 2 and closing > 0) loop
        -- one of the third ones forgets now and then
        if not (ccpay(j) = 2 and dbms_random.value < 0.25) then
          amt := case ccpay(j) when 0 then s.closing when 1 then s.min_due
                                else round(dbms_random.value(s.min_due, s.closing), 2) end;
          ccx := available(curacc(j * 3));
          amt := least(amt, trunc(ccx * 100) / 100);
          if amt > 0 then
            begin
              e := bk_core.cc_pay(cca(j), curacc(j * 3), amt, 'WEB');
            exception when others then refused;
            end;
          end if;
        end if;
      end loop;
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
  bk_core.set_branch_context(null);
  commit;
  select count(*) into n from bk_entry;
  dbms_output.put_line('== demo: ' || cust.count || ' customers, ' || acc.count || ' accounts, ' || cca.count
                       || ' credit cards, ' || lna.count || ' loans, ' || n || ' entries, ' || (last_day_ - first_day + 1)
                       || ' days closed');
end;
/
set serveroutput off
