-- BK_AI_DEMO.sql -- INSTALL.sql demo: the suspicious movements, made up, once (the setting AI_DEMO; also on a
-- database whose demo was made before). First the hours of the movements of the days closed spread as a bank has
-- them (the counter 8:30 - 14:30, the ATM and the e-banking from the morning to midnight, the cards 9:00 - 22:00,
-- the bank itself at its close, 23:30); the model learns from them (bk_ai.train). Then on the business day a few
-- movements it should find strange, and a few usual ones, and the scan of the day (bk_ai.scan):
--   a card: 2.900 USD on the internet at 03:12;
--   an account: 3 withdrawals from the ATM between 02:00 and 03:00;
--   an account: 4.800 € to another bank from the e-banking at 04:37;
--   a savings account: 18.000 € in cash at the counter;
--   the usual: a supermarket at 13:20, a restaurant at 19:05, 50 € from the ATM at 18:10, 120 € by e-banking at 20:30.
-- Without the privilege CREATE MINING MODEL (db/GRANT_AI.sql): it says so and stops; INSTALL.sql demo again after it.
set serveroutput on
declare
  d date := bk_core.open_day;
  n number;
  rows_ number;
  e number;
  k1 number;
  k2 number;
  a1 number;
  a2 number;
  a3 number;
  a4 number;
  a5 number;

  procedure at_(p_entry number, p_hhmi varchar2) is
  begin
    update bk_entry set created_at = book_date + (to_number(substr(p_hhmi, 1, 2)) + to_number(substr(p_hhmi, 4, 2)) / 60) / 24
    where id = p_entry;
  end;

  procedure said(p_what varchar2) is
  begin
    dbms_output.put_line('   (' || p_what || ': ' || substr(sqlerrm, 1, 160) || ')');
  end;

  function cur_acc(p_min number, p_not1 number default -1, p_not2 number default -1, p_kind varchar2 default 'CUR') return number is
    r number;
  begin
    select min(a.id) into r from bk_account a, bk_product p
    where p.id = a.product_id and p.kind = p_kind and a.status = 'O' and a.currency = 'EUR' and a.balance >= p_min
      and a.id not in (p_not1, p_not2);
    return r;
  end;
begin
  select count(*) into n from bk_setting where name = 'AI_DEMO' and value = 'Y';
  if n > 0 then
    dbms_output.put_line('== AI demo: made before');
    return;
  end if;
  select count(*) into n from bk_entry where book_date < d;
  if n < 1000 then
    dbms_output.put_line('== AI demo: not enough movements of the demo');
    return;
  end if;
  dbms_random.seed(26);
  update bk_entry set created_at = book_date + case channel
           when 'BR' then dbms_random.value(8.5, 14.5)
           when 'ATM' then dbms_random.value(7, 23.5)
           when 'WEB' then dbms_random.value(7, 23.9)
           else case kind when 'PUR' then dbms_random.value(9, 22) else 23.5 end end / 24
  where book_date < d;
  commit;
  begin
    rows_ := bk_ai.train;
  exception
    when others then
      if sqlcode = -20171 then
        dbms_output.put_line('== AI demo: ' || sqlerrm);
        dbms_output.put_line('== then INSTALL.sql demo again');
        return;
      end if;
      raise;
  end;
  bk_core.set_branch_context('0001');
  -- the cards: the one with the most room, and another
  select max(k.id) keep (dense_rank last order by c.credit_limit + a.balance - c.held, k.id) into k1
  from bk_card k, bk_ccard c, bk_account a where c.account_id = k.account_id and a.id = k.account_id and k.status = 'A';
  select max(k.id) keep (dense_rank last order by c.credit_limit + a.balance - c.held, k.id) into k2
  from bk_card k, bk_ccard c, bk_account a where c.account_id = k.account_id and a.id = k.account_id and k.status = 'A'
    and k.id <> k1;
  begin
    e := bk_core.cc_purchase(k1, 2900, 'ηλεκτρονικά (εξωτερικό)', 'USD');
    at_(e, '03:12');
  exception when others then
    begin
      e := bk_core.cc_purchase(k1, 900, 'ηλεκτρονικά (εξωτερικό)', 'USD');
      at_(e, '03:12');
    exception when others then said('2.900 USD');
    end;
  end;
  begin
    e := bk_core.cc_purchase(k2, 24.90, 'σούπερ μάρκετ');
    at_(e, '13:20');
    e := bk_core.cc_purchase(k2, 61.30, 'εστιατόριο');
    at_(e, '19:05');
  exception when others then said('οι αγορές');
  end;
  a1 := cur_acc(2000);
  a2 := cur_acc(6000, a1);
  a3 := cur_acc(0, a1, a2, 'SAV');
  a4 := cur_acc(500, a1, a2);
  select min(id) into a5 from bk_account a where a.status = 'O' and a.currency = 'EUR' and a.id not in (a1, a2, a3, a4)
    and a.product_id in (select id from bk_product where kind = 'CUR');
  for i in 1 .. 3 loop
    begin
      e := bk_core.withdraw(a1, 200, null, null, 'ATM');
      at_(e, '02:' || to_char(i * 17 - 12, 'FM00'));
    exception when others then said('ATM');
    end;
  end loop;
  begin
    e := bk_core.transfer_out(a2, 4800, 'GR9608100010000001234567890', 'Μεταφορά', null, 'WEB');
    at_(e, '04:37');
  exception when others then said('4.800 €');
  end;
  begin
    e := bk_core.deposit(a3, 18000, 'Κατάθεση μετρητών');
    at_(e, '11:05');
  exception when others then said('18.000 €');
  end;
  begin
    e := bk_core.withdraw(a4, 50, null, null, 'ATM');
    at_(e, '18:10');
    e := bk_core.transfer(a4, a5, 120, 'Μεταφορά', null, 'WEB');
    at_(e, '20:30');
  exception when others then said('τα συνηθισμένα');
  end;
  bk_core.set_branch_context(null);
  n := bk_ai.scan(d);
  insert into bk_setting (name, value) values ('AI_DEMO', 'Y');
  commit;
  dbms_output.put_line('== AI demo: a model from ' || rows_ || ' movements; ' || n || ' alerts on '
                       || to_char(d, 'DD/MM/YYYY'));
end;
/
set serveroutput off
