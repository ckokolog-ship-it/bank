-- LOAD_EMBED.sql -- (and the knowledge of the assistant: BK_RAG.sql, the guides from BK_DOCS) the model of embeddings (BK_EMBED, for the search by meaning: BK_VECTOR.sql) into the
-- database, from the directory BK_MODELS (GRANT_AI.sql, as SYSTEM) and its file bk_embed.onnx (ai/mk_embed_model.sh),
-- then the texts of all the movements with their vectors. INSTALL.sql runs it at its end: the model there, only the
-- texts of the new movements; no directory or no file, it says so (the rest of the bank works without it).
--
--   sqlplus bank@localhost:1521/FREEPDB1 @LOAD_EMBED.sql          (once)
--   sqlplus bank@localhost:1521/FREEPDB1 @LOAD_EMBED.sql again    (a new file of the model)
set define on
set verify off
set termout off
column 1 new_value 1
select '' "1" from dual where rownum = 0;
set termout on
set serveroutput on
declare
  n number;
  d number;
begin
  if bk_vec.ready = 'Y' and lower('&1') <> 'again' then
    n := bk_vec.refresh;
    commit;
    dbms_output.put_line('== BK_EMBED: in the database; ' || n || ' new texts');
    n := bk_rag.refresh;
    dbms_output.put_line('== the knowledge of the assistant (BK_RAG): ' || n || ' pieces');
    return;
  end if;
  select count(*) into d from all_directories where directory_name = 'BK_MODELS';
  if d = 0 then
    dbms_output.put_line('== no model of embeddings: ai/mk_embed_model.sh, then db/GRANT_AI.sql as SYSTEM, then LOAD_EMBED.sql');
    return;
  end if;
  n := bk_vec.load_model;
  dbms_output.put_line('== BK_EMBED loaded: ' || n || ' texts of the movements with their vector');
  n := bk_rag.refresh;
  dbms_output.put_line('== the knowledge of the assistant (BK_RAG): ' || n || ' pieces');
exception
  when others then
    dbms_output.put_line('== ' || sqlerrm);
end;
/
set serveroutput off
set define off
