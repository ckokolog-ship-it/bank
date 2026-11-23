-- GRANT_AI.sql -- once, as SYSTEM (or SYS), in the pluggable database: BANK may make the models of AI (CREATE
-- MINING MODEL: the suspicious movements, BK_AI.sql; the embeddings, BK_VECTOR.sql), and read the file of the model
-- of embeddings from the directory BK_MODELS (where ai/mk_embed_model.sh writes it; the database must see it):
--
--   sqlplus system@localhost:1521/FREEPDB1 @GRANT_AI.sql                       (/home/oracle/bank/ai/models)
--   sqlplus system@localhost:1521/FREEPDB1 @GRANT_AI.sql /another/directory
--
-- (it asks for the password of SYSTEM). Then INSTALL.sql demo again (the demo rows stay; each model is made once).
set define on
set verify off
set termout off
column 1 new_value 1
select '' "1" from dual where rownum = 0;
column dir new_value dir noprint
select nvl('&1', '/home/oracle/bank/ai/models') dir from dual;
set termout on
grant create mining model to bank;
create or replace directory bk_models as '&dir';
grant read on directory bk_models to bank;
prompt == BANK may make models (CREATE MINING MODEL) and read the directory BK_MODELS (&dir)
prompt == now INSTALL.sql demo again
exit
