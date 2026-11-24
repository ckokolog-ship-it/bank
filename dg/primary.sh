#!/bin/bash
# primary.sh -- the database of the bank on db1 (its software: dg/db_host.sh): the CDB BANK with the PDB BANKPDB,
# ready for Data Guard (the standby on db2: dg/standby.sh). As root on db1:
#
#   sudo bash ~/primary.sh
#
# The listener (port 1521, a static entry for the broker), tnsnames.ora with both hosts (BANK_DB1, BANK_DB2,
# BANKPDB); then dbca without windows: Enterprise Edition, AL32UTF8, OMF files in /u01/app/oracle/oradata, archive
# log on, a fast recovery area of 30 GB. The passwords of SYS, SYSTEM and of the admin of the PDB: asked by dbca
# itself, never on the command line, never in a file. Then what Data Guard wants: db_unique_name BANK_DB1, force
# logging, flashback, standby redo logs, standby_file_management AUTO, the broker started; the PDB opened at every
# start; the database and the listener started with the VM (systemd: oracle-bank). Again: what is there is left.
set -euo pipefail
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=$ORACLE_BASE/product/26ai/dbhome_1
SID=BANK
UNIQUE=BANK_DB1
MEM_MB=${BK_DB_MEM_MB:-3072}
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in
  db1) ;;
  *) die "this is $(hostname): primary.sh is for db1 only (db2: standby.sh)" ;;
esac
[ -x "$ORACLE_HOME/bin/dbca" ] || die "no $ORACLE_HOME/bin/dbca: first dg/db_host.sh"
ora() { runuser -l oracle -c "$1"; }
sqlsys() { runuser -l oracle -c "sqlplus -s / as sysdba" ; }

echo "== the listener and tnsnames.ora"
NET=$ORACLE_HOME/network/admin
cat > "$NET/listener.ora" <<LSNR
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = db1.home.lan)(PORT = 1521)))
    (DESCRIPTION = (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1521))))
# static: the broker starts an instance that is down (switchover, reinstate)
SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC = (GLOBAL_DBNAME = ${UNIQUE}_DGMGRL)(ORACLE_HOME = $ORACLE_HOME)(SID_NAME = $SID)))
LSNR
cat > "$NET/tnsnames.ora" <<'TNS'
BANK_DB1 = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = db1.home.lan)(PORT = 1521))
  (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = BANK_DB1)))
BANK_DB2 = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = db2.home.lan)(PORT = 1521))
  (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = BANK_DB2)))
# the PDB of the bank on whichever host it is open
BANKPDB = (DESCRIPTION = (CONNECT_TIMEOUT = 5)(RETRY_COUNT = 3)(FAILOVER = on)
  (ADDRESS_LIST = (LOAD_BALANCE = off)
    (ADDRESS = (PROTOCOL = TCP)(HOST = db1.home.lan)(PORT = 1521))
    (ADDRESS = (PROTOCOL = TCP)(HOST = db2.home.lan)(PORT = 1521)))
  (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = BANKPDB)))
TNS
chown oracle:oinstall "$NET/listener.ora" "$NET/tnsnames.ora"
ora "lsnrctl status >/dev/null 2>&1 && lsnrctl reload >/dev/null || lsnrctl start >/dev/null"

if grep -q "^$SID:" /etc/oratab 2>/dev/null; then
  echo "== the database $SID exists already (/etc/oratab)"
else
  echo "== dbca: the CDB $SID with the PDB BANKPDB (some 15-30 minutes)"
  echo "   dbca asks the passwords: SYS, SYSTEM, the admin of the PDB (best: the same strong one; keep it)"
  ora "dbca -silent -createDatabase -templateName General_Purpose.dbc \
    -gdbName $SID -sid $SID -databaseConfigType SINGLE \
    -createAsContainerDatabase true -numberOfPDBs 1 -pdbName BANKPDB -useLocalUndoForPDBs true \
    -storageType FS -datafileDestination $ORACLE_BASE/oradata -useOMF true \
    -recoveryAreaDestination $ORACLE_BASE/fast_recovery_area -recoveryAreaSize 30720 -enableArchive true \
    -characterSet AL32UTF8 -nationalCharacterSet AL16UTF16 \
    -memoryMgmtType AUTO_SGA -totalMemory $MEM_MB -redoLogFileSize 200 \
    -emConfiguration NONE" || die "dbca failed (its log: $ORACLE_BASE/cfgtoollogs/dbca/$SID/)"
fi
pgrep -x "ora_pmon_$SID" >/dev/null || echo "startup" | sqlsys

echo "== Data Guard: db_unique_name $UNIQUE, force logging, flashback, standby redo logs, the broker"
CUR=$(printf 'set heading off feedback off pages 0\nselect value from v$parameter where name = %s;\n' "'db_unique_name'" | sqlsys | tr -d '[:space:]')
if [ "$CUR" != "$UNIQUE" ]; then
  printf "alter system set db_unique_name='%s' scope=spfile;\nshutdown immediate\nstartup\n" "$UNIQUE" | sqlsys
fi
sqlsys <<'SQL'
whenever sqlerror exit failure
set feedback off
declare
  n number;
  sz number;
  procedure x(s varchar2) is begin execute immediate s; end;
begin
  select count(*) into n from v$database where force_logging = 'YES';
  if n = 0 then x('alter database force logging'); end if;
  select count(*) into n from v$database where flashback_on = 'YES';
  if n = 0 then x('alter database flashback on'); end if;
  x('alter system set standby_file_management = AUTO scope = both');
  x('alter system set db_flashback_retention_target = 1440 scope = both');
  -- the standby redo logs: as large as the redo logs, one group more (also used here after a role change)
  select max(bytes) into sz from v$log;
  select count(*) into n from v$standby_log;
  for i in n + 1 .. 4 loop
    x('alter database add standby logfile thread 1 size ' || sz);
  end loop;
  x('alter system set dg_broker_start = TRUE scope = both');
  select count(*) into n from v$pdbs where name = 'BANKPDB' and open_mode = 'READ WRITE';
  if n = 0 then x('alter pluggable database BANKPDB open'); end if;
end;
/
SQL
echo "alter pluggable database BANKPDB save state;" | sqlsys >/dev/null || true

echo "== the database with the VM: /etc/oratab Y, systemd oracle-bank"
sed -i "s#^$SID:\([^:]*\):N#$SID:\1:Y#" /etc/oratab
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
ExecStart=$ORACLE_HOME/bin/dbstart $ORACLE_HOME
ExecStop=$ORACLE_HOME/bin/dbshut $ORACLE_HOME
TimeoutStartSec=600
TimeoutStopSec=600

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable -q oracle-bank

printf 'set lines 160 pages 50\ncol name for a12\ncol db_unique_name for a12\ncol open_mode for a12\nselect name, db_unique_name, database_role, open_mode, log_mode, force_logging, flashback_on from v$database;\nselect name, open_mode from v$pdbs;\nselect group#, bytes/1048576 mb from v$standby_log;\n' | sqlsys
echo "== $UNIQUE ready. Try: sqlplus system@BANKPDB. Next: docs/ODIGIES_DG.md (the schema BANK from forms1)"
