-- BK_AI.sql -- the suspicious movements (Oracle Machine Learning, in the database): a model of anomaly detection
-- (One-Class SVM, DBMS_DATA_MINING) learns what is usual from the movements of the customers of the days closed;
-- each movement of a day gets the probability that it is NOT usual (PREDICTION_PROBABILITY(model, 0 USING *)),
-- and the ones over the threshold (the setting AI_THRESHOLD, 0.55) become alerts, with the reasons of the model
-- (PREDICTION_DETAILS: the features that weighed most) in Greek. A manager clears an alert (C: not a fraud) or
-- confirms it (F: a fraud; its account blocked).
--
-- The features of a movement (a line of an account of a customer; not the fees, the interest, the reversals):
--   KIND, CHANNEL, PRODUCT_KIND (CUR, SAV, CC, LN), DIRECTION (D out of the account, C in), FOREIGN_ (Y: in
--   another currency), HOUR (0 .. 23, of CREATED_AT), NIGHT (Y: before 6), DAY_COUNT (the movements of the account
--   that day), AMOUNT_BAND (the amount in euro: up to 100, 1.000, 5.000, more), RATIO_BAND (the amount against the
--   mean of the 30 before it of the account, the same direction: LOW under 0.3, USUAL, X3 over 3 times, X10 over 10)
--   (bands, not the numbers: with the numbers the model hardly saw an amount 20 times the usual one)
--
-- The model: bk_ai.train (ADMIN; it needs the privilege CREATE MINING MODEL: CREATE_USER.sql, or GRANT_AI.sql once
-- for a user made before). The scan: bk_ai.scan(day), by bk_core.close_day for the day it closes (nothing when
-- there is no model yet), or by hand (the form BK_AI, POST /api/ai/scan) for the business day.
create table if not exists bk_ai_alert (
  id           number generated always as identity constraint bk_ai_alert_pk primary key,
  line_id      number not null constraint bk_ai_alert_line_uk unique
                      constraint bk_ai_alert_line_fk references bk_line,
  entry_id     number not null,
  account_id   number not null constraint bk_ai_alert_account_fk references bk_account,
  score        number not null,                     -- the probability of an anomaly, 0 .. 1
  reasons      varchar2(400),                       -- in Greek, the strongest first
  details      varchar2(2000),                      -- PREDICTION_DETAILS as it was (XML)
  status       varchar2(1) default 'N' not null
               constraint bk_ai_alert_status_ck check (status in ('N', 'C', 'F')),   -- new, cleared, fraud
  created_at   date default sysdate not null,
  reviewed_by  varchar2(30),
  reviewed_at  date,
  note         varchar2(200)
);
create index if not exists bk_ai_alert_account_ix on bk_ai_alert (account_id);

create or replace view bk_ai_features as
select y.*,
       case when y.log_ratio > 2.3026 then 'X10' when y.log_ratio > 1.0986 then 'X3'
            when y.log_ratio < -1.204 then 'LOW' else 'USUAL' end ratio_band,
       case when y.amount < 100 then 'A100' when y.amount < 1000 then 'A1K' when y.amount < 5000 then 'A5K'
            else 'A5KP' end amount_band
from (
select x.line_id, x.entry_id, x.account_id, x.book_date, x.kind, x.channel, x.product_kind, x.direction, x.foreign_,
       x.amount, round(ln(1 + x.amount), 4) log_amount, x.hour,
       case when x.hour < 6 then 'Y' else 'N' end night,
       round(ln((1 + x.amount) / (1 + nvl(avg(x.amount) over (partition by x.account_id, x.direction order by x.line_id
                                                              rows between 30 preceding and 1 preceding), x.amount))), 4) log_ratio,
       count(*) over (partition by x.account_id, x.book_date) day_count
from (select l.id line_id, e.id entry_id, l.account_id, e.book_date, e.kind, e.channel, p.kind product_kind,
             case when l.debit > 0 then 'D' else 'C' end direction,
             case when e.orig_currency is not null then 'Y' else 'N' end foreign_,
             l.base_debit + l.base_credit amount, to_number(to_char(e.created_at, 'HH24')) hour
      from bk_line l, bk_entry e, bk_account a, bk_product p
      where e.id = l.entry_id and a.id = l.account_id and p.id = a.product_id
        and e.kind in ('DEP', 'WDR', 'TRF', 'OUT', 'INC', 'PUR') and nvl(l.op, '-') <> 'FEE') x) y;

-- the alerts with their movement and their account (the forms, the pages)
create or replace view bk_ai_alert_v as
select al.id, al.status, al.score, al.reasons, al.created_at, al.reviewed_by, al.reviewed_at, al.note,
       al.entry_id, al.line_id, al.account_id, e.book_date, to_char(e.created_at, 'HH24:MI') at_time, e.kind,
       e.channel, e.descr, l.debit + l.credit amount, l.currency, l.base_debit + l.base_credit amount_eur,
       case when l.debit > 0 then 'D' else 'C' end direction, e.orig_amount, e.orig_currency,
       a.iban, a.holder, a.status account_status, a.branch_code
