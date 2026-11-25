#!/bin/bash
# standby.sh -- the physical standby of the bank on db2 (its software: dg/db_host.sh; the primary on db1:
# dg/primary.sh). As root on db2, with the password file of db1 in the home of chris (docs/ODIGIES_DG.md):
#
#   sudo bash ~/standby.sh
#
# The listener (a static entry BANK_DB2 for RMAN while the instance is only started, BANK_DB2_DGMGRL for the broker),
# tnsnames.ora as on db1; the password file of db1 (the same, or the redo is refused); an instance started NOMOUNT;
# then RMAN DUPLICATE ... FOR STANDBY FROM ACTIVE DATABASE: the files over the network from db1, no backup, the
# spfile of db1 with db_unique_name BANK_DB2. RMAN asks the password of SYS twice (db1, db2: the same one). Then
# flashback, the database with the VM (systemd oracle-bank). The broker: dg/broker.sh on db1.
set -euo pipefail
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=$ORACLE_BASE/product/26ai/dbhome_1
SID=BANK
UNIQUE=BANK_DB2
SRC=$(getent passwd "${SUDO_USER:-chris}" | cut -d: -f6)
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in
  db2) ;;
  *) die "this is $(hostname): standby.sh is for db2 only (db1: primary.sh)" ;;
esac
[ -x "$ORACLE_HOME/bin/rman" ] || die "no $ORACLE_HOME/bin/rman: first dg/db_host.sh"
ora() { runuser -l oracle -c "$1"; }
sqlsys() { runuser -l oracle -c "sqlplus -s / as sysdba"; }
# running or not: asked to the instance itself (the names of its processes differ by version)
running() { printf 'set heading off feedback off pages 0\nselect status from v$instance;\n' | sqlsys 2>/dev/null | grep -qE '^(STARTED|MOUNTED|OPEN)'; }
dgm() { runuser -l oracle -c "dgmgrl -silent /"; }

echo "== the password file of db1"
PW=$ORACLE_HOME/dbs/orapw$SID
if [ -f "$SRC/orapw$SID" ]; then
  install -o oracle -g oinstall -m 640 "$SRC/orapw$SID" "$PW"
  rm -f "$SRC/orapw$SID"
fi
[ -f "$PW" ] || die "no orapw$SID: copy it from db1 first (docs/ODIGIES_DG.md §7)"

echo "== the listener and tnsnames.ora"
NET=$ORACLE_HOME/network/admin
cat > "$NET/listener.ora" <<LSNR
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = db2.home.lan)(PORT = 1521)))
    (DESCRIPTION = (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1521))))
# static: RMAN connects to the instance while it is only started (NOMOUNT); the broker starts it when it is down
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC = (GLOBAL_DBNAME = ${UNIQUE})(ORACLE_HOME = $ORACLE_HOME)(SID_NAME = $SID))
    (SID_DESC = (GLOBAL_DBNAME = ${UNIQUE}_DGMGRL)(ORACLE_HOME = $ORACLE_HOME)(SID_NAME = $SID)))
LSNR
cat > "$NET/tnsnames.ora" <<'TNS'
BANK_DB1 = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = db1.home.lan)(PORT = 1521))
  (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = BANK_DB1)))
BANK_DB2 = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = db2.home.lan)(PORT = 1521))
  (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = BANK_DB2)(UR = A)))
# the PDB of the bank on whichever host it is open
BANKPDB = (DESCRIPTION = (CONNECT_TIMEOUT = 5)(RETRY_COUNT = 3)(FAILOVER = on)
  (ADDRESS_LIST = (LOAD_BALANCE = off)
    (ADDRESS = (PROTOCOL = TCP)(HOST = db1.home.lan)(PORT = 1521))
    (ADDRESS = (PROTOCOL = TCP)(HOST = db2.home.lan)(PORT = 1521)))
  (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = BANKPDB)))
TNS
chown oracle:oinstall "$NET/listener.ora" "$NET/tnsnames.ora"
ora "lsnrctl status >/dev/null 2>&1 && lsnrctl reload >/dev/null || lsnrctl start >/dev/null"

ROLE=""
if running; then
  ROLE=$(printf 'set heading off feedback off pages 0\nselect database_role from v$database;\n' | sqlsys 2>/dev/null | tr -d '[:space:]' || true)
fi
if [ "$ROLE" = PHYSICALSTANDBY ]; then
  echo "== the standby is here already"
