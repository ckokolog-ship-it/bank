#!/bin/bash
# broker.sh -- on db1 (the primary), as root, once the standby on db2 is there (dg/standby.sh): the Data Guard
# Broker: the configuration BANK of BANK_DB1 (primary) and BANK_DB2 (physical standby), enabled; the redo then goes
# to db2 by itself and is applied there. dgmgrl as sysdba of this host (no password); at the end what it says:
#
#   sudo bash ~/broker.sh
#
# Again: the configuration there already is left, only shown. Fast-Start Failover (the observer on forms1): next.
set -euo pipefail
ORACLE_HOME=/u01/app/oracle/product/26ai/dbhome_1
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in db1) ;; *) die "this is $(hostname): broker.sh is for db1" ;; esac
dg() { runuser -l oracle -c "dgmgrl -silent /"; }
if echo "show configuration;" | dg | grep -q "ORA-16532"; then
  echo "== the configuration BANK"
  dg <<'DG'
create configuration bank as primary database is BANK_DB1 connect identifier is BANK_DB1;
add database BANK_DB2 as connect identifier is BANK_DB2;
enable configuration;
DG
  echo "== a minute for the redo to start"
  sleep 60
else
  echo "== the configuration is there already"
fi
dg <<'DG'
show configuration;
show database BANK_DB2;
validate database BANK_DB2;
DG
