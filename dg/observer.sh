#!/bin/bash
# observer.sh -- on forms1, as root: the observer of Fast-Start Failover (dg/fsfo.sh on db1). A third host: it sees
# db1 and db2, and when the primary is gone (THRESHOLD seconds) while it and the standby still see each other, it
# makes the standby the primary. dgmgrl of the database of forms1 (its own home: the Free); its own network files
# in /home/oracle/dg (TNS_ADMIN: the rest of forms1 untouched): tnsnames.ora with BANK_DB1, BANK_DB2, and a wallet
# with the password of SYS for both (mkstore asks a password for the wallet and the one of SYS; never in a file in
# clear); then a systemd service dg-observer that keeps it running (and starts it with forms1):
#
#   sudo bash /home/oracle/bank/dg/observer.sh        (as chris: /home/oracle is closed to chris, not to sudo)
set -euo pipefail
DIR=/home/oracle/dg
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in forms1*) ;; *) die "this is $(hostname): observer.sh is for forms1 (a third host)" ;; esac
OH=$(awk -F: '/^[A-Za-z0-9_]+:\// && $2 != "" {print $2; exit}' /etc/oratab)
[ -n "$OH" ] || OH=$(runuser -l oracle -c 'echo $ORACLE_HOME')
[ -x "$OH/bin/dgmgrl" ] || die "no dgmgrl in $OH/bin (docs/ODIGIES_DG.md §9: what then)"
[ -x "$OH/bin/mkstore" ] || die "no mkstore in $OH/bin"
ora() { runuser -l oracle -c "export TNS_ADMIN=$DIR ORACLE_HOME=$OH PATH=$OH/bin:\$PATH; $1"; }

echo "== $DIR: tnsnames.ora, sqlnet.ora (the wallet)"
mkdir -p "$DIR/wallet"
cat > "$DIR/tnsnames.ora" <<'TNS'
BANK_DB1 = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.178.221)(PORT = 1521))
  (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = BANK_DB1)))
BANK_DB2 = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = 192.168.178.222)(PORT = 1521))
  (CONNECT_DATA = (SERVER = DEDICATED)(SERVICE_NAME = BANK_DB2)))
TNS
cat > "$DIR/sqlnet.ora" <<SQLNET
WALLET_LOCATION = (SOURCE = (METHOD = FILE)(METHOD_DATA = (DIRECTORY = $DIR/wallet)))
SQLNET.WALLET_OVERRIDE = TRUE
SQLNET
chown -R oracle:oinstall "$DIR"
chmod 700 "$DIR/wallet"

if [ ! -f "$DIR/wallet/cwallet.sso" ]; then
  echo "== the wallet: first its own password (twice: a new one, any), then the one of SYS of BANK (twice)"
  ora "mkstore -wrl $DIR/wallet -create"
  ora "mkstore -wrl $DIR/wallet -createCredential BANK_DB1 sys"
  ora "mkstore -wrl $DIR/wallet -createCredential BANK_DB2 sys"
fi
echo "== the wallet works: dgmgrl /@BANK_DB1"
# (the whole output first: grep -q stops reading early, and with pipefail that counted as a failure)
OUT=$(echo "show configuration;" | ora "dgmgrl -silent /@BANK_DB1" 2>&1 || true)
echo "$OUT"
grep -qi "bank_db2" <<<"$OUT" \
  || die "dgmgrl /@BANK_DB1 did not connect (the password of SYS in the wallet? mkstore -wrl $DIR/wallet -modifyCredential BANK_DB1 sys)"

echo "== systemd: dg-observer"
cat > /etc/systemd/system/dg-observer.service <<UNIT
[Unit]
Description=Data Guard observer of BANK (Fast-Start Failover)
After=network-online.target
Wants=network-online.target

[Service]
User=oracle
Group=oinstall
Environment=ORACLE_HOME=$OH
Environment=TNS_ADMIN=$DIR
WorkingDirectory=$DIR
ExecStart=$OH/bin/dgmgrl -silent /@BANK_DB1 "start observer bank_obs file is '$DIR/fsfo.dat' logfile is '$DIR/observer.log'"
ExecStop=$OH/bin/dgmgrl -silent /@BANK_DB1 "stop observer bank_obs"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable -q --now dg-observer
sleep 15
systemctl --no-pager status dg-observer | head -5
echo "show fast_start failover;" | ora "dgmgrl -silent /@BANK_DB1"
echo "== the observer: running. Its log: $DIR/observer.log"
