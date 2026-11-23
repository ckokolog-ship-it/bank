-- BK_REPORT.sql -- the rows of the reports of the bank (reports/mkreports.py), and their Greek (the XML of a
-- report is ASCII, as the forms: its title, headings and words come from here when it runs).
--
--   P_KIND S  the statement of an account (BK_STATEMENT): its lines of the period by their book date, the
--             value date of each, debit, credit, the running balance; before them its balance before the period
--   P_KIND C  the statement of a credit card (BK_CC_STATEMENT, P_FROM .. P_TO its period): its lines as the
--             statement of an account, but the running balance what is owed (charges less payments); in the
--             heading the minimum to pay and its day
--   P_KIND L  the schedule of a loan (BK_LN_SCHEDULE): its installments due in the period, the interest as debit,
--             the principal as credit, the balance the principal left; before them its principal (less what was
--             paid of it before the period); under the title its principal, months, rate and day
--   P_KIND I  its interest (BK_INTEREST): the stretches of the period (balance x rate x days / days of the year)
--             as credit, the capitalizations as debit (gross; its tax in the words), the running balance: the
--             interest accrued and not capitalized yet; before them the accrued before the period
--
-- report_rows: the rows with what was before each one in the period (PRIOR_*) and up to it (CUM_*): the first
-- PRIOR_ of a page is its "from the carry-over" (από μεταφορά), the last CUM_ and BALANCE its "to the carry-over"
-- (σε μεταφορά). With no row in the period: one row, the balance before it. The interest of an account is
-- counted when it is needed (bk_core.accrue): the form accrues it before it opens the report.
create or replace package bk_report as
  type t_rrow is record (
    seq            number,
    ldate          date,
    doc_text       varchar2(40),     -- S: the value date; I: the last day of the stretch
    descr          varchar2(300),
    debit          number,
    credit         number,
    balance        number,
    prior_debit    number,           -- the totals of the period before this row
    prior_credit   number,
    prior_balance  number,
    cum_debit      number,           -- ... with it
    cum_credit     number);
  type t_rrows is table of t_rrow;
  function report_rows(p_kind varchar2, p_account_id number, p_from date, p_to date) return t_rrows pipelined;
  -- the title of a report (its account: IBAN, holder, product) and the words of it
  function title(p_kind varchar2, p_account_id number) return varchar2;
  function label(p_key varchar2, p_kind varchar2 default null) return varchar2;
  -- the line under the title: the period (C: the statement of that day, its minimum and its due date)
  function period(p_kind varchar2, p_account_id number, p_from date, p_to date) return varchar2;
end bk_report;
/

