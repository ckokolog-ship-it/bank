#!/bin/bash
# pdb.sh -- on db1 (the primary of Data Guard), as root: a new pluggable database for another application, beside
# BANKPDB, with the protection the bank has (the redo to db2, Active Data Guard there, Fast-Start Failover):
#
#   sudo bash ~/pdb.sh PROPOPDB propo          the PDB PROPOPDB, its services propo_rw and propo_ro
#
#   1. CREATE PLUGGABLE DATABASE from the seed (OMF: its files beside the others), its admin user (the password
#      asked, not shown, never on a command line); opened, its state saved (it opens with the CDB)
#   2. on db2 it comes by itself with the redo (standby_file_management AUTO), opened READ ONLY there (Active Data
#      Guard; the trigger bk_open_pdbs of adg.sh opens all PDBs of a standby when it starts)
#   3. the services <prefix>_rw (only on the primary: the writes) and <prefix>_ro (the standby, the primary as a
#      fallback: the reads) and a trigger that starts them by the role whenever the PDB opens: after a failover or
#      a switchover they follow the roles by themselves
#   4. tnsnames.ora of db1 and db2: the alias <PDB> to <prefix>_rw on both hosts
# The users and the tables of the application: its own scripts (PROPOApplication: db/). Again: what is there is left.
set -euo pipefail
PDB=${1:?the name of the PDB, e.g. PROPOPDB}
PFX=${2:?the prefix of its services, e.g. propo}
PDB=$(echo "$PDB" | tr '[:lower:]' '[:upper:]')
PFX=$(echo "$PFX" | tr '[:upper:]' '[:lower:]')
ORACLE_HOME=/u01/app/oracle/product/26ai/dbhome_1
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0 $*"
case $(hostname -s) in db1|db2) ;; *) die "this is $(hostname): pdb.sh is for the primary of Data Guard" ;; esac
[[ $PDB =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "the name of the PDB: letters, digits, _"
[[ $PFX =~ ^[a-z][a-z0-9_]{0,20}$ ]] || die "the prefix: letters, digits, _"
[ "$PDB" != BANKPDB ] || die "BANKPDB is the bank's"
sqlsys() { runuser -l oracle -c "sqlplus -s / as sysdba"; }
q() { printf 'set heading off feedback off pages 0\n%s\n' "$1" | sqlsys | tr -d '[:space:]'; }
ROLE=$(q "select database_role from v\$database;")
[ "$ROLE" = PRIMARY ] || die "the database here is $ROLE: run it on the primary"

echo "== 1. the PDB $PDB"
if [ "$(q "select count(*) from v\$pdbs where name = '$PDB';")" = 0 ]; then
  echo "   the password of its admin (${PFX}admin): no @, no \""
  read -rsp "   password: " P1; echo
  read -rsp "   again: " P2; echo
  [ -n "$P1" ] && [ "$P1" = "$P2" ] || die "empty, or not the same"
  case $P1 in *@*|*\"*) die "no @ or \" in it" ;; esac
  # (through stdin: not in the arguments of a process)
  printf 'whenever sqlerror exit failure\ncreate pluggable database %s admin user %sadmin identified by "%s";\n' "$PDB" "$PFX" "$P1" | sqlsys
  unset P1 P2
fi
printf 'whenever sqlerror continue\nset feedback off\nalter pluggable database %s open;\nalter pluggable database %s save state;\n' "$PDB" "$PDB" | sqlsys >/dev/null 2>&1 || true
# a PDB from the seed has no USERS: the default tablespace of the users of an application
printf "whenever sqlerror exit failure\nset feedback off\nalter session set container = %s;\ndeclare n number; begin select count(*) into n from dba_tablespaces where tablespace_name = 'USERS'; if n = 0 then execute immediate 'create tablespace users datafile size 100m autoextend on next 100m maxsize 10g'; execute immediate 'alter database default tablespace users'; end if; end;\n/\n" "$PDB" | sqlsys

echo "== 3. the services ${PFX}_rw, ${PFX}_ro and their trigger"
sqlsys <<SQL
whenever sqlerror exit failure
set feedback off
alter session set container = $PDB;
declare
  procedure mk(n varchar2) is
  begin
    dbms_service.create_service(service_name => n, network_name => n);
  exception when others then
    if sqlcode not in (-44303, -44314, -44773) then raise; end if;   -- (there already)
  end;
begin
  mk('${PFX}_rw');
  mk('${PFX}_ro');
end;
/
create or replace trigger sys.${PFX}_role_services after startup on database
declare
  r varchar2(30);
  procedure up(n varchar2) is begin dbms_service.start_service(n); exception when others then null; end;
  procedure down(n varchar2) is begin dbms_service.stop_service(n); exception when others then null; end;
begin
  select database_role into r from v\$database;
  if r = 'PRIMARY' then
    up('${PFX}_rw');
  else
    down('${PFX}_rw');
  end if;
  up('${PFX}_ro');
end;
/
begin
  begin dbms_service.start_service('${PFX}_rw'); exception when others then null; end;
  begin dbms_service.start_service('${PFX}_ro'); exception when others then null; end;
end;
/
alter session set container = CDB\$ROOT;
alter system archive log current;
SQL

echo "== 4. tnsnames.ora: $PDB (${PFX}_rw on db1, db2)"
NET=$ORACLE_HOME/network/admin/tnsnames.ora
ENTRY="$PDB = (DESCRIPTION = (CONNECT_TIMEOUT = 5)(RETRY_COUNT = 3)(FAILOVER = on)
  (ADDRESS_LIST = (LOAD_BALANCE = off)
    (ADDRESS = (PROTOCOL = TCP)(HOST = db1.home.lan)(PORT = 1521))
    (ADDRESS = (PROTOCOL = TCP)(HOST = db2.home.lan)(PORT = 1521)))
  (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = ${PFX}_rw)))"
if ! grep -q "^$PDB = " "$NET"; then
  printf '%s\n' "$ENTRY" >> "$NET"
fi
echo "   (db2: the same entry; from forms1: scp, or by hand -- docs/ODIGIES_DG.md §13)"

printf 'set lines 160 pages 50\ncol name for a12\nselect name, open_mode from v$pdbs order by 1;\nalter session set container = %s;\ncol name for a14\nselect name from v$active_services order by 1;\n' "$PDB" | sqlsys
echo "== $PDB ready on the primary; on db2 within seconds (READ ONLY). Connect: ${PFX}_rw on db1,db2:1521"