else
  echo "== an instance NOMOUNT for RMAN"
  mkdir -p "$ORACLE_BASE/admin/$SID/adump" "$ORACLE_BASE/oradata/$UNIQUE" "$ORACLE_BASE/fast_recovery_area/$UNIQUE"
  chown -R oracle:oinstall "$ORACLE_BASE/admin" "$ORACLE_BASE/oradata" "$ORACLE_BASE/fast_recovery_area"
  echo "db_name=$SID" > "$ORACLE_HOME/dbs/init$SID.ora"
  chown oracle:oinstall "$ORACLE_HOME/dbs/init$SID.ora"
  if running; then echo "shutdown abort" | sqlsys >/dev/null; fi
  echo "startup nomount pfile='$ORACLE_HOME/dbs/init$SID.ora'" | sqlsys
  grep -q "^$SID:" /etc/oratab || echo "$SID:$ORACLE_HOME:Y" >> /etc/oratab

  echo "== RMAN DUPLICATE FOR STANDBY FROM ACTIVE DATABASE (some 10-30 minutes)"
  echo "   RMAN asks the password of SYS: twice (target: db1, auxiliary: db2; the same one)"
  RMF=$ORACLE_BASE/dup_standby.rman
  cat > "$RMF" <<RMAN
run {
  allocate channel p1 type disk;
  allocate channel p2 type disk;
  allocate auxiliary channel s1 type disk;
  allocate auxiliary channel s2 type disk;
  duplicate target database for standby from active database using compressed backupset
    spfile
      parameter_value_convert 'BANK_DB1', '$UNIQUE'
      set db_unique_name = '$UNIQUE'
      set control_files = '$ORACLE_BASE/oradata/$UNIQUE/control01.ctl', '$ORACLE_BASE/fast_recovery_area/$UNIQUE/control02.ctl'
      set audit_file_dest = '$ORACLE_BASE/admin/$SID/adump'
      set fal_server = 'BANK_DB1'
      set log_archive_dest_2 = ''
    nofilenamecheck;
}
RMAN
  chown oracle:oinstall "$RMF"
  ora "rman target sys@BANK_DB1 auxiliary sys@BANK_DB2 cmdfile=$RMF log=$ORACLE_BASE/dup_standby.log" \
    || die "RMAN failed: $ORACLE_BASE/dup_standby.log (its end: sudo tail -40 $ORACLE_BASE/dup_standby.log)"
  rm -f "$ORACLE_HOME/dbs/init$SID.ora"
fi

echo "== the broker started"
sqlsys <<'SQL'
whenever sqlerror exit failure
set feedback off
alter system set dg_broker_start = TRUE scope = both;
alter system set standby_file_management = AUTO scope = both;
SQL

# flashback (Fast-Start Failover wants it): on a standby only with the apply stopped, and only once the files are
# recovered enough (ORA-38788 right after the duplicate): so after the broker (dg/broker.sh on db1) applies the redo
FB=$(printf 'set heading off feedback off pages 0\nselect flashback_on from v$database;\n' | sqlsys | tr -d '[:space:]')
if [ "$FB" = YES ]; then
  echo "== flashback: on"
elif echo "show configuration;" | dgm | grep -qi "bank_db2"; then  # (the member: its words may be Greek)
  echo "== flashback: the apply stopped a moment"
  echo "edit database bank_db2 set state='APPLY-OFF';" | dgm
  printf 'whenever sqlerror continue\nalter database flashback on;\n' | sqlsys
  echo "edit database bank_db2 set state='APPLY-ON';" | dgm
else
  echo "== flashback: not yet (first the broker: sudo bash ~/broker.sh on db1; then this again)"
fi

echo "== the database with the VM: systemd oracle-bank"
cat > /etc/systemd/system/oracle-bank.service <<UNIT
[Unit]
Description=Oracle database $SID and its listener
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=oracle
Group=oinstall
Environment=ORACLE_HOME=$ORACLE_HOME
# the listener first, always (dbstart alone left it down after a power off: no reinstate, no redo)
ExecStartPre=-$ORACLE_HOME/bin/lsnrctl start
ExecStart=$ORACLE_HOME/bin/dbstart $ORACLE_HOME
ExecStop=$ORACLE_HOME/bin/dbshut $ORACLE_HOME
ExecStopPost=-$ORACLE_HOME/bin/lsnrctl stop
TimeoutStartSec=600
TimeoutStopSec=600

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable -q oracle-bank

printf 'set lines 160\ncol name for a8\ncol db_unique_name for a12\nselect name, db_unique_name, database_role, open_mode, flashback_on from v$database;\n' | sqlsys
echo "== $UNIQUE ready. Next on db1: sudo bash ~/broker.sh (docs/ODIGIES_DG.md §8)"
