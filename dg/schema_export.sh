#!/bin/bash
# schema_export.sh -- on forms1, as oracle: the schema of another application of the database Free (FREEPDB1) to db1,
# for its own PDB on Data Guard (dg/pdb.sh first, on db1; then dg/schema_import.sh there). The mini market:
#
#   cd ~/bank && bash dg/schema_export.sh MM
#
# expdp of the schema (its tables, packages, the user with its password; consistent: at one moment) in
# /home/oracle/dp; then the dump and dg/schema_import.sh to the home of chris on db1 (scp: the password of chris on
# db1). The password of SYSTEM: asked by expdp. The database here stays as it was: the application goes on with it
# until its alias is moved (dg/apps_forms.sh). Again any time: a new copy (the last one with the application
# stopped). The bank has its own (dg/export.sh: its files of the AI too).
set -euo pipefail
SCHEMA=$(echo "${1:?the schema, e.g. MM}" | tr '[:lower:]' '[:upper:]')
DB1=${BK_DB1:-192.168.178.221}
PDB=${BK_SRC_PDB:-FREEPDB1}
REPO=$(cd "$(dirname "$0")/.." && pwd)
DP=$HOME/dp
NAME=$(echo "$SCHEMA" | tr '[:upper:]' '[:lower:]')
die() { echo "== $*" >&2; exit 1; }
[[ $SCHEMA =~ ^[A-Z][A-Z0-9_]{0,29}$ ]] || die "the schema: letters, digits, _"
[ "$SCHEMA" != BANK ] || die "the bank: dg/export.sh (its files of the AI too)"
[ "$(id -un)" = oracle ] || die "as oracle (sudo su - oracle)"
case $(hostname -s) in forms1*) ;; *) die "this is $(hostname): schema_export.sh is for forms1" ;; esac
command -v expdp >/dev/null || die "no expdp: the environment of oracle (ORACLE_HOME, PATH)"
mkdir -p "$DP"
rm -f "$DP/$NAME.dmp" "$DP/${NAME}_exp.log"

echo "== the directory BK_DP ($DP) in $PDB"
sqlplus -s / as sysdba <<SQL
whenever sqlerror exit failure
alter session set container = $PDB;
create or replace directory bk_dp as '$DP';
exit
SQL
N=$(printf "set heading off feedback off pages 0\nalter session set container = %s;\nselect count(*) from dba_users where username = '%s';\n" "$PDB" "$SCHEMA" \
  | sqlplus -s / as sysdba | tr -d '[:space:]')
[ "$N" = 1 ] || die "no user $SCHEMA in $PDB"

echo "== expdp of $SCHEMA (the password of SYSTEM)"
set +e
# (an alias, not //host:port/service: Data Pump splits user/password at its slashes; its own tnsnames.ora)
mkdir -p "$DP/tns"
printf '%s_DP = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = localhost)(PORT = 1521))\n  (CONNECT_DATA = (SERVICE_NAME = %s)))\n' "$PDB" "$PDB" > "$DP/tns/tnsnames.ora"
TNS_ADMIN=$DP/tns expdp "system@${PDB}_DP" schemas="$SCHEMA" directory=BK_DP dumpfile="$NAME.dmp" logfile="${NAME}_exp.log" \
  flashback_time=systimestamp exclude=statistics
rc=$?
set -e
[ $rc = 0 ] || [ $rc = 5 ] || die "expdp: $rc ($DP/${NAME}_exp.log)"
ls -l "$DP/$NAME.dmp"

echo "== to db1 ($DB1): the password of chris on db1"
scp "$DP/$NAME.dmp" "$REPO/dg/schema_import.sh" "chris@$DB1:"
echo "== now on db1: sudo bash ~/schema_import.sh $SCHEMA <its PDB, e.g. MMPDB>"
