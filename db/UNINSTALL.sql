-- UNINSTALL.sql -- everything of the bank out (the tables with their rows): as its owner
--   sqlplus bank/<password>@FREEPDB1 @UNINSTALL.sql
set feedback off
whenever sqlerror continue
drop package if exists bk_auth;
drop package if exists bk_report;
drop package if exists bk_text;
drop package if exists bk_core;
drop view if exists bk_account_v;
drop view if exists bk_rule_v;
drop view if exists bk_card_v;
drop view if exists bk_ccard_v;
drop view if exists bk_loan_v;
drop view if exists bk_currency_v;
drop view if exists bk_cc_statement_v;
drop view if exists bk_customer_account_v;
drop view if exists bk_statement_line;
drop view if exists bk_limits;
drop view if exists bk_check;
drop view if exists bk_statement;
drop view if exists bk_value_balance;
drop table if exists bk_ln_schedule purge;
drop table if exists bk_loan purge;
drop table if exists bk_ln_product purge;
drop table if exists bk_ln_index purge;
drop table if exists bk_cc_statement purge;
drop table if exists bk_cc_auth purge;
drop table if exists bk_ccard purge;
drop table if exists bk_cc_product purge;
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
drop table if exists bk_fx_rate purge;
drop table if exists bk_currency purge;
prompt == BANK UNINSTALL OK
exit