from bk_ai_alert al, bk_line l, bk_entry e, bk_account_v a
where l.id = al.line_id and e.id = al.entry_id and a.id = al.account_id;

create or replace package bk_ai as
  c_model constant varchar2(30) := 'BK_AI_FRAUD';
  -- Y: there is a model
  function ready return varchar2;
  -- the model again, from the movements of the days closed (DDL: it commits); the movements it learned from back
  function train return number;
  -- the movements of a day (null: the business day) over the threshold: alerts (not twice); how many new
  function scan(p_day date default null) return number;
  -- an alert: C (not a fraud) or F (a fraud: p_block Y blocks its account)
  procedure review(p_alert_id number, p_status varchar2, p_note varchar2 default null, p_block varchar2 default 'Y');
  -- the threshold (AI_THRESHOLD, 0.55)
  function threshold return number;
  -- the model in a line: its algorithm, when, from how many, the threshold, the alerts open
  function model_info return varchar2;
  -- the reasons of PREDICTION_DETAILS in Greek, with the values of its movement
  function reasons_of(p_line_id number, p_details varchar2) return varchar2;
end bk_ai;
/

create or replace package body bk_ai as

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

  function money(p number) return varchar2 is
  begin
    return to_char(p, 'FM999G999G990D00', 'NLS_NUMERIC_CHARACTERS='',.''');
  end;

  function ready return varchar2 is
    n number;
  begin
    select count(*) into n from user_mining_models where model_name = c_model;
    return case when n > 0 then 'Y' else 'N' end;
  end;

  function threshold return number is
    v varchar2(400) := setting('AI_THRESHOLD');
  begin
    return nvl(to_number(v, '9D9999', 'NLS_NUMERIC_CHARACTERS=''.,'''), 0.55);
  exception
    when value_error or invalid_number then
      return 0.55;
  end;

  procedure set_(p_name varchar2, p_value varchar2) is
  begin
    merge into bk_setting s using (select p_name name, p_value value from dual) x on (s.name = x.name)
    when matched then update set s.value = x.value
    when not matched then insert (name, value) values (x.name, x.value);
  end;

  function train return number is
    s dbms_data_mining.setting_list;
    n number;
    d date := bk_core.open_day;
  begin
    select count(*) into n from bk_ai_features where book_date < d;
    if n < 200 then
      fail(70, 'Λίγες κινήσεις για να μάθει το μοντέλο: ' || n || ' (θέλει 200 και πάνω, από ημέρες που έκλεισαν)');
    end if;
    begin
      dbms_data_mining.drop_model(c_model, true);
    exception
      when others then
        null;
    end;
    s('ALGO_NAME') := 'ALGO_SUPPORT_VECTOR_MACHINES';
    s('PREP_AUTO') := 'ON';
    s('SVMS_OUTLIER_RATE') := '0.01';
    begin
      dbms_data_mining.create_model2(c_model, 'CLASSIFICATION',
        'select line_id, kind, channel, product_kind, direction, foreign_, hour, night, day_count, ratio_band, amount_band '
        || 'from bk_ai_features where book_date < date ''' || to_char(d, 'YYYY-MM-DD') || '''',
        s, 'LINE_ID', null);
    exception
      when others then
        if sqlcode = -1031 then
          fail(71, 'Ο χρήστης της τράπεζας δεν έχει το δικαίωμα CREATE MINING MODEL: db/GRANT_AI.sql μία φορά');
        end if;
        raise;
    end;
    set_('AI_TRAINED_ROWS', to_char(n));
    set_('AI_TRAINED_TO', to_char(d - 1, 'DD/MM/YYYY'));
    commit;
    return n;
  end;

  function reasons_of(p_line_id number, p_details varchar2) return varchar2 is
    f bk_ai_features%rowtype;
    e bk_entry%rowtype;
    nm varchar2(30);
    t varchar2(400);
    w varchar2(200);
    hour_done boolean := false;
  begin
    select * into f from bk_ai_features where line_id = p_line_id;
    select * into e from bk_entry where id = f.entry_id;
    for i in 1 .. 6 loop
      nm := regexp_substr(p_details, 'name="([A-Z_]+)"', 1, i, null, 1);
      exit when nm is null;
      w := case
             when nm in ('NIGHT', 'HOUR') and not hour_done then
               case when f.night = 'Y' then 'νυχτερινή ώρα ' else 'ώρα ' end || to_char(e.created_at, 'HH24:MI')
             when nm = 'FOREIGN_' and f.foreign_ = 'Y' then
               'σε ' || e.orig_currency || ' (' || money(e.orig_amount) || ')'
             when nm = 'FOREIGN_' then 'σε ευρώ'
             when nm in ('LOG_AMOUNT', 'AMOUNT_BAND') then 'ποσό ' || money(f.amount) || ' €'
             when nm in ('LOG_RATIO', 'RATIO_BAND') and f.log_ratio > 0.7 then
               round(exp(f.log_ratio)) || ' φορές το συνηθισμένο ποσό του λογαριασμού'
             when nm in ('LOG_RATIO', 'RATIO_BAND') then 'ασυνήθιστο ποσό για τον λογαριασμό'
             when nm = 'DAY_COUNT' then f.day_count || ' κινήσεις του λογαριασμού την ίδια ημέρα'
             when nm = 'CHANNEL' then 'από ' || case f.channel when 'BR' then 'γκισέ' when 'ATM' then 'ATM'
                                                      when 'WEB' then 'e-banking' else 'κάρτα' end
             when nm = 'KIND' then case f.kind when 'DEP' then 'κατάθεση' when 'WDR' then 'ανάληψη'
                                               when 'TRF' then 'μεταφορά' when 'OUT' then 'μεταφορά σε άλλη τράπεζα'
                                               when 'INC' then 'από άλλη τράπεζα' else 'αγορά με κάρτα' end
             when nm = 'PRODUCT_KIND' then case f.product_kind when 'CC' then 'πιστωτική κάρτα'
                                               when 'SAV' then 'λογαριασμός ταμιευτηρίου' when 'LN' then 'δάνειο'
                                               else 'τρεχούμενος λογαριασμός' end
             when nm = 'DIRECTION' then case f.direction when 'D' then 'χρέωση' else 'πίστωση' end
           end;
      if nm in ('NIGHT', 'HOUR') then
        hour_done := true;
      end if;
      if w is not null and (t is null or instr(t, w) = 0) then
        t := substr(t || case when t is not null then ' · ' end || w, 1, 400);
      end if;
    end loop;
    return t;
  exception
    when no_data_found then
      return null;
  end;

  function scan(p_day date default null) return number is
    d date := nvl(trunc(p_day), bk_core.open_day);
    n number;
  begin
    if ready = 'N' then
      return 0;
    end if;
    -- (USING *: SQL only, so dynamic; the model may not exist when this package is compiled)
    execute immediate
      'insert into bk_ai_alert (line_id, entry_id, account_id, score, details) '
      || 'select line_id, entry_id, account_id, score, details from ('
      || ' select f.line_id, f.entry_id, f.account_id, round(prediction_probability(' || c_model || ', 0 using *), 4) score,'
      || ' substr(prediction_details(' || c_model || ', 0, 5 using *), 1, 2000) details'
      || ' from bk_ai_features f where f.book_date = :d) x '
      || 'where x.score >= :t and not exists (select null from bk_ai_alert a where a.line_id = x.line_id)'
      using d, threshold;
    n := sql%rowcount;
    for a in (select id, line_id, details from bk_ai_alert where reasons is null) loop
      update bk_ai_alert set reasons = reasons_of(a.line_id, a.details) where id = a.id;
    end loop;
    return n;
  end;

  procedure review(p_alert_id number, p_status varchar2, p_note varchar2 default null, p_block varchar2 default 'Y') is
    a bk_ai_alert%rowtype;
    st varchar2(1);
  begin
    begin
      select * into a from bk_ai_alert where id = p_alert_id for update;
    exception
      when no_data_found then
        fail(72, 'Δεν υπάρχει ειδοποίηση ' || p_alert_id);
    end;
    if nvl(p_status, '-') not in ('C', 'F') then
      fail(73, 'Η ειδοποίηση: C (δεν είναι απάτη) ή F (απάτη)');
    end if;
    update bk_ai_alert set status = p_status, note = substr(p_note, 1, 200), reviewed_at = sysdate,
           reviewed_by = nvl(sys_context('userenv', 'client_identifier'), user)
    where id = p_alert_id;
    if p_status = 'F' and nvl(p_block, 'Y') = 'Y' then
      select status into st from bk_account where id = a.account_id;
      if st = 'O' then
        bk_core.set_status(a.account_id, 'B');
      end if;
    end if;
  end;

  function model_info return varchar2 is
    c date;
    n number;
  begin
    select count(*) into n from bk_ai_alert where status = 'N';
    if ready = 'N' then
      return 'Δεν υπάρχει μοντέλο ακόμα (Εκπαίδευση μοντέλου, ADMIN)  ·  ' || n || ' ανοιχτές ειδοποιήσεις';
    end if;
    select creation_date into c from user_mining_models where model_name = c_model;
    return 'One-Class SVM, ' || to_char(c, 'DD/MM/YYYY HH24:MI') || ', από ' || setting('AI_TRAINED_ROWS')
           || ' κινήσεις ως ' || setting('AI_TRAINED_TO') || '  ·  όριο '
           || to_char(threshold, 'FM0D00', 'NLS_NUMERIC_CHARACTERS='',.''') || '  ·  ' || n || ' ανοιχτές ειδοποιήσεις';
  end;
end bk_ai;
/
