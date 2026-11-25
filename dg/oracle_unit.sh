#!/bin/bash
# oracle_unit.sh -- on db1 and on db2, as root: the systemd service oracle-bank made again, now with the listener
# (lsnrctl start before dbstart, lsnrctl stop after dbshut). For hosts made before it (primary.sh, standby.sh make
# it so already); the listener started now when it is down. Nothing else changed:
#
#   sudo bash ~/oracle_unit.sh
set -euo pipefail
ORACLE_HOME=/u01/app/oracle/product/26ai/dbhome_1
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in db1|db2) ;; *) die "this is $(hostname): oracle_unit.sh is for db1, db2" ;; esac
[ -x "$ORACLE_HOME/bin/lsnrctl" ] || die "no $ORACLE_HOME/bin/lsnrctl"
cat > /etc/systemd/system/oracle-bank.service <<UNIT
[Unit]
Description=Oracle database BANK and its listener
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
runuser -l oracle -c "lsnrctl status >/dev/null 2>&1 || lsnrctl start >/dev/null"
runuser -l oracle -c "lsnrctl status" | grep -iE "^Service|BANK" | head
echo "== oracle-bank: the listener with the database, from the next start of $(hostname -s)"
