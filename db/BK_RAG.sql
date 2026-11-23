-- BK_RAG.sql -- the assistant of the teller (RAG: retrieval-augmented generation, all in the database): a question
-- in Greek; the pieces of knowledge nearest in meaning to it (AI Vector Search: the model of embeddings BK_EMBED of
-- BK_VECTOR.sql); a language model (an LLM: Ollama on the same server, gemma3:4b) writes the answer from them only,
-- with their numbers ([1], [2]) as its sources: DBMS_VECTOR.UTL_TO_GENERATE_TEXT.
--
-- The knowledge (BK_AI_DOC): (a) the facts of the bank as they are now, made from its tables: each product (its
-- rates, its interest, its card or loan terms), each rule of the bank and of a product (allowed or not, its limits,
-- its fee); (b) the guides of the repo (docs/ODIGIES_*.md, from the directory BK_DOCS: GRANT_AI.sql), in pieces
-- (DBMS_VECTOR.UTL_TO_CHUNKS). Each piece with its vector. bk_rag.refresh makes them again (LOAD_EMBED.sql, the
-- form, the page: when the products or the rules changed).
--
-- The language model: the settings AI_LLM_URL (http://localhost:11434/api/generate), AI_LLM_MODEL (gemma3:4b),
-- AI_LLM_TIMEOUT (300 seconds: "transfer_timeout" of UTL_TO_GENERATE_TEXT); the database may call it (an ACL: GRANT_AI.sql). Without it (not running, no ACL):
-- the answer says so, and the pieces found are there all the same.
-- How much the model reads and writes (on a CPU the time of an answer is mostly its reading of the pieces):
-- AI_RAG_FACTS (2) and AI_RAG_DOCS (2) the pieces of each kind, AI_RAG_CHARS (600) the characters of each,
-- AI_LLM_MAX_TOKENS (200) the answer at most, AI_LLM_CTX (2048) its context, AI_LLM_KEEP_ALIVE (24h) the model kept
-- loaded by Ollama between the questions.
create table if not exists bk_ai_doc (
  id      number generated always as identity constraint bk_ai_doc_pk primary key,
  source  varchar2(100) not null,           -- DB:... (the facts) or the file
  title   varchar2(300),
  text    varchar2(4000) not null,
  vec     vector(384, float32)
);

-- every question: who, when, the answer, how long, the model, an error
create table if not exists bk_ai_question (
  id        number generated always as identity constraint bk_ai_question_pk primary key,
  asked_by  varchar2(30),
  asked_at  date default sysdate not null,
  question  varchar2(1000) not null,
  answer    clob,
  model     varchar2(60),
  ms        number,
  error     varchar2(1000)
);

-- its sources: the pieces given to the model, by their number in the prompt
create table if not exists bk_ai_question_src (
  question_id  number not null constraint bk_ai_qsrc_q_fk references bk_ai_question on delete cascade,
  n            number not null,
  doc_id       number,
  source       varchar2(100),
  title        varchar2(300),
  text         varchar2(4000),
  similarity   number,
  constraint bk_ai_qsrc_pk primary key (question_id, n)
);

create or replace package bk_rag as
  -- the knowledge again: the facts of the bank, the guides of BK_DOCS, their vectors; the pieces back
  function refresh(p_dir varchar2 default 'BK_DOCS') return number;
  -- a question: its answer (and its sources: BK_AI_QUESTION_SRC); the id of it back
  -- (p_k: the pieces, half facts and half guides; null: AI_RAG_FACTS and AI_RAG_DOCS)
  function ask(p_question varchar2, p_k number default null) return number;
  -- the facts of the bank in Greek sentences (refresh puts them in BK_AI_DOC): how many
  function facts return number;
  -- the assistant in a line: the model, the pieces of knowledge
  function info return varchar2;
end bk_rag;
/

create or replace package body bk_rag as

  c_files constant varchar2(400) := 'ODIGIES_VASI.md,ODIGIES_ATM.md,ODIGIES_KARTES.md,ODIGIES_DANEIA.md,'
                                    || 'ODIGIES_NOMISMATA.md,ODIGIES_YPOKATASTIMATA.md,ODIGIES_WEB.md,ODIGIES_FORMS.md,'
                                    || 'ODIGIES_REPORTS.md,ODIGIES_AI.md';

  function setting(p_name varchar2, p_default varchar2) return varchar2 is
    v varchar2(400);
  begin
    select max(value) into v from bk_setting where name = p_name;
    return nvl(v, p_default);
  end;

  function money(p number) return varchar2 is
  begin
    return to_char(p, 'FM999G999G990D00', 'NLS_NUMERIC_CHARACTERS='',.''') || ' €';
  end;

  function num(p number) return varchar2 is
  begin
    return to_char(p, 'FM999G999G990D00', 'NLS_NUMERIC_CHARACTERS='',.''');
  end;

  function pct(p number) return varchar2 is
  begin
    return rtrim(rtrim(to_char(p, 'FM990D9999', 'NLS_NUMERIC_CHARACTERS='',.'''), '0'), ',') || '%';
  end;

  procedure add_(p_source varchar2, p_title varchar2, p_text varchar2) is
  begin
    insert into bk_ai_doc (source, title, text) values (p_source, substr(p_title, 1, 300), substr(p_text, 1, 4000));
  end;

  function op_text(p_op varchar2) return varchar2 is
  begin
    return case p_op when 'DEP' then 'κατάθεση' when 'WDR' then 'ανάληψη' when 'TRO' then 'μεταφορά προς άλλον λογαριασμό της τράπεζας'
                     when 'TRI' then 'μεταφορά από άλλον λογαριασμό της τράπεζας' when 'OUT' then 'μεταφορά σε άλλη τράπεζα'
                     when 'INC' then 'μεταφορά από άλλη τράπεζα' else p_op end;
  end;

  function channel_text(p_ch varchar2) return varchar2 is
  begin
    return case p_ch when 'BR' then 'στο γκισέ' when 'WEB' then 'από το e-banking' when 'ATM' then 'από ATM'
                     else 'από όλα τα κανάλια (γκισέ, e-banking, ATM)' end;
  end;

  function facts return number is
    n number := 0;
    t varchar2(4000);
    r varchar2(2000);
    d date;
  begin
    begin
      d := bk_core.open_day;
    exception
      when others then
        d := null;                -- (no business day yet: BK-101)
    end;
    delete from bk_ai_doc where source like 'DB:%';
    -- the products: what they are, their interest, their rates now (by the balance from which each holds)
    for p in (select p.*, cast(null as varchar2(2000)) rates
              from bk_product p order by p.id) loop
      t := 'Το προϊόν ' || p.code || ' «' || p.name || '» είναι '
           || case p.kind when 'CUR' then 'λογαριασμός όψεως' when 'SAV' then 'λογαριασμός ταμιευτηρίου'
                          when 'CC' then 'πιστωτική κάρτα' when 'LN' then 'δάνειο' else p.kind end
           || case when p.active = 'N' then ' (δεν ανοίγει πια)' end || ', σε ' || replace(p.currencies, ',', ', ') || '.';
      if p.kind in ('CUR', 'SAV') then
        -- its rates now, each currency by its steps as ranges (a small model reads "from 5.000 to 19.999,99" right,
        -- "from 5.000" and "from 20.000" not always)
        r := null;
        for x in (select currency, min_balance, rate,
                         lead(min_balance) over (partition by currency order by min_balance) upto
                  from bk_rate b where product_id = p.id
                    and valid_from = (select max(y.valid_from) from bk_rate y where y.product_id = b.product_id
                                      and y.currency = b.currency and y.min_balance = b.min_balance
                                      and y.valid_from <= nvl(d, trunc(sysdate)))
                  order by case currency when 'EUR' then 0 else 1 end, currency, min_balance) loop
          r := r || case when r is not null then '; ' end || pct(x.rate) || ' σε ' || x.currency
               || case when x.upto is not null and x.min_balance = 0 then ' για υπόλοιπο έως ' || num(x.upto - 0.01)
                       when x.upto is not null then ' για υπόλοιπο από ' || num(x.min_balance) || ' έως ' || num(x.upto - 0.01)
                       when x.min_balance > 0 then ' για υπόλοιπο από ' || num(x.min_balance) || ' και πάνω'
                       else ' για κάθε υπόλοιπο' end;
        end loop;
        t := t || ' Επιτόκιο καταθέσεων τώρα (ετήσιο): ' || nvl(r, 'κανένα') || '. Οι τόκοι μετρούν κάθε ημέρα ('
             || p.day_basis || ') και κεφαλαιοποιούνται '
             || case p.cap_every when 'M' then 'κάθε μήνα' when 'Q' then 'κάθε τρίμηνο' when 'Y' then 'κάθε χρόνο' else p.cap_every end
             || ', με φόρο τόκων ' || pct(p.tax_rate) || '. Επιτόκιο υπερανάληψης: ' || pct(p.od_rate) || '.';
      end if;
      for c in (select * from bk_cc_product where product_id = p.id) loop
        t := t || ' Επιτόκιο ' || pct(c.rate) || ' τον χρόνο. Ελάχιστη καταβολή κάθε μήνα το ' || pct(c.min_pct)
             || ' της οφειλής, τουλάχιστον ' || money(c.min_amount) || ', μέσα σε ' || c.due_days
             || ' ημέρες από την κίνηση. Τέλος καθυστέρησης ' || money(c.late_fee) || '. Αγορές σε ξένο νόμισμα: προμήθεια '
             || pct(c.fx_fee_pct) || '. Χωρίς τόκους όταν η προηγούμενη κίνηση εξοφλήθηκε ολόκληρη ως τη λήξη της.';
      end loop;
      for l in (select * from bk_ln_product where product_id = p.id) loop
        t := t || case l.rate_type when 'V' then ' Κυμαινόμενο επιτόκιο: ' || l.index_code || ' + ' || pct(l.rate)
                                    || ', αλλάζει κάθε ' || l.reset_months || ' μήνες.'
                                   else ' Σταθερό επιτόκιο ' || pct(l.rate) || '.' end
             || ' Έως ' || l.max_months || ' μήνες. Δόση σε καθυστέρηση: μετά από ' || l.grace_days || ' ημέρες τέλος '
             || money(l.late_fee) || ' και τόκοι υπερημερίας (επιτόκιο + ' || pct(l.late_add) || '). Πρόωρη εξόφληση: προμήθεια '
             || pct(l.prepay_pct) || ' του ποσού.';
      end loop;
      add_('DB:product', 'Προϊόν ' || p.code || ' ' || p.name, t);
      n := n + 1;
    end loop;
    -- the rules of the bank and of the products (not of one account): each one a sentence
    for r in (select * from bk_rule_v where lvl in ('BANK', 'PRODUCT') order by lvl, product, op, channel) loop
      t := 'Κανόνας ' || case when r.lvl = 'BANK' then 'για όλους τους λογαριασμούς' else 'για το προϊόν ' || r.product end
           || ': ' || op_text(r.op) || ' ' || channel_text(r.channel) || ': '
           || case when r.allowed = 'N' then 'δεν επιτρέπεται.'
                   else rtrim(case when r.allowed = 'Y' then 'επιτρέπεται, ' end
                        || case when r.min_amount is not null then 'ελάχιστο ποσό ' || money(r.min_amount) || ', ' end
                        || case when r.max_amount is not null then 'μέγιστο ποσό ' || money(r.max_amount) || ' τη φορά, ' end
                        || case when r.day_amount is not null then 'έως ' || money(r.day_amount) || ' την ημέρα, ' end
                        || case when r.day_count is not null then 'έως ' || r.day_count || ' φορές την ημέρα, ' end
                        || case when r.month_amount is not null then 'έως ' || money(r.month_amount) || ' τον μήνα, ' end
                        || case when r.month_count is not null then 'έως ' || r.month_count || ' φορές τον μήνα, ' end
                        || case when r.fee is not null then 'προμήθεια ' || money(r.fee)
                                || case when r.free_month is not null then ' μετά τις ' || r.free_month || ' δωρεάν τον μήνα' end || ', '
                                when r.free_month is not null then r.free_month || ' δωρεάν τον μήνα, ' end
                        || case when r.min_balance is not null then 'να μένει υπόλοιπο τουλάχιστον ' || money(r.min_balance) || ', ' end,
                        ', ') || '.' end;
      add_('DB:rule', 'Κανόνας ' || nvl(r.product, 'τράπεζας') || ' ' || r.op || ' ' || r.channel, t);
      n := n + 1;
    end loop;
    select listagg(code || ' ' || name || nvl2(city, ' (' || city || ')', null), ', ') within group (order by code) into t
    from bk_branch where active = 'Y';
    add_('DB:bank', 'Η τράπεζα', case when d is not null then 'Η εργάσιμη ημέρα της τράπεζας είναι η '
                                      || to_char(d, 'DD/MM/YYYY') || '. ' end || 'Βασικό νόμισμα: '
         || setting('BASE_CURRENCY', 'EUR') || '. Υποκαταστήματα: ' || t || '.');
    return n + 1;
  end;

  -- a guide of the repo in pieces: each section of it (a heading #, ##, ###; not a # in a block of code) one piece
  -- with its heading, a long one cut by DBMS_VECTOR.UTL_TO_CHUNKS (by words), each part with the same heading (pieces
  -- cut through the sections lost the sentence asked about, or had the heading of the section before)
  function load_file(p_dir varchar2, p_file varchar2) return number is
    c clob;
    f bfile := bfilename(p_dir, p_file);
    dst integer := 1;
    src integer := 1;
    ctx integer := dbms_lob.default_lang_ctx;
    warn integer;
    n number := 0;
    pos integer := 1;
    nl integer;
    len integer;
    line varchar2(4000);
    title varchar2(300);
    buf varchar2(32767);
    fence boolean := false;

    procedure flush is
    begin
      -- (a heading with nothing under it: not a piece)
      if buf is null or length(trim(buf)) - length(nvl(title, '')) < 40 then
        return;
      end if;
      if regexp_count(buf, '[^[:space:]]+') <= 110 then
        add_(p_file, title, substr(buf, 1, 4000));
        n := n + 1;
      else
        for x in (select jt.data
                  from table(dbms_vector.utl_to_chunks(to_clob(buf),
                         json('{"by":"words","max":"90","overlap":"10","split":"recursively","normalize":"all"}'))) k,
                       json_table(k.column_value, '$' columns (data varchar2(4000) path '$.chunk_data')) jt) loop
          add_(p_file, title, x.data);
          n := n + 1;
        end loop;
      end if;
    end;
  begin
    if dbms_lob.fileexists(f) = 0 then
      return 0;
    end if;
    dbms_lob.createtemporary(c, true);
    dbms_lob.fileopen(f, dbms_lob.file_readonly);
    dbms_lob.loadclobfromfile(c, f, dbms_lob.lobmaxsize, dst, src, nls_charset_id('AL32UTF8'), ctx, warn);
    dbms_lob.fileclose(f);
    len := dbms_lob.getlength(c);
    while pos <= len loop
      nl := dbms_lob.instr(c, chr(10), pos);
      if nl = 0 then
        nl := len + 1;
      end if;
      line := dbms_lob.substr(c, least(nl - pos, 4000), pos);
      pos := nl + 1;
      if line like '```%' then
        fence := not fence;
      end if;
      if not fence and regexp_like(line, '^#{1,4} ') then
        flush;
        title := substr(trim(ltrim(line, '# ')), 1, 300);
        buf := line || chr(10);
      elsif length(buf) + length(line) < 32000 then
        buf := buf || line || chr(10);
      else
        flush;
        buf := line || chr(10);
      end if;
    end loop;
    flush;
    dbms_lob.freetemporary(c);
    return n;
  exception
    when others then
      if dbms_lob.isopen(f) = 1 then
        dbms_lob.fileclose(f);
      end if;
      raise;
  end;

  function refresh(p_dir varchar2 default 'BK_DOCS') return number is
    n number;
    d number;
    f varchar2(100);
  begin
    if bk_vec.ready = 'N' then
      raise_application_error(-20175, 'BK-175: Δεν υπάρχει μοντέλο embeddings ακόμα (db/LOAD_EMBED.sql)');
    end if;
    n := facts;
    select count(*) into d from all_directories where directory_name = p_dir;
    if d > 0 then
      delete from bk_ai_doc where source not like 'DB:%';
      for i in 1 .. regexp_count(c_files, ',') + 1 loop
        f := regexp_substr(c_files, '[^,]+', 1, i);
        begin
          n := n + load_file(p_dir, f);
        exception
          when others then
            null;              -- (a file it may not read: the rest all the same)
        end;
      end loop;
    end if;
    execute immediate 'update bk_ai_doc set vec = vector_embedding(' || bk_vec.c_model
                      || ' using ''passage: '' || substr(title || '': '' || text, 1, 3900) as data) where vec is null';
    commit;
    return n;
  end;

  -- a question of interest with an amount: the rate of each product for that balance, worked out by the database
  -- (a small model reads "from 5.000 to 19.999,99" and still picks the wrong step for 12.000: it gets the answer)
  function rate_calc(p_question varchar2) return varchar2 is
    a number;
    cur varchar2(3) := 'EUR';
    t varchar2(4000);
    s varchar2(100);
    d date;
  begin
    if not regexp_like(p_question, 'επιτόκ|τόκ|απόδοσ', 'i') then
      return null;
    end if;
    begin
      d := bk_core.open_day;
    exception
      when others then
        d := trunc(sysdate);      -- (no business day yet)
    end;
    -- the amount: 12.000 or 12000 or 12.000,50 (Greek: the dot of the thousands, the comma of the decimals)
    s := regexp_substr(p_question, '[0-9]{1,3}(\.[0-9]{3})+(,[0-9]+)?|[0-9]+(,[0-9]+)?');
    if s is null then
      return null;
    end if;
    a := to_number(replace(replace(s, '.'), ',', '.'), '999999999999D99', 'NLS_NUMERIC_CHARACTERS=''.,''');
    cur := case when regexp_like(p_question, 'USD|δολάρ', 'i') then 'USD' when regexp_like(p_question, 'GBP|λίρ', 'i') then 'GBP'
                when regexp_like(p_question, 'CHF|φράγκ', 'i') then 'CHF' else 'EUR' end;
    for x in (select p.code, p.name,
                     (select max(r.rate) keep (dense_rank last order by r.min_balance) from bk_rate r
                      where r.product_id = p.id and r.currency = cur and r.min_balance <= a
                        and r.valid_from = (select max(y.valid_from) from bk_rate y where y.product_id = r.product_id
                                            and y.currency = r.currency and y.min_balance = r.min_balance
                                            and y.valid_from <= d)) rate
              from bk_product p where p.kind in ('CUR', 'SAV') and p.active = 'Y' order by p.id) loop
      if x.rate is not null then
        t := t || case when t is not null then '; ' end || x.code || ' «' || x.name || '»: ' || pct(x.rate);
      end if;
    end loop;
    if t is null then
      return null;
    end if;
    return 'Υπολογισμός της τράπεζας: για υπόλοιπο ' || num(a) || ' ' || cur || ' το ετήσιο επιτόκιο καταθέσεων τώρα είναι: '
           || t || '.';
  end;

  function ask(p_question varchar2, p_k number default null) return number is
    v vector(384, float32);
    qid number;
    prompt clob;
    ans clob;
    k number := 0;
    t0 timestamp := systimestamp;
    model varchar2(60) := setting('AI_LLM_MODEL', 'gemma3:4b');
    nf number := nvl(ceil(p_k / 2), to_number(setting('AI_RAG_FACTS', '2')));
    nd number := nvl(floor(p_k / 2), to_number(setting('AI_RAG_DOCS', '2')));
    chars number := to_number(setting('AI_RAG_CHARS', '600'));
    err varchar2(1000);
    calc varchar2(4000) := rate_calc(p_question);
  begin
    if trim(p_question) is null then
      raise_application_error(-20176, 'BK-176: Γράψε μια ερώτηση');
    end if;
    if bk_vec.ready = 'N' then
      raise_application_error(-20175, 'BK-175: Δεν υπάρχει μοντέλο embeddings ακόμα (db/LOAD_EMBED.sql)');
    end if;
    insert into bk_ai_question (asked_by, question, model)
    values (nvl(sys_context('userenv', 'client_identifier'), user), substr(trim(p_question), 1, 1000), model)
    returning id into qid;
    execute immediate 'select vector_embedding(' || bk_vec.c_model || ' using :q as data) from dual'
      into v using 'query: ' || substr(trim(p_question), 1, 500);
    prompt := 'Είσαι ο βοηθός των υπαλλήλων μιας τράπεζας. Απάντησε στα ελληνικά, σύντομα και με ακρίβεια, ΜΟΝΟ από τα '
              || 'παρακάτω αποσπάσματα. Μετά από κάθε πληροφορία γράψε τον αριθμό του αποσπάσματος σε αγκύλες, π.χ. [2]. '
              || 'Χρησιμοποίησε μόνο τους αριθμούς των αποσπασμάτων που υπάρχουν. Αν τα αποσπάσματα δεν φτάνουν για την '
              || 'απάντηση, πες ότι δεν το ξέρεις· μη μαντεύεις.' || chr(10) || chr(10);
    if calc is not null then
      k := 1;
      insert into bk_ai_question_src (question_id, n, source, title, text, similarity)
      values (qid, k, 'DB:calc', 'Υπολογισμός επιτοκίου', calc, 1);
      prompt := prompt || '[1] Υπολογισμός επιτοκίου: ' || calc || chr(10) || chr(10);
    end if;
    -- the facts of the bank and the guides each their own share (the guides are many more, long: alone they took
    -- every place, and the rule asked about was not given to the model)
    for d in (select * from (
                select id, source, title, text, round(1 - vector_distance(vec, v, cosine), 4) sim, 0 o
                from bk_ai_doc where vec is not null and source like 'DB:%'
                order by vector_distance(vec, v, cosine) fetch first nf rows only)
              union all
              select * from (
                select id, source, title, text, round(1 - vector_distance(vec, v, cosine), 4) sim, 1 o
                from bk_ai_doc where vec is not null and source not like 'DB:%'
                order by vector_distance(vec, v, cosine) fetch first nd rows only)
              order by o, sim desc) loop
      k := k + 1;
      insert into bk_ai_question_src (question_id, n, doc_id, source, title, text, similarity)
      values (qid, k, d.id, d.source, d.title, d.text, d.sim);
      -- (each piece at most AI_RAG_CHARS: the model reads all of it before it writes, on the CPU that is most of the
      -- time of an answer)
      prompt := prompt || '[' || k || '] ' || d.title || ': ' || substr(d.text, 1, chars) || chr(10) || chr(10);
    end loop;
    prompt := prompt || 'Ερώτηση: ' || trim(p_question) || chr(10) || 'Απάντηση:';
    begin
      -- (the time it may take: "transfer_timeout" in the parameters; UTL_HTTP.SET_TRANSFER_TIMEOUT it does not
      -- read, and without it each call stopped at 60 seconds: ORA-29276 under an ORA-29273)
      ans := dbms_vector.utl_to_generate_text(prompt,
               json('{"provider":"ollama","host":"local","url":"' || setting('AI_LLM_URL', 'http://localhost:11434/api/generate')
                    || '","model":"' || model || '","transfer_timeout":'
                    || to_number(setting('AI_LLM_TIMEOUT', '300')) || ',"keep_alive":"' || setting('AI_LLM_KEEP_ALIVE', '24h')
                    -- (these to Ollama as they are: the answer at most, its context, a little of chance)
                    || '","options":{"num_predict":' || to_number(setting('AI_LLM_MAX_TOKENS', '200'))
                    || ',"num_ctx":' || to_number(setting('AI_LLM_CTX', '2048')) || ',"temperature":0.2}}'));
    exception
      when others then
        -- all of it (the first line alone said only "HTTP request failed")
        err := substr(regexp_replace(dbms_utility.format_error_stack, 'ORA-06512[^' || chr(10) || ']*' || chr(10), ''), 1, 1000);
    end;
    update bk_ai_question
    set answer = ans, error = err,
        ms = round((extract(minute from systimestamp - t0) * 60 + extract(second from systimestamp - t0)) * 1000)
    where id = qid;
    commit;
    return qid;
  end;

  function info return varchar2 is
    n number;
    f number;
  begin
    select count(*), count(case when source like 'DB:%' then 1 end) into n, f from bk_ai_doc;
    return 'Γλωσσικό μοντέλο: ' || setting('AI_LLM_MODEL', 'gemma3:4b') || ' (Ollama, '
           || setting('AI_LLM_URL', 'http://localhost:11434/api/generate') || ')  ·  γνώση: ' || n || ' κομμάτια ('
           || f || ' από τα προϊόντα και τους κανόνες, ' || (n - f) || ' από τις οδηγίες)';
  end;
end bk_rag;
/
