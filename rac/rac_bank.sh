#!/bin/bash
# rac_bank.sh -- on rac1, as root: the bank on the RAC database BANKRAC (rac/db1_export.sh put bank_rac.dmp and
# bank_rac_files.tgz in the home of chris here):
#
#   sudo bash ~/rac_bank.sh                    (the LLM: Ollama on the Windows of the laptop, 192.168.178.54)
#
#   1. the files of the AI to /u01/app/oracle/bank on rac1 and on rac2 (BK_MODELS, BK_DOCS: the same path on both
#      nodes, either instance may read them)
#   2. BANK in BANKPDB there already: dropped first (asked); impdp into BANKPDB through the listener of rac1
#      (cluster=n: its files are on rac1 only); the password of SYSTEM of BANKRAC asked by impdp
#   3. what Data Pump does not carry: DBMS_CRYPTO, BK_MODELS, BK_DOCS, the ACL to the LLM; compiled
#   4. the service bank_rac on both instances, with Transparent Application Continuity: the session of a node that
#      falls goes on in the other one, its transaction replayed (failovertype AUTO, commit_outcome, the drain of a
#      planned stop); its FAN events (ONS) for the pools of the applications
#   5. what is there: the objects, the invalid ones, the models of the AI, the service
set -euo pipefail
LLM=${1:-192.168.178.54}
GRID_HOME=/u01/app/23.0.0/grid
ORACLE_BASE=/u01/app/oracle
DB_HOME=$ORACLE_BASE/product/26ai/dbhome_1
DB=BANKRAC
DP=$ORACLE_BASE/dp
FILES=$ORACLE_BASE/bank
CHRIS=${SUDO_USER:-chris}
HOME_C=$(getent passwd "$CHRIS" | cut -d: -f6)
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in rac1) ;; *) die "this is $(hostname): rac_bank.sh is for rac1" ;; esac
D() { runuser -l oracle -c "export ORACLE_HOME=$DB_HOME ORACLE_SID=${DB}1 PATH=$DB_HOME/bin:\$PATH; $1"; }
sqlsys() { D "sqlplus -s / as sysdba"; }
D "srvctl status database -db $DB" | grep -q "is running" || die "the database $DB does not run (rac_db.sh)"

echo "== 1. the files: $DP, $FILES (rac1, rac2)"
mkdir -p "$DP" "$FILES"
for f in bank_rac.dmp bank_rac_files.tgz; do
  if [ -f "$HOME_C/$f" ]; then mv -f "$HOME_C/$f" "$DP/"; fi
  [ -f "$DP/$f" ] || die "no $f (on db1: sudo bash ~/db1_export.sh)"
done
tar -C "$FILES" -xzf "$DP/bank_rac_files.tgz"
chown -R oracle:oinstall "$DP" "$FILES"
runuser -u oracle -- ssh -o BatchMode=yes rac2 "mkdir -p $FILES"
tar -C "$FILES" -cf - . | runuser -u oracle -- ssh -o BatchMode=yes rac2 "tar -C $FILES -xf -"

EXISTS=$(printf 'set heading off feedback off pages 0\nalter session set container = BANKPDB;\nselect count(*) from dba_users where username = %s;\n' "'BANK'" | sqlsys | tr -d '[:space:]')
if [ "$EXISTS" != 0 ]; then
  read -r -p "== BANK is in BANKPDB of $DB already: drop it and import again? (yes/no) " a
  [ "$a" = yes ] || die "left as it is"
  sqlsys <<'SQL'
whenever sqlerror exit failure
alter session set container = BANKPDB;
begin
  for s in (select inst_id, sid, serial# from gv$session where username = 'BANK') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ',@' || s.inst_id || ''' immediate';
  end loop;
end;
/
drop user bank cascade;
SQL
fi

echo "== 2. impdp into BANKPDB (the password of SYSTEM of $DB)"
printf "alter session set container = BANKPDB;\ncreate or replace directory bk_dp as '%s';\n" "$DP" | sqlsys >/dev/null
set +e
D "impdp system@//rac1.home.lan:1521/bankpdb directory=BK_DP dumpfile=bank_rac.dmp logfile=bank_rac_imp.log cluster=n"
rc=$?
set -e
# (5: done, with warnings: the packages of the login before DBMS_CRYPTO; compiled below)
[ $rc = 0 ] || [ $rc = 5 ] || die "impdp: $rc ($DP/bank_rac_imp.log)"

echo "== 3. DBMS_CRYPTO, BK_MODELS, BK_DOCS, the ACL to $LLM:11434; compile"
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
SQL

echo "== 4. the service bank_rac (both instances, Transparent Application Continuity)"
if ! D "srvctl status service -db $DB -service bank_rac" >/dev/null 2>&1; then
  D "srvctl add service -db $DB -service bank_rac -pdb BANKPDB -preferred ${DB}1,${DB}2 \
    -failovertype AUTO -failover_restore AUTO -commit_outcome TRUE -retention 86400 -replay_init_time 600 \
    -failoverretry 30 -failoverdelay 3 -notification TRUE -clbgoal SHORT -rlbgoal SERVICE_TIME \
    -drain_timeout 60 -stopoption IMMEDIATE"
fi
D "srvctl start service -db $DB -service bank_rac" 2>/dev/null || true
D "srvctl status service -db $DB -service bank_rac"

echo "== 5. BANK in BANKPDB of $DB"
sqlsys <<'SQL'
set feedback off lines 160 pages 100
alter session set container = BANKPDB;
col object_type for a20
col object_name for a32
select object_type, count(*) n from dba_objects where owner = 'BANK' group by object_type order by 1;
prompt == invalid (none: good)
select object_type, object_name from dba_objects where owner = 'BANK' and status <> 'VALID' order by 1, 2;
prompt == the models of the AI
select model_name, algorithm from dba_mining_models where owner = 'BANK' order by 1;
prompt == the accounts
select count(*) accounts from bank.bk_account;
SQL
cat <<'MSG'
== the bank on RAC. The connection of an application (the SCAN by its address: the nodes of k3s have no /etc/hosts
   with rac-scan; the retries: the time of a failover):
   jdbc:oracle:thin:@(DESCRIPTION=(CONNECT_TIMEOUT=5)(TRANSPORT_CONNECT_TIMEOUT=3)(RETRY_COUNT=20)(RETRY_DELAY=3)(ADDRESS=(PROTOCOL=TCP)(HOST=192.168.178.235)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=bank_rac)))
MSG
