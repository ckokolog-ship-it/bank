#!/bin/bash
# import.sh -- on db1, as root: the schema BANK from forms1 (dg/export.sh put bank.dmp, bank_files.tgz and this file
# in the home of chris) into the PDB BANKPDB of the primary:
#
#   sudo bash ~/import.sh                     (the LLM: Ollama on the Windows of the laptop, 192.168.178.54)
#   sudo bash ~/import.sh 192.168.178.54
#
# The files of the AI to /u01/app/oracle/bank (ai/models, docs); BANK there already: dropped first (asked: a copy
# made again); impdp (the password of SYSTEM: asked by impdp; the user BANK comes with its own password); what
# Data Pump does not carry: EXECUTE on DBMS_CRYPTO (the login of the forms), the directories BK_MODELS and BK_DOCS,
# the ACL to the LLM; all compiled; at the end what is there: the tables, the invalid objects, the models of the AI.
set -euo pipefail
LLM=${1:-192.168.178.54}
SRC=$(getent passwd "${SUDO_USER:-chris}" | cut -d: -f6)
ORACLE_BASE=/u01/app/oracle
DP=$ORACLE_BASE/dp
FILES=$ORACLE_BASE/bank
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in db1) ;; *) die "this is $(hostname): import.sh is for db1 (the primary)" ;; esac
sqlsys() { runuser -l oracle -c "sqlplus -s / as sysdba"; }
ROLE=$(printf 'set heading off feedback off pages 0\nselect database_role from v$database;\n' | sqlsys | tr -d '[:space:]')
[ "$ROLE" = PRIMARY ] || die "the database here is $ROLE, not PRIMARY"

echo "== the files: $DP, $FILES"
mkdir -p "$DP" "$FILES"
for f in bank.dmp bank_files.tgz; do
  if [ -f "$SRC/$f" ]; then mv -f "$SRC/$f" "$DP/"; fi
  [ -f "$DP/$f" ] || die "no $f (on forms1: bash dg/export.sh)"
done
tar -C "$FILES" -xzf "$DP/bank_files.tgz"
chown -R oracle:oinstall "$DP" "$FILES"

EXISTS=$(printf 'set heading off feedback off pages 0\nalter session set container = BANKPDB;\nselect count(*) from dba_users where username = %s;\n' "'BANK'" | sqlsys | tr -d '[:space:]')
if [ "$EXISTS" != 0 ]; then
  read -r -p "== BANK is in BANKPDB already: drop it and import again? (yes/no) " a
  [ "$a" = yes ] || die "left as it is"
  sqlsys <<'SQL'
whenever sqlerror exit failure
alter session set container = BANKPDB;
begin
  for s in (select sid, serial# from v$session where username = 'BANK') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
  end loop;
end;
/
drop user bank cascade;
SQL
fi

echo "== the directory BK_DP; impdp (the password of SYSTEM)"
printf "alter session set container = BANKPDB;\ncreate or replace directory bk_dp as '%s';\n" "$DP" | sqlsys >/dev/null
set +e
runuser -l oracle -c "impdp system@BANKPDB directory=BK_DP dumpfile=bank.dmp logfile=bank_imp.log"
rc=$?
set -e
# (5: done, with warnings: e.g. the packages of the login before DBMS_CRYPTO; compiled below)
[ $rc = 0 ] || [ $rc = 5 ] || die "impdp: $rc ($DP/bank_imp.log)"

echo "== DBMS_CRYPTO, BK_MODELS, BK_DOCS, the ACL to $LLM:11434; compile"
sqlsys <<SQL
whenever sqlerror exit failure
set feedback off lines 160 pages 100
alter session set container = BANKPDB;
grant execute on sys.dbms_crypto to bank;
grant create mining model to bank;
create or replace directory bk_models as '$FILES/ai/models';
grant read on directory bk_models to bank;
create or replace directory bk_docs as '$FILES/docs';
grant read on directory bk_docs to bank;
begin
  dbms_network_acl_admin.append_host_ace(host => '$LLM', lower_port => 11434, upper_port => 11434,
    ace => xs\$ace_type(privilege_list => xs\$name_list('http'), principal_name => 'BANK', principal_type => xs_acl.ptype_db));
end;
/
exec dbms_utility.compile_schema('BANK', compile_all => false)
whenever sqlerror continue
prompt == BANK in BANKPDB
col object_type for a20
col object_name for a32
select object_type, count(*) n from dba_objects where owner = 'BANK' group by object_type order by 1;
prompt == invalid (none: good)
select object_type, object_name from dba_objects where owner = 'BANK' and status <> 'VALID' order by 1, 2;
prompt == the models of the AI
select model_name, mining_function, algorithm from dba_mining_models where owner = 'BANK' order by 1;
SQL
echo "== BANK on db1. Try: sqlplus bank@BANKPDB. Next: docs/ODIGIES_DG.md (the standby on db2)"
