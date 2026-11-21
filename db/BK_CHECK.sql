-- BK_CHECK.sql -- does everything add up? No rows: yes (the view BK_CHECK)
set linesize 200 pagesize 100
column what format a8
column ref format a28
column detail format a100
select what, ref, detail from bk_check;
prompt == (no rows above: everything adds up)
exit
