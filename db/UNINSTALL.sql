-- UNINSTALL.sql -- everything of the bank out (the tables with their rows): as its owner
--   sqlplus bank/<password>@FREEPDB1 @UNINSTALL.sql
set feedback off
whenever sqlerror continue
drop package if exists bk_core;
drop view if exists bk_limits;
drop view if exists bk_check;
drop view if exists bk_statement;
drop view if exists bk_value_balance;
drop table if exists bk_card purge;
drop table if exists bk_atm_note purge;
drop table if exists bk_atm purge;
drop table if exists bk_session purge;
drop table if exists bk_user purge;
drop table if exists bk_rule purge;
drop table if exists bk_capital purge;
drop table if exists bk_accrual purge;
drop table if exists bk_accrual_new purge;
drop table if exists bk_capital_new purge;
drop table if exists bk_calendar purge;
drop table if exists bk_line purge;
drop table if exists bk_entry cascade constraints purge;
drop table if exists bk_day purge;
drop table if exists bk_holder purge;
drop table if exists bk_account purge;
drop table if exists bk_rate purge;
drop table if exists bk_product purge;
drop table if exists bk_customer purge;
drop table if exists bk_gl purge;
drop table if exists bk_setting purge;
prompt == BANK UNINSTALL OK
exit
