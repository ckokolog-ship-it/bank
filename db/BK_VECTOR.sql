-- BK_VECTOR.sql -- the search by meaning (Oracle AI Vector Search): a multilingual model of embeddings in the
-- database (BK_EMBED: intfloat/multilingual-e5-small as ONNX, its tokenizer in it; ai/mk_embed_model.sh makes it,
-- LOAD_EMBED.sql loads it) turns a text into a VECTOR of 384 numbers (VECTOR_EMBEDDING); two texts near in
-- meaning, two vectors near (VECTOR_DISTANCE, cosine): "φαγητό έξω" finds "Ταβέρνα Ο Μπάμπης" and "Pizza Fan Πάτρα"
-- with no word of them in common.
--
--   BK_AI_PHRASE       the texts of the movements, each once (the numbers in them as #: "Μισθοδοσία #"), its
--                      vector, its category (the nearest one) and how near
--   BK_AI_ENTRY_TEXT   each entry: its text
--   BK_AI_CATEGORY     the categories of the spending (a name, the words of it), each with its vector
--   BK_AI_SPEND_V      what an account spent, by month and category (its debits, in euro)
--
-- bk_vec.refresh: the texts of the new entries, their vectors, their categories (bk_core.close_day calls it for
-- the day; nothing without the model). bk_vec.search: the movements nearest in meaning to a question. The e5
-- model wants "query: " before a question and "passage: " before a text searched: bk_vec puts them.
create table if not exists bk_ai_category (
  code   varchar2(4)   constraint bk_ai_category_pk primary key,
  name   varchar2(60)  not null,
  hint   varchar2(300) not null,           -- the words of it: what is embedded
  ord    number        not null,
  vec    vector(384, float32),             -- its words as a question ("query: "): the texts to it
  qvec   vector(384, float32)              -- its words as a text ("passage: "): a question to it
);

create table if not exists bk_ai_phrase (
  id        number generated always as identity constraint bk_ai_phrase_pk primary key,
  text      varchar2(300) not null constraint bk_ai_phrase_uk unique,
  vec       vector(384, float32),
  category  varchar2(4) constraint bk_ai_phrase_cat_fk references bk_ai_category,
  cat_sim   number                        -- how near its category (cosine similarity)
);

create table if not exists bk_ai_entry_text (
  entry_id   number constraint bk_ai_entry_text_pk primary key constraint bk_ai_entry_text_fk references bk_entry,
  phrase_id  number not null constraint bk_ai_entry_text_ph_fk references bk_ai_phrase
);
create index if not exists bk_ai_entry_text_ph_ix on bk_ai_entry_text (phrase_id);

-- the categories (again: the words changed, the vector again)
merge into bk_ai_category c
using (select 'FOOD' code, 'Φαγητό έξω' name, 'εστιατόριο, ταβέρνα, καφετέρια, φαγητό σε πακέτο, ψητοπωλείο' hint, 1 ord from dual
       union all select 'GROC', 'Σούπερ μάρκετ', 'σούπερ μάρκετ, τρόφιμα, μανάβικο, ψώνια για το σπίτι', 2 from dual
       union all select 'FUEL', 'Καύσιμα και αυτοκίνητο', 'πρατήριο καυσίμων, βενζίνη, αυτοκίνητο', 3 from dual
       union all select 'BILL', 'Λογαριασμοί σπιτιού', 'λογαριασμός ρεύματος, λογαριασμός νερού, κινητή τηλεφωνία, internet σπιτιού', 4 from dual
       union all select 'SUBS', 'Συνδρομές', 'συνδρομή, streaming', 5 from dual
       union all select 'TRAV', 'Ταξίδια', 'αεροπορικά εισιτήρια, πλοίο, ξενοδοχείο, ταξίδι', 6 from dual
       union all select 'HLTH', 'Υγεία', 'φαρμακείο, γιατρός, οδοντίατρος', 7 from dual
       union all select 'CLTH', 'Ρούχα και παπούτσια', 'ρούχα, παπούτσια, ένδυση, αθλητικά είδη', 8 from dual
       union all select 'SHOP', 'Αγορές online και ηλεκτρονικά', 'ηλεκτρονικό κατάστημα, βιβλία, ηλεκτρικές συσκευές, υπολογιστές', 9 from dual
       union all select 'HOME', 'Ενοίκιο και κατοικία', 'ενοίκιο, αγορά κατοικίας', 10 from dual
       union all select 'CASH', 'Μετρητά', 'ανάληψη μετρητών, ATM, κατάθεση μετρητών', 11 from dual
       union all select 'INCO', 'Μισθός και έσοδα', 'μισθοδοσία, μισθός', 12 from dual
       union all select 'DEBT', 'Δάνεια και κάρτες', 'δόση δανείου, πληρωμή πιστωτικής κάρτας', 13 from dual
       union all select 'BANK', 'Τόκοι και προμήθειες', 'τόκοι, προμήθεια της τράπεζας, καθυστέρηση', 14 from dual
       union all select 'MOVE', 'Μεταφορές χρημάτων', 'μεταφορά χρημάτων, συνάλλαγμα', 15 from dual) x
on (c.code = x.code)
when matched then update set c.name = x.name, c.ord = x.ord,
                             c.vec = case when c.hint = x.hint then c.vec end,
                             c.qvec = case when c.hint = x.hint then c.qvec end, c.hint = x.hint
when not matched then insert (code, name, hint, ord) values (x.code, x.name, x.hint, x.ord);
commit;

create or replace view bk_ai_spend_v as
select l.account_id, trunc(e.book_date, 'MM') month, c.code category, c.name, c.ord,
       sum(l.base_debit) amount, count(*) movements
from bk_line l, bk_entry e, bk_ai_entry_text t, bk_ai_phrase p, bk_ai_category c
where e.id = l.entry_id and t.entry_id = e.id and p.id = t.phrase_id and c.code = p.category
  and l.account_id is not null and l.debit > 0
group by l.account_id, trunc(e.book_date, 'MM'), c.code, c.name, c.ord;

-- the last 12 months of an account by category (its debits, in euro), the most first
create or replace view bk_ai_spend12_v as
select account_id, category, name, ord, sum(amount) amount, sum(movements) movements
from bk_ai_spend_v
where month >= add_months(trunc(bk_core.open_day, 'MM'), -11)
group by account_id, category, name, ord;

-- the hits of a search for the forms (a block on a table: bk_vec.fill_hits puts them here, for the session)
create global temporary table if not exists bk_ai_hit (
  seq         number,
  line_id     number,
  entry_id    number,
  account_id  number,
  iban        varchar2(34),
  holder      varchar2(200),
  book_date   date,
  kind        varchar2(3),
  descr       varchar2(200),
  debit       number,
  credit      number,
  currency    varchar2(3),
  similarity  number,
  category    varchar2(60)
) on commit preserve rows;

create or replace package bk_vec as
  c_model constant varchar2(30) := 'BK_EMBED';
  type t_hit is record (
    line_id     number,
    entry_id    number,
    account_id  number,
    iban        varchar2(34),
    holder      varchar2(200),
    book_date   date,
    kind        varchar2(3),
    descr       varchar2(200),
    debit       number,
    credit      number,
    currency    varchar2(3),
    similarity  number,
    category    varchar2(60));
  type t_hits is table of t_hit;
  -- Y: the model is in the database
  function ready return varchar2;
  -- the model from a file of a directory (DDL: it commits), then refresh; the texts made back
  function load_model(p_dir varchar2 default 'BK_MODELS', p_file varchar2 default 'bk_embed.onnx') return number;
  -- the text of an entry as it is searched: its words (its kind, if none), the shop of a card without "Αγορά: ",
  -- the numbers as #
  function phrase_of(p_descr varchar2, p_kind varchar2) return varchar2 deterministic;
  -- the texts of the new entries, their vectors and categories: the new texts back
  function refresh return number;
  -- the movements nearest in meaning to a question (of an account, or of all of them), the newest first: the
  -- texts up to VEC_MARGIN (0.019) less near than the nearest one; p_category: all the movements of a category
  -- (the question not used)
  function search(p_query varchar2, p_account_id number default null, p_limit number default 50,
                  p_category varchar2 default null) return t_hits pipelined;
  -- the category nearest to a question: its code, its name
  procedure category_of(p_query varchar2, p_code out varchar2, p_name out varchar2);
  -- the hits of a search into BK_AI_HIT (the forms): how many
  function fill_hits(p_query varchar2, p_account_id number default null, p_category varchar2 default null) return number;
  -- the model in a line
  function model_info return varchar2;
end bk_vec;
/

create or replace package body bk_vec as

  function ready return varchar2 is
    n number;
  begin
    select count(*) into n from user_mining_models where model_name = c_model;
    return case when n > 0 then 'Y' else 'N' end;
  end;

  function phrase_of(p_descr varchar2, p_kind varchar2) return varchar2 deterministic is
    t varchar2(300) := p_descr;
  begin
    if t is null then
      t := case p_kind when 'DEP' then 'Κατάθεση' when 'WDR' then 'Ανάληψη' when 'TRF' then 'Μεταφορά'
                       when 'OUT' then 'Μεταφορά σε άλλη τράπεζα' when 'INC' then 'Μεταφορά από άλλη τράπεζα'
                       when 'INT' then 'Τόκοι' when 'REV' then 'Αντιλογισμός' when 'PUR' then 'Αγορά με κάρτα'
                       else 'Προμήθεια' end;
    end if;
    t := regexp_replace(t, '^(Αγορά|Πληρωμή με κάρτα): ', '');
    t := regexp_replace(t, 'GR[0-9]+', 'GR#');
    t := regexp_replace(t, '[0-9]+([/.,:-][0-9]+)*', '#');
    return substr(trim(t), 1, 300);
  end;

  function refresh return number is
    hi number;
    n number;
  begin
    if ready = 'N' then
      return 0;
    end if;
    select nvl(max(entry_id), 0) into hi from bk_ai_entry_text;
    insert into bk_ai_phrase (text)
    select distinct phrase_of(e.descr, e.kind) from bk_entry e
    where e.id > hi and not exists (select null from bk_ai_phrase p where p.text = phrase_of(e.descr, e.kind));
    n := sql%rowcount;
    insert into bk_ai_entry_text (entry_id, phrase_id)
    select e.id, p.id from bk_entry e, bk_ai_phrase p where e.id > hi and p.text = phrase_of(e.descr, e.kind);
    -- (VECTOR_EMBEDDING ... USING: SQL only, so dynamic; the model may not be there when this is compiled)
    -- (the numbers, #, out: words only)
    execute immediate 'update bk_ai_phrase set vec = vector_embedding(' || c_model
                      || ' using ''passage: '' || trim(replace(text, ''#'')) as data) where vec is null';
    execute immediate 'update bk_ai_category set vec = vector_embedding(' || c_model
                      || ' using ''query: '' || hint as data), qvec = vector_embedding(' || c_model
                      || ' using ''passage: '' || hint as data) where vec is null or qvec is null';
    -- each new text: its nearest category
    merge into bk_ai_phrase p
    using (select id, code, sim from (
             select p.id, c.code, round(1 - vector_distance(p.vec, c.vec, cosine), 4) sim,
                    row_number() over (partition by p.id order by vector_distance(p.vec, c.vec, cosine)) rn
             from bk_ai_phrase p, bk_ai_category c
             where p.category is null and p.vec is not null and c.vec is not null)
           where rn = 1) x
    on (p.id = x.id)
    when matched then update set p.category = x.code, p.cat_sim = x.sim;
    -- the movements of the bank itself by their kind, not by their words: interest and fees, a reversal or a plain
    -- transfer (the model put "Τόκοι #" near health and "Μεταφορά" near travel)
    update bk_ai_phrase p set p.category = 'BANK'
    where p.category <> 'BANK' and not exists (select null from bk_ai_entry_text t, bk_entry e
                                               where t.phrase_id = p.id and e.id = t.entry_id and e.kind not in ('INT', 'FEE'));
    update bk_ai_phrase p set p.category = 'MOVE'
    where p.category <> 'MOVE' and (p.text = 'Μεταφορά' or not exists (select null from bk_ai_entry_text t, bk_entry e
                                                                      where t.phrase_id = p.id and e.id = t.entry_id and e.kind <> 'REV'));
    return n;
  end;

  function load_model(p_dir varchar2 default 'BK_MODELS', p_file varchar2 default 'bk_embed.onnx') return number is
    n number;
  begin
    begin
      dbms_vector.drop_onnx_model(c_model, true);
    exception
      when others then
        null;
    end;
    begin
      dbms_vector.load_onnx_model(p_dir, p_file, c_model,
        json('{"function":"embedding","embeddingOutput":"embedding","input":{"input":["DATA"]}}'));
    exception
      when others then
        raise_application_error(-20174, 'BK-174: Το μοντέλο δεν φορτώθηκε από ' || p_dir || '/' || p_file
                                || ' (ai/mk_embed_model.sh, db/GRANT_AI.sql): ' || substr(sqlerrm, 1, 300));
    end;
    -- the texts again with the new model
    update bk_ai_phrase set vec = null, category = null, cat_sim = null;
    update bk_ai_category set vec = null, qvec = null;
    n := refresh;
    select count(*) into n from bk_ai_phrase;
    commit;
    -- an index of the vectors (IVF: the neighbours in partitions; in the memory of the session, no vector pool)
    begin
      execute immediate 'drop index if exists bk_ai_phrase_vix';
      execute immediate 'create vector index bk_ai_phrase_vix on bk_ai_phrase (vec) organization neighbor partitions '
                        || 'distance cosine with target accuracy 95';
    exception
      when others then
        null;
    end;
    return n;
  end;

  function question(p_query varchar2) return vector is
    v vector(384, float32);
  begin
    if ready = 'N' then
      raise_application_error(-20175, 'BK-175: Δεν υπάρχει μοντέλο embeddings ακόμα (db/LOAD_EMBED.sql)');
    end if;
    execute immediate 'select vector_embedding(' || c_model || ' using :q as data) from dual'
      into v using 'query: ' || substr(trim(p_query), 1, 500);
    return v;
  end;

  procedure category_of(p_query varchar2, p_code out varchar2, p_name out varchar2) is
    v vector(384, float32);
  begin
    if trim(p_query) is null then
      return;
    end if;
    v := question(p_query);
    select max(code) keep (dense_rank first order by vector_distance(qvec, v, cosine)),
           max(name) keep (dense_rank first order by vector_distance(qvec, v, cosine))
    into p_code, p_name from bk_ai_category where qvec is not null;
  end;

  function search(p_query varchar2, p_account_id number default null, p_limit number default 50,
                  p_category varchar2 default null) return t_hits pipelined is
    v vector(384, float32);
    best number := 0;
    margin number;
    qcat varchar2(4);
    h t_hit;
  begin
    if p_category is null and trim(p_query) is null then
      return;
    end if;
    if p_category is null then
      v := question(p_query);
      -- the nearest texts: the best one and those almost as near (e5: its similarities close together)
      -- (of an account: the texts of its movements only)
      select max(1 - vector_distance(p.vec, v, cosine)) into best from bk_ai_phrase p
      where p.vec is not null
        and (p_account_id is null or exists (select null from bk_ai_entry_text t, bk_line l
                                             where t.phrase_id = p.id and l.entry_id = t.entry_id and l.account_id = p_account_id));
      select nvl(max(to_number(value, '9D9999', 'NLS_NUMERIC_CHARACTERS=''.,''')), 0.019) into margin
      from bk_setting where name = 'VEC_MARGIN';
      -- the category of the question: a text not almost the nearest (0.008) only of it (among a few texts of an
      -- account the margin let a petrol station in for "φαγητό έξω")
      select max(code) keep (dense_rank first order by vector_distance(qvec, v, cosine)) into qcat
      from bk_ai_category where qvec is not null;
    end if;
    for x in (with near as (
                select p.id, round(1 - vector_distance(p.vec, v, cosine), 4) sim
                from bk_ai_phrase p where p.vec is not null and p_category is null
                  and (p_account_id is null or exists (select null from bk_ai_entry_text t, bk_line l
                                                       where t.phrase_id = p.id and l.entry_id = t.entry_id
                                                         and l.account_id = p_account_id))
                order by vector_distance(p.vec, v, cosine)
                fetch approx first 12 rows only),
              hit as (
                select n.id, n.sim from near n, bk_ai_phrase p
                where p.id = n.id and n.sim >= best - margin and (n.sim >= best - 0.008 or p.category = qcat)
                union all
                select id, cat_sim from bk_ai_phrase where category = p_category)
              select l.id line_id, e.id entry_id, l.account_id, a.iban, a.holder, e.book_date, e.kind, e.descr,
                     nullif(l.debit, 0) debit, nullif(l.credit, 0) credit, l.currency, n.sim, c.name category
              from hit n, bk_ai_entry_text t, bk_entry e, bk_line l, bk_account_v a, bk_ai_phrase p, bk_ai_category c
              where t.phrase_id = n.id and e.id = t.entry_id and l.entry_id = e.id and l.account_id is not null
                and a.id = l.account_id and p.id = n.id and c.code (+) = p.category
                and (p_account_id is null or l.account_id = p_account_id)
              order by e.book_date desc, n.sim desc, l.id desc     -- (all near enough: the newest first)
              fetch first nvl(p_limit, 50) rows only) loop
      h.line_id := x.line_id;
      h.entry_id := x.entry_id;
      h.account_id := x.account_id;
      h.iban := x.iban;
      h.holder := x.holder;
      h.book_date := x.book_date;
      h.kind := x.kind;
      h.descr := x.descr;
      h.debit := x.debit;
      h.credit := x.credit;
      h.currency := x.currency;
      h.similarity := x.sim;
      h.category := x.category;
      pipe row (h);
    end loop;
    return;
  end;

  function fill_hits(p_query varchar2, p_account_id number default null, p_category varchar2 default null) return number is
  begin
    delete from bk_ai_hit;
    insert into bk_ai_hit (seq, line_id, entry_id, account_id, iban, holder, book_date, kind, descr, debit, credit,
                           currency, similarity, category)
    select rownum, line_id, entry_id, account_id, iban, holder, book_date, kind, descr, debit, credit, currency,
           similarity, category
    from table(search(p_query, p_account_id, 200, p_category));
    return sql%rowcount;
  end;

  function model_info return varchar2 is
    n number;
    e number;
    c date;
  begin
    if ready = 'N' then
      return 'Δεν υπάρχει μοντέλο embeddings ακόμα (ai/mk_embed_model.sh, db/LOAD_EMBED.sql)';
    end if;
    select creation_date into c from user_mining_models where model_name = c_model;
    select count(*), count(case when vec is not null then 1 end) into n, e from bk_ai_phrase;
    return 'multilingual-e5-small (ONNX, 384 διαστάσεις), ' || to_char(c, 'DD/MM/YYYY HH24:MI') || '  ·  ' || e
           || ' κείμενα κινήσεων με vector' || case when n > e then ' (' || (n - e) || ' χωρίς)' end;
  end;
end bk_vec;
/
