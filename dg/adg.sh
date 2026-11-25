#!/bin/bash
# adg.sh -- Active Data Guard and the services by role. As root, first on db1 (the primary), then on db2 (the
# standby):
#
#   sudo bash ~/adg.sh
#
# On the primary: in BANKPDB the services bank_rw (writes: only on the primary) and bank_ro (reads: on the standby,
# and on the primary too, the fallback), and a trigger that starts them by the role whenever the PDB opens (so after
# a failover or a switchover they follow the roles by themselves); in the root a trigger that opens the PDBs READ
# ONLY on a standby when it starts. All go to the standby with the redo.
# On the standby: the apply stopped a moment (dgmgrl), the database and BANKPDB opened READ ONLY, the apply started
# again: Real Time Query, the SELECTs on db2 see the data of db1 within a second. (Active Data Guard: an option of
# Enterprise Edition with its own license; for a lab, to learn.) Again: harmless.
set -euo pipefail
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in db1|db2) ;; *) die "this is $(hostname): adg.sh is for db1, db2" ;; esac
ME=$(hostname -s)
sqlsys() { runuser -l oracle -c "sqlplus -s / as sysdba"; }
dgm() { runuser -l oracle -c "dgmgrl -silent /"; }
q() { printf 'set heading off feedback off pages 0\n%s\n' "$1" | sqlsys | tr -d '[:space:]'; }
ROLE=$(q "select database_role from v\$database;")

if [ "$ROLE" = PRIMARY ]; then
  echo "== $ME: the primary: the services bank_rw, bank_ro and the triggers"
  sqlsys <<'SQL'
whenever sqlerror exit failure
set feedback off serveroutput on
-- the root: the PDBs open READ ONLY on a standby when it starts (Active Data Guard)
create or replace trigger sys.bk_open_pdbs after startup on database
declare
  r varchar2(30);
begin
  select database_role into r from v$database;
  if r = 'PHYSICAL STANDBY' then
    execute immediate 'alter pluggable database all open read only';
  end if;
exception when others then null;
end;
/
alter session set container = BANKPDB;
declare
  procedure mk(n varchar2) is
  begin
    dbms_service.create_service(service_name => n, network_name => n);
  exception when others then
    if sqlcode not in (-44303, -44314, -44773) then raise; end if;   -- (there already)
  end;
begin
  mk('bank_rw');
  mk('bank_ro');
end;
/
-- the services by the role, whenever BANKPDB opens (after a failover, a switchover, a start)
create or replace trigger sys.bk_role_services after startup on database
declare
  r varchar2(30);
  procedure up(n varchar2) is begin dbms_service.start_service(n); exception when others then null; end;
  procedure down(n varchar2) is begin dbms_service.stop_service(n); exception when others then null; end;
begin
  select database_role into r from v$database;
  if r = 'PRIMARY' then
    up('bank_rw');
  else
    down('bank_rw');
  end if;
  up('bank_ro');
end;
/
-- now, without waiting for a start
begin
  begin dbms_service.start_service('bank_rw'); exception when others then null; end;
  begin dbms_service.start_service('bank_ro'); exception when others then null; end;
end;
/
alter system archive log current;
SQL
  echo "== now on db2: sudo bash ~/adg.sh"
elif [ "$ROLE" = PHYSICALSTANDBY ]; then
  MODE=$(q "select open_mode from v\$database;")
  echo "== $ME: the standby ($MODE)"
  if [ "$MODE" != READONLYWITHAPPLY ]; then
    NAME=$(q "select lower(db_unique_name) from v\$database;")
    echo "edit database $NAME set state='APPLY-OFF';" | dgm
    printf 'whenever sqlerror continue\nalter database open read only;\nalter pluggable database all open read only;\n' | sqlsys
    echo "edit database $NAME set state='APPLY-ON';" | dgm
    sleep 10
  fi
  # the services of BANKPDB on the standby: started by the trigger when the PDB opens; now, in case
  printf "alter session set container = BANKPDB;\nexec begin dbms_service.start_service('bank_ro'); exception when others then null; end;\n" | sqlsys >/dev/null || true
else
  die "the role of the database here: $ROLE"
fi

printf 'set lines 160 pages 50\ncol name for a10\ncol open_mode for a22\ncol database_role for a18\nselect database_role, open_mode from v$database;\nselect name, open_mode from v$pdbs;\nalter session set container = BANKPDB;\ncol name for a12\nselect name from v$active_services order by 1;\n' | sqlsys
echo "show configuration;" | dgm | grep -iE "primary|standby|real|SUCCESS|WARNING|ERROR" || true
echo "== $ME: done"
