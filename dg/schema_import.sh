#!/bin/bash
# schema_import.sh -- on db1, as root: a schema from forms1 (dg/schema_export.sh put <schema>.dmp and this file in the
# home of chris) into its own PDB of the primary (dg/pdb.sh made it: the services <prefix>_rw / _ro). The mini market:
#
#   sudo bash ~/schema_import.sh MM MMPDB
#
# The schema there already: dropped first (asked: a copy made again); impdp (the password of SYSTEM: asked by impdp;
# the user comes with its own password: the wallet of the domain on forms1 still fits); what Data Pump does not carry
# (the grants on objects of SYS: for MM, DBMS_CRYPTO -- the logins -- and DATA_PUMP_DIR -- its backups); all compiled;
# at the end what is there: the objects, the invalid ones. On db2 it all comes by itself, with the redo.
set -euo pipefail
SCHEMA=$(echo "${1:?the schema, e.g. MM}" | tr '[:lower:]' '[:upper:]')
PDB=$(echo "${2:?its PDB, e.g. MMPDB}" | tr '[:lower:]' '[:upper:]')
NAME=$(echo "$SCHEMA" | tr '[:upper:]' '[:lower:]')
SRC=$(getent passwd "${SUDO_USER:-chris}" | cut -d: -f6)
DP=/u01/app/oracle/dp
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0 $*"
[[ $SCHEMA =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] && [[ $PDB =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "the schema, the PDB: letters, digits, _"
[ "$SCHEMA" != BANK ] || die "the bank: dg/import.sh"
[ "$PDB" != BANKPDB ] || die "BANKPDB is the bank's"
case $(hostname -s) in db1|db2) ;; *) die "this is $(hostname): schema_import.sh is for the primary of Data Guard" ;; esac
sqlsys() { runuser -l oracle -c "sqlplus -s / as sysdba"; }
q() { printf 'set heading off feedback off pages 0\n%s\n' "$1" | sqlsys | tr -d '[:space:]'; }
[ "$(q "select database_role from v\$database;")" = PRIMARY ] || die "the database here is not the primary"
[ "$(q "select count(*) from v\$pdbs where name = '$PDB' and open_mode = 'READ WRITE';")" = 1 ] \
  || die "no PDB $PDB open here: first sudo bash ~/pdb.sh $PDB <prefix>"

echo "== the dump: $DP/$NAME.dmp"
mkdir -p "$DP"
if [ -f "$SRC/$NAME.dmp" ]; then mv -f "$SRC/$NAME.dmp" "$DP/"; fi
[ -f "$DP/$NAME.dmp" ] || die "no $NAME.dmp (on forms1: bash dg/schema_export.sh $SCHEMA)"
chown -R oracle:oinstall "$DP"

if [ "$(q "alter session set container = $PDB;
select count(*) from dba_users where username = '$SCHEMA';")" != 0 ]; then
  read -r -p "== $SCHEMA is in $PDB already: drop it and import again? (yes/no) " a
  [ "$a" = yes ] || die "left as it is"
  sqlsys <<SQL
whenever sqlerror exit failure
alter session set container = $PDB;
begin
  for s in (select sid, serial# from v\$session where username = '$SCHEMA') loop
    execute immediate 'alter system kill session ''' || s.sid || ',' || s.serial# || ''' immediate';
  end loop;
end;
/
drop user $NAME cascade;
SQL
fi

echo "== the directory BK_DP; impdp (the password of SYSTEM)"
printf "alter session set container = %s;\ncreate or replace directory bk_dp as '%s';\n" "$PDB" "$DP" | sqlsys >/dev/null
set +e
# (the alias of the PDB in the tnsnames.ora of db1: dg/pdb.sh)
runuser -l oracle -c "impdp system@$PDB directory=BK_DP dumpfile=$NAME.dmp logfile=${NAME}_imp.log"
rc=$?
set -e
# (5: done, with warnings: e.g. packages before their grants; compiled below)
[ $rc = 0 ] || [ $rc = 5 ] || die "impdp: $rc ($DP/${NAME}_imp.log)"

echo "== the grants on objects of SYS; compile"
GRANTS=
if [ "$SCHEMA" = MM ]; then
  GRANTS="grant execute on sys.dbms_crypto to mm;
grant read, write on directory data_pump_dir to mm;"
fi
sqlsys <<SQL
whenever sqlerror exit failure
set feedback off lines 160 pages 100
alter session set container = $PDB;
$GRANTS
exec dbms_utility.compile_schema('$SCHEMA', compile_all => false)
whenever sqlerror continue
prompt == $SCHEMA in $PDB
col object_type for a20
col object_name for a32
select object_type, count(*) n from dba_objects where owner = '$SCHEMA' group by object_type order by 1;
prompt == invalid (none: good)
select object_type, object_name from dba_objects where owner = '$SCHEMA' and status <> 'VALID' order by 1, 2;
SQL
echo "== $SCHEMA in $PDB on db1 (and on db2 with the redo). Next, on forms1: its alias to Data Guard (dg/apps_forms.sh)"
