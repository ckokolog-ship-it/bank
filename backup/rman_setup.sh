#!/bin/bash
# rman_setup.sh -- on db1 and on db2, as root: the backups of BANK with RMAN (backup/nfs_client.sh first: /backup of
# em1 here) -- docs/ODIGIES_BACKUP.md:
#
#   sudo bash ~/rman_setup.sh            (rman_backup.sh beside it, in the home of chris)
#   sudo bash ~/rman_setup.sh --now      and a first backup (level 0) now, on the primary
#
# 1. RMAN of this host (its control file): the retention a recovery window of 7 days, the control file and the spfile
#    backed up by themselves after every backup (to /backup/BANK), compressed backup sets (BASIC: no extra licence),
#    2 channels, the archived logs deleted only when applied on the standby and in a backup.
# 2. Block change tracking (the level 1 reads only the changed blocks): on the primary, and on the standby too
#    (Active Data Guard): after a switchover it is there.
# 3. rman_backup.sh to /usr/local/bin, and the timers of systemd (as oracle): level0 Sunday 01:30, level1 the other
#    days 01:30, arch every 4 hours. On both hosts: only the primary backs up (rman_backup.sh asks the role).
set -euo pipefail
NOW=
[ "${1:-}" = --now ] && NOW=1
ORACLE_HOME=/u01/app/oracle/product/26ai/dbhome_1
DEST=/backup/BANK
SRC=$(dirname "$(readlink -f "$0")")
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0 $*"
case $(hostname -s) in db1|db2) ;; *) die "this is $(hostname): rman_setup.sh is for db1 and db2 (Data Guard)" ;; esac
[ -f "$SRC/rman_backup.sh" ] || die "no rman_backup.sh beside this file ($SRC)"
findmnt -n /backup >/dev/null || die "no /backup here: sudo bash ~/nfs_client.sh"
runuser -u oracle -- test -w "$DEST" || die "oracle cannot write in $DEST"
O() { runuser -l oracle -c "$*"; }
ROLE=$(printf 'set heading off feedback off pages 0\nselect database_role from v$database;\n' | O "sqlplus -s / as sysdba" | tr -d '[:space:]')
echo "== $(hostname -s): BANK $ROLE"

echo "== 1. RMAN: retention 7 days, autobackup of the control file, compressed, to $DEST"
O "rman target /" <<RMAN
configure retention policy to recovery window of 7 days;
configure controlfile autobackup on;
configure controlfile autobackup format for device type disk to '$DEST/cf_%F';
configure device type disk parallelism 2 backup type to compressed backupset;
configure channel device type disk format '$DEST/%d_%T_%U';
configure compression algorithm 'BASIC';
configure archivelog deletion policy to applied on all standby backed up 1 times to device type disk;
show all;
RMAN

echo "== 2. block change tracking"
O "sqlplus -s / as sysdba" <<'SQL'
set feedback off heading off
whenever sqlerror continue
declare n number; begin
  select count(*) into n from v$block_change_tracking where status = 'ENABLED';
  if n = 0 then execute immediate 'alter database enable block change tracking'; end if;
exception when others then dbms_output.put_line('(block change tracking: ' || sqlerrm || ')');
end;
/
select 'block change tracking: ' || status || ' ' || filename from v$block_change_tracking;
exit
SQL

echo "== 3. rman_backup.sh and the timers"
install -o root -g root -m 755 "$SRC/rman_backup.sh" /usr/local/bin/rman_backup.sh
cat > /etc/systemd/system/rman-bank@.service <<UNIT
[Unit]
Description=RMAN: a backup of BANK (%i) to /backup of em1
After=oracle-bank.service remote-fs.target
RequiresMountsFor=/backup

[Service]
Type=oneshot
User=oracle
Group=oinstall
Environment=ORACLE_HOME=$ORACLE_HOME ORACLE_SID=BANK
ExecStart=/usr/local/bin/rman_backup.sh %i
TimeoutStartSec=6h
UNIT
timer() { # name, OnCalendar, the kind
  cat > "/etc/systemd/system/rman-bank-$1.timer" <<UNIT
[Unit]
Description=RMAN: $3 of BANK ($2)

[Timer]
OnCalendar=$2
Unit=rman-bank@$3.service
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
UNIT
}
timer level0 'Sun *-*-* 01:30' level0
timer level1 'Mon..Sat *-*-* 01:30' level1
timer arch '*-*-* 00/4:15' arch
systemctl daemon-reload
systemctl enable -q --now rman-bank-level0.timer rman-bank-level1.timer rman-bank-arch.timer
systemctl list-timers 'rman-bank-*' --no-pager

if [ -n "$NOW" ]; then
  if [ "$ROLE" = PRIMARY ]; then
    echo "== a first backup now (level 0: some minutes)"
    systemctl start rman-bank@level0.service || die "the backup failed: journalctl -u rman-bank@level0 -n 50"
    systemctl status rman-bank@level0.service --no-pager -n 15 || true
  else
    echo "== (--now: this host is $ROLE: the first backup on the primary)"
  fi
fi
echo "== the backups of BANK on $(hostname -s). Their logs: $DEST/logs"
