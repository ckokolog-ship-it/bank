-- GRANT_AI.sql -- once, as SYSTEM (or SYS), in the pluggable database: what BANK needs for the AI of the bank:
--   CREATE MINING MODEL      the models (the suspicious movements: BK_AI.sql; the embeddings: BK_VECTOR.sql)
--   the directory BK_MODELS  the file of the model of embeddings (ai/mk_embed_model.sh writes it in ai/models)
--   the directory BK_DOCS    the guides of the repo (docs/): the knowledge of the assistant (BK_RAG.sql)
--   an ACL to the LLM        HTTP to Ollama on this server (localhost:11434): the assistant (BK_RAG.sql)
-- The database must see the two directories (on its own server):
--
--   sqlplus system@localhost:1521/FREEPDB1 @GRANT_AI.sql             (/home/oracle/bank/ai/models, /home/oracle/bank/docs)
--   sqlplus system@localhost:1521/FREEPDB1 @GRANT_AI.sql /models/dir /docs/dir [llm host]
--
-- (it asks for the password of SYSTEM). Then INSTALL.sql demo again (the demo rows stay; each model is made once).
set define on
set verify off
set termout off
column 1 new_value 1
column 2 new_value 2
column 3 new_value 3
select '' "1", '' "2", '' "3" from dual where rownum = 0;
column dir new_value dir noprint
column docs new_value docs noprint
column llm new_value llm noprint
select nvl('&1', '/home/oracle/bank/ai/models') dir, nvl('&2', '/home/oracle/bank/docs') docs,
       nvl('&3', 'localhost') llm from dual;
set termout on
grant create mining model to bank;
create or replace directory bk_models as '&dir';
grant read on directory bk_models to bank;
create or replace directory bk_docs as '&docs';
grant read on directory bk_docs to bank;
begin
  dbms_network_acl_admin.append_host_ace(host => '&llm', lower_port => 11434, upper_port => 11434,
    ace => xs$ace_type(privilege_list => xs$name_list('http'), principal_name => 'BANK', principal_type => xs_acl.ptype_db));
end;
/
prompt == BANK may make models (CREATE MINING MODEL), read BK_MODELS (&dir) and BK_DOCS (&docs), and call the LLM (&llm:11434)
prompt == now INSTALL.sql demo again
exit
