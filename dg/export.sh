#!/bin/bash
# export.sh -- on forms1, as oracle: the schema BANK of the database Free (FREEPDB1) to db1 (dg/import.sh):
#
#   cd ~/bank && bash dg/export.sh
#
# expdp of the schema BANK (its tables, packages, the models of the AI, the user and its privileges; consistent:
# at one moment), in /home/oracle/dp; with it the file of the model of embeddings (ai/models) and the guides (docs/)
# for the AI, and dg/import.sh; all to the home of chris on db1 (scp: the password of chris on db1). The password of
# SYSTEM: asked by expdp. The database here stays as it was: the applications go on with it. Again any time: a new
# copy (the last, when the applications move to db1: with them stopped first).
set -euo pipefail
DB1=${BK_DB1:-192.168.178.221}
PDB=${BK_SRC_PDB:-FREEPDB1}
REPO=$(cd "$(dirname "$0")/.." && pwd)
DP=$HOME/dp
die() { echo "== $*" >&2; exit 1; }
[ "$(id -un)" = oracle ] || die "as oracle (sudo su - oracle)"
case $(hostname -s) in forms1*) ;; *) die "this is $(hostname): export.sh is for forms1" ;; esac
command -v expdp >/dev/null || die "no expdp: the environment of oracle (ORACLE_HOME, PATH)"
mkdir -p "$DP"
rm -f "$DP/bank.dmp" "$DP/bank_exp.log"

echo "== the directory BK_DP ($DP) in $PDB"
sqlplus -s / as sysdba <<SQL
whenever sqlerror exit failure
alter session set container = $PDB;
create or replace directory bk_dp as '$DP';
exit
SQL

echo "== expdp of BANK (the password of SYSTEM)"
set +e
expdp "system@//localhost:1521/$PDB" schemas=BANK directory=BK_DP dumpfile=bank.dmp logfile=bank_exp.log \
  flashback_time=systimestamp exclude=statistics
rc=$?
set -e
[ $rc = 0 ] || [ $rc = 5 ] || die "expdp: $rc ($DP/bank_exp.log)"

echo "== the files of the AI: ai/models, docs"
[ -f "$REPO/ai/models/bk_embed.onnx" ] || echo "== (no ai/models/bk_embed.onnx: the model of embeddings comes with the schema anyway)"
tar -C "$REPO" -czf "$DP/bank_files.tgz" docs $(cd "$REPO" && ls ai/models/bk_embed.onnx 2>/dev/null || true)
ls -l "$DP/bank.dmp" "$DP/bank_files.tgz"

echo "== to db1 ($DB1): the password of chris on db1"
scp "$DP/bank.dmp" "$DP/bank_files.tgz" "$REPO/dg/import.sh" "chris@$DB1:"
echo "== now on db1: sudo bash ~/import.sh"