create or replace package body bk_report as

  function money(p number, p_scale pls_integer default 2) return varchar2 is
  begin
    return to_char(p, 'FM999G999G990D' || rpad('0', p_scale, '0'), 'NLS_NUMERIC_CHARACTERS='',.''');
  end;

  function kind_text(p_kind varchar2, p_op varchar2) return varchar2 is
  begin
    return case when p_op = 'FEE' then 'Προμήθεια'
                else case p_kind when 'DEP' then 'Κατάθεση' when 'WDR' then 'Ανάληψη' when 'TRF' then 'Μεταφορά'
                                 when 'OUT' then 'Σε άλλη τράπεζα' when 'INC' then 'Από άλλη τράπεζα'
                                 when 'INT' then 'Τόκοι' when 'REV' then 'Αντιλογισμός' when 'PUR' then 'Αγορά με κάρτα'
                                 when 'FEE' then 'Προμήθεια' else p_kind end end;
  end;

  function report_rows(p_kind varchar2, p_account_id number, p_from date, p_to date) return t_rrows pipelined is
    r t_rrow;
    prev number := 0;
    dsum number := 0;
    csum number := 0;
    n pls_integer := 0;
    a number;
    k varchar2(1) := upper(p_kind);
    sg number := case when upper(p_kind) = 'C' then -1 else 1 end;     -- (C: the balance what is owed)

    procedure out_(p_date date, p_doc varchar2, p_descr varchar2, p_debit number, p_credit number) is
    begin
      n := n + 1;
      r.seq := n;
      r.ldate := p_date;
      r.doc_text := p_doc;
      r.descr := substr(p_descr, 1, 300);
      r.debit := p_debit;
      r.credit := p_credit;
      r.prior_debit := dsum;
      r.prior_credit := csum;
      r.prior_balance := prev;
      dsum := dsum + nvl(p_debit, 0);
      csum := csum + nvl(p_credit, 0);
      if k = 'L' then
        prev := prev - nvl(p_credit, 0);                   -- (L: the principal left)
      else
        prev := prev + sg * (nvl(p_credit, 0) - nvl(p_debit, 0));
      end if;
      r.balance := prev;
      r.cum_debit := dsum;
      r.cum_credit := csum;
    end;
  begin
    select count(*) into a from bk_account where id = p_account_id;
    if a = 0 then
      raise_application_error(-20108, 'BK-108: Δεν υπάρχει λογαριασμός ' || p_account_id);
    end if;
    if k in ('S', 'C') then
      -- its balance before the period (its lines by their book date), then its lines of the period
      select sg * nvl(sum(l.credit - l.debit), 0) into prev
      from bk_line l join bk_entry e on e.id = l.entry_id
      where l.account_id = p_account_id and e.book_date < trunc(p_from);
      for x in (select e.book_date, e.value_date, e.kind, l.op, e.descr, e.id, l.debit, l.credit,
                       e.orig_amount, e.orig_currency, e.fx_rate,
                       (select 'Y' from bk_entry v where v.reversal_of = e.id) reversed
                from bk_line l join bk_entry e on e.id = l.entry_id
                where l.account_id = p_account_id and e.book_date between trunc(p_from) and trunc(p_to)
                order by e.book_date, e.id, l.id) loop
        out_(x.book_date, to_char(x.value_date, 'DD/MM/YYYY'),
             '#' || x.id || ' ' || case when x.kind = 'PUR' and x.descr is not null and nvl(x.op, '-') <> 'FEE' then x.descr     -- (Αγορά: ...)
                                        else kind_text(x.kind, x.op) || case when x.descr is not null then ': ' || x.descr end end
             -- (in another currency: the amount it was in, at its rate)
             || case when x.orig_currency is not null and nvl(x.op, '-') <> 'FEE' then ' (' || money(x.orig_amount) || ' '
                       || x.orig_currency || ' × ' || rtrim(rtrim(money(x.fx_rate, 6), '0'), ',') || ')' end
             || case when x.reversed = 'Y' then ' (αντιλογίστηκε)' end,
             nullif(x.debit, 0), nullif(x.credit, 0));
        pipe row (r);
      end loop;
    elsif k = 'I' then
      -- the interest accrued before the period (its stretches that ended before it, less what was capitalized),
      -- then its stretches and its capitalizations of the period, by their day
      select nvl(sum(interest), 0) into prev from bk_accrual where account_id = p_account_id and day_to < trunc(p_from);
      select prev - nvl(sum(gross), 0) into prev from bk_capital where account_id = p_account_id and day < trunc(p_from);
      for x in (select day_from d, 0 o, day_to, balance, rate, days, year_days, interest, null gross, null tax
                from bk_accrual where account_id = p_account_id and day_to >= trunc(p_from) and day_from <= trunc(p_to)
                union all
                select day, 1, null, null, null, null, null, null, gross, tax
                from bk_capital where account_id = p_account_id and day between trunc(p_from) and trunc(p_to)
                order by 1, 2) loop
        if x.o = 0 then
          out_(x.d, to_char(x.day_to, 'DD/MM/YYYY'),
               money(x.balance) || ' € × ' || rtrim(rtrim(money(x.rate, 4), '0'), ',') || '% × ' || x.days || '/' || x.year_days,
               null, x.interest);
        else
          out_(x.d, null, 'Κεφαλαιοποίηση: φόρος ' || money(x.tax) || ' €, καθαρός ' || money(x.gross - x.tax) || ' €',
               x.gross, null);
        end if;
        pipe row (r);
      end loop;
    elsif k = 'L' then
      select count(*) into a from bk_loan where account_id = p_account_id;
      if a = 0 then
        raise_application_error(-20155, 'BK-155: Ο λογαριασμός ' || p_account_id || ' δεν είναι δανείου');
      end if;
      -- its principal, less the principal of the installments before the period
      select l.principal - nvl((select sum(s.principal) from bk_ln_schedule s
                                where s.account_id = l.account_id and s.due_date < trunc(p_from)), 0)
      into prev from bk_loan l where l.account_id = p_account_id;
      for x in (select n, due_date, rate, principal, interest, payment, balance, status, paid, paid_on, late_fee, late_booked
                from bk_ln_schedule where account_id = p_account_id and due_date between trunc(p_from) and trunc(p_to)
                order by n) loop
        out_(x.due_date, 'Δόση ' || x.n,
             money(x.payment) || ' € · ' || rtrim(rtrim(money(x.rate, 4), '0'), ',') || '% · '
             || case x.status when 'D' then 'θα έρθει' when 'O' then 'οφείλεται'
                              when 'L' then 'σε καθυστέρηση' || case when x.late_fee > 0 then ', τέλος ' || money(x.late_fee) || ' €' end
                                            || case when x.late_booked > 0 then ', τόκοι υπερημερίας ' || money(x.late_booked) || ' €' end
                              else 'πληρώθηκε ' || to_char(x.paid_on, 'DD/MM/YYYY')
                                   || case when x.late_fee > 0 then ' (με τέλος ' || money(x.late_fee) || ' €)' end end
             || case when x.status in ('O', 'L') and x.paid > 0 then ', πληρώθηκαν ' || money(x.paid) || ' €' end,
             nullif(x.interest, 0), x.principal);
        pipe row (r);
      end loop;
    else
      raise_application_error(-20145, 'BK-145: Καρτέλα (S), τόκοι (I), κίνηση κάρτας (C) ή δάνειο (L)');
    end if;
    if n = 0 then
      -- nothing in the period: the balance before it, alone
      out_(trunc(p_from), null, label('OPEN', k), null, null);
      pipe row (r);
    end if;
    return;
  end;

  function title(p_kind varchar2, p_account_id number) return varchar2 is
    t varchar2(300);
  begin
    select a.iban || '  ·  ' || a.holder || '  ·  ' || a.product_name || '  ·  ' || a.currency into t
    from bk_account_v a where a.id = p_account_id;
    return case upper(p_kind) when 'I' then 'Τόκοι λογαριασμού ' when 'C' then 'Κίνηση πιστωτικής κάρτας '
                              when 'L' then 'Πρόγραμμα αποπληρωμής δανείου '
                              else 'Καρτέλα λογαριασμού ' end || t;
  exception
    when no_data_found then
      return p_account_id;
  end;

  function label(p_key varchar2, p_kind varchar2 default null) return varchar2 is
    i boolean := upper(p_kind) = 'I';
  begin
    if upper(p_kind) = 'L' then
      return case upper(p_key)
        when 'DATE' then 'Λήξη' when 'DOC' then 'Δόση' when 'DESCR' then 'Ποσό · επιτόκιο · κατάσταση'
        when 'DEBIT' then 'Τόκος' when 'CREDIT' then 'Κεφάλαιο' when 'BALANCE' then 'Υπόλοιπο κεφαλαίου'
        when 'OPEN' then 'Κεφάλαιο στην αρχή' when 'CLOSE' then 'Κεφάλαιο στο τέλος'
        else label(p_key) end;
    end if;
    if upper(p_kind) = 'C' then
      return case upper(p_key)
        when 'DATE' then 'Ημερομηνία' when 'DOC' then 'Αξία' when 'DESCR' then 'Περιγραφή'
        when 'DEBIT' then 'Χρεώσεις' when 'CREDIT' then 'Πληρωμές' when 'BALANCE' then 'Οφειλή'
        when 'OPEN' then 'Προηγούμενο υπόλοιπο' when 'CLOSE' then 'Νέο υπόλοιπο'
        else label(p_key) end;
    end if;
    return case upper(p_key)
      when 'DATE' then case when i then 'Από' else 'Λογισμός' end
      when 'DOC' then case when i then 'Έως' else 'Αξία' end
      when 'DESCR' then case when i then 'Υπόλοιπο × επιτόκιο × ημέρες / έτος' else 'Περιγραφή' end
      when 'DEBIT' then case when i then 'Κεφαλαιοποίηση' else 'Χρέωση' end
      when 'CREDIT' then case when i then 'Τόκος' else 'Πίστωση' end
      when 'BALANCE' then case when i then 'Δεδουλευμένοι' else 'Υπόλοιπο' end
      when 'FROM_CARRY' then 'Από μεταφορά'
      when 'TO_CARRY' then 'Σε μεταφορά'
      when 'TOTALS' then 'Σύνολα περιόδου'
      when 'OPEN' then case when i then 'Δεδουλευμένοι πριν από την περίοδο' else 'Από προηγούμενη περίοδο' end
      when 'CLOSE' then case when i then 'Δεδουλευμένοι στο τέλος' else 'Γενικό υπόλοιπο' end
      when 'PAGE' then 'Σελίδα'
      when 'PERIOD' then 'Διάστημα'
      else p_key end;
  end;

  function period(p_kind varchar2, p_account_id number, p_from date, p_to date) return varchar2 is
    s bk_cc_statement%rowtype;
    lim number;
    l bk_loan%rowtype;
    rt varchar2(1);
  begin
    if upper(p_kind) = 'L' then
      begin
        select * into l from bk_loan where account_id = p_account_id;
        select x.rate_type into rt from bk_ln_product x join bk_account a on a.product_id = x.product_id where a.id = p_account_id;
        return 'Κεφάλαιο ' || money(l.principal) || ' € σε ' || l.months || ' μήνες, από ' || to_char(l.start_date, 'DD/MM/YYYY')
               || '  ·  ' || case rt when 'V' then 'κυμαινόμενο' else 'σταθερό' end || ' επιτόκιο, τώρα '
               || rtrim(rtrim(money(l.rate, 4), '0'), ',') || '%  ·  δόση στις ' || l.pay_day || ' του μήνα'
               || case when l.status = 'C' then '  ·  εξοφλήθηκε' end;
      exception
        when no_data_found then
          null;
      end;
    end if;
    if upper(p_kind) = 'C' then
      begin
        select * into s from bk_cc_statement where account_id = p_account_id and stmt_date = trunc(p_to);
        select credit_limit into lim from bk_ccard where account_id = p_account_id;
        return 'Κίνηση της ' || to_char(s.stmt_date, 'DD/MM/YYYY') || ' (από ' || to_char(s.period_from, 'DD/MM/YYYY')
               || ')  ·  Ελάχιστη καταβολή ' || money(s.min_due) || ' € ως ' || to_char(s.due_date, 'DD/MM/YYYY')
               || '  ·  Όριο ' || money(lim) || ' €';
      exception
        when no_data_found then
          null;
      end;
    end if;
    return label('PERIOD') || ': ' || to_char(p_from, 'DD/MM/YYYY') || ' - ' || to_char(p_to, 'DD/MM/YYYY');
  end;
end bk_report;
/
