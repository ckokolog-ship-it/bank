-- CREATE_USER.sql -- the owner of the bank, once, as SYSTEM, in the pluggable database:
--
--   sqlplus system@FREEPDB1 @CREATE_USER.sql
--
-- It asks for the password of the new user (it is not written in any file of the repo).
-- Then: sqlplus bank@FREEPDB1 @INSTALL.sql demo
set verify off
accept bk_pw char prompt 'Password of the user BANK: ' hide
create user bank identified by "&bk_pw"
  default tablespace users quota unlimited on users;
grant create session, create table, create view, create sequence, create procedure,
      create trigger, create type, create synonym, create mining model to bank;
undefine bk_pw
prompt == user BANK: OK
exit
