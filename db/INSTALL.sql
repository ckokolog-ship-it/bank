-- INSTALL.sql -- the database of the bank, as its owner, from this folder:
--
--   sqlplus bank/<password>@FREEPDB1 @INSTALL.sql            (the tables, the products, the package)
--   sqlplus bank/<password>@FREEPDB1 @INSTALL.sql demo       (and the demo rows: random customers, a year)
--
-- The files are UTF-8 (Greek): the client must read them so, before sqlplus:
--   Windows:  set NLS_LANG=GREEK_GREECE.AL32UTF8
--   Linux:    export NLS_LANG=GREEK_GREECE.AL32UTF8
-- A second run is safe: what exists stays (UNINSTALL.sql removes everything). The user: CREATE_USER.sql.
set define on
set verify off
set feedback off
whenever sqlerror exit failure rollback
alter session set ddl_lock_timeout = 60;

-- &1 empty when not given (else sqlplus would ask for it)
set termout off
column 1 new_value 1
select '' "1" from dual where rownum = 0;
column demo_file new_value demo_file noprint
select case when lower('&1') = 'demo' then 'BK_DEMO.sql' else 'BK_NODEMO.sql' end demo_file from dual;
-- the login of the forms (BK_AUTH): with DBMS_CRYPTO only (GRANT_CRYPTO.sql)
column ai_demo_file new_value ai_demo_file noprint
select case when lower('&1') = 'demo' then 'BK_AI_DEMO.sql' else 'BK_AI_NODEMO.sql' end ai_demo_file from dual;
column auth_file new_value auth_file noprint
select case when count(*) > 0 then 'BK_AUTH.sql' else 'BK_NOAUTH.sql' end auth_file
from all_procedures where owner = 'SYS' and object_name = 'DBMS_CRYPTO';
set termout on

prompt == the client reads UTF-8
begin
  if length('Ά') <> 1 then
    raise_application_error(-20001, 'the client does not read UTF-8: NLS_LANG=GREEK_GREECE.AL32UTF8 first');
  end if;
end;
/
set define off
prompt == the tables
@BK_TABLES.sql
prompt == the accounts of the bank, the products
@BK_BASE.sql
prompt == the package BK_CORE
whenever sqlerror continue
@BK_CORE.sql
whenever sqlerror exit failure rollback
declare
  n number;
begin
  select count(*) into n from user_errors where name = 'BK_CORE';
  if n > 0 then
    raise_application_error(-20002, 'BK_CORE: ' || n || ' errors (show errors package body bk_core)');
  end if;
end;
/
prompt == the rows of the reports (BK_REPORT)
@BK_REPORT.sql
prompt == the suspicious movements (BK_AI: Oracle Machine Learning)
@BK_AI.sql
prompt == the words of the forms (BK_TEXT)
@BK_TEXT.sql
set define on
prompt == &auth_file
whenever sqlerror continue
@&auth_file
whenever sqlerror exit failure rollback
declare
  n number;
begin
  select count(*) into n from user_errors where name in ('BK_AUTH', 'BK_TEXT', 'BK_REPORT', 'BK_AI');
  if n > 0 then
    raise_application_error(-20002, 'BK_AUTH, BK_TEXT, BK_REPORT or BK_AI: ' || n || ' errors (show errors)');
  end if;
end;
/
prompt == &demo_file
@&demo_file
prompt == &ai_demo_file
@&ai_demo_file
prompt == BANK INSTALL OK
exit
