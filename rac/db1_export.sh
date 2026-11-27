#!/bin/bash
# db1_export.sh -- on db1 (the primary of Data Guard, the laptop), as root: the schema BANK as it is now, for the
# RAC of the lab (the i9): expdp of BANK from BANKPDB (consistent), the files of the AI (/u01/app/oracle/bank: the
# model of embeddings, the guides), and rac/rac_bank.sh; all to the home of chris on rac1 (scp: its password).
# The password of SYSTEM of db1 asked by expdp (an @ in it: the password within double quotes). Nothing changes on
# db1: the bank goes on with it.
#
#   sudo bash ~/db1_export.sh
set -euo pipefail
RAC1=${BK_RAC1:-192.168.178.231}
ORACLE_BASE=/u01/app/oracle
DP=$ORACLE_BASE/dp
CHRIS=${SUDO_USER:-chris}
HOME_C=$(getent passwd "$CHRIS" | cut -d: -f6)
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in db1|db2) ;; *) die "this is $(hostname): db1_export.sh is for the primary of Data Guard" ;; esac
sqlsys() { runuser -l oracle -c "sqlplus -s / as sysdba"; }
ROLE=$(printf 'set heading off feedback off pages 0\nselect database_role from v$database;\n' | sqlsys | tr -d '[:space:]')
[ "$ROLE" = PRIMARY ] || die "the database here is $ROLE: run it on the primary"
[ -f "$HOME_C/rac_bank.sh" ] || die "no ~/rac_bank.sh (from forms1: scp rac/rac_bank.sh chris@$(hostname -s):)"

mkdir -p "$DP" && chown oracle:oinstall "$DP"
rm -f "$DP/bank_rac.dmp" "$DP/bank_rac_exp.log"
printf "alter session set container = BANKPDB;\ncreate or replace directory bk_dp as '%s';\n" "$DP" | sqlsys >/dev/null
echo "== expdp of BANK (the password of SYSTEM of this database)"
set +e
runuser -l oracle -c "expdp system@BANKPDB schemas=BANK directory=BK_DP dumpfile=bank_rac.dmp logfile=bank_rac_exp.log flashback_time=systimestamp exclude=statistics"
rc=$?
set -e
[ $rc = 0 ] || [ $rc = 5 ] || die "expdp: $rc ($DP/bank_rac_exp.log)"
tar -C "$ORACLE_BASE/bank" -czf "$DP/bank_rac_files.tgz" .
chmod 644 "$DP/bank_rac.dmp" "$DP/bank_rac_files.tgz"
ls -l "$DP/bank_rac.dmp" "$DP/bank_rac_files.tgz"
echo "== to rac1 ($RAC1): the password of chris on rac1"
runuser -u "$CHRIS" -- scp -o StrictHostKeyChecking=accept-new "$DP/bank_rac.dmp" "$DP/bank_rac_files.tgz" "$HOME_C/rac_bank.sh" "chris@$RAC1:"
echo "== now on rac1: sudo bash ~/rac_bank.sh"
