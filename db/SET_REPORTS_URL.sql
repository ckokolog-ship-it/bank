-- SET_REPORTS_URL.sql -- where the forms open the reports: the rwservlet of the Reports Server, with the key of
-- cgicmd.dat (bank: userid=/@BK_DB, no password in the address: forms/bk_wallet.sh writes it), and the format.
--   sqlplus /@BK_DB @SET_REPORTS_URL.sql http://forms1.home.lan:9012 PDF
-- The format: PDF or HTML.
set verify off
merge into bk_setting s
using (select 'REPORTS_URL' name, '&1/reports/rwservlet?bank' value from dual
       union all select 'REPORTS_FORMAT', upper('&2') from dual) v
on (s.name = v.name)
when matched then update set s.value = v.value
when not matched then insert (name, value) values (v.name, v.value);
commit;
select name, value from bk_setting where name like 'REPORTS%' order by name;
exit
