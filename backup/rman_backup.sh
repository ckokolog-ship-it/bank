#!/bin/bash
# rman_backup.sh -- the backups of the database BANK of Data Guard with RMAN, to /backup of em1 (NFS), as oracle; run
# by the timers of systemd that backup/rman_setup.sh installed on db1 and db2 (docs/ODIGIES_BACKUP.md):
#
#   rman_backup.sh level0      every Sunday: the whole database (all its PDBs: BANKPDB, PROPOPDB, MMPDB, ...)
#   rman_backup.sh level1      the other days: what changed since the last level 0 (block change tracking: fast)
#   rman_backup.sh arch        every 4 hours: the archived logs not in a backup yet
#
# Only the primary backs up -- after a switchover or a failover the other host by itself; first the backups in the
# shared folder are cataloged, so the primary of now knows those of the primary of before. The standby only catalogs
# them and deletes its archived logs that the policy allows (applied, and in a backup): its recovery area does not
# fill. Then what the retention (7 days) no longer needs: deleted. Its log in /backup/BANK/logs; an error of RMAN:
# exit 1 (systemctl status, journalctl, and the backups page of Enterprise Manager say so).
set -uo pipefail
KIND=${1:?level0, level1 or arch}
case $KIND in level0|level1|arch) ;; *) echo "== level0, level1 or arch, not $KIND" >&2; exit 2 ;; esac
export ORACLE_HOME=${ORACLE_HOME:-/u01/app/oracle/product/26ai/dbhome_1}
export ORACLE_SID=${ORACLE_SID:-BANK}
export PATH=$ORACLE_HOME/bin:$PATH
export NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'
DEST=${BK_BACKUP_DEST:-/backup/BANK}
LOG=$DEST/logs/$(hostname -s)_${KIND}_$(date +%Y%m%d-%H%M%S).log
if ! mkdir -p "$DEST/logs" 2>/dev/null || ! touch "$LOG" 2>/dev/null; then
  echo "== $DEST is not writable: is /backup of em1 mounted? (findmnt /backup; on em1: systemctl status nfs-server)" >&2
  exit 1
fi
exec > >(tee -a "$LOG") 2>&1
ROLE=$(printf 'set heading off feedback off pages 0\nselect database_role from v$database;\n' | sqlplus -s / as sysdba | tr -d '[:space:]')
echo "== $(date '+%F %T') $(hostname -s) $ORACLE_SID $ROLE: $KIND"

if [ "$ROLE" = PRIMARY ]; then
  case $KIND in
    level0) WHAT="backup incremental level 0 database plus archivelog;" ;;
    level1) WHAT="backup incremental level 1 cumulative database plus archivelog;" ;;
    arch) WHAT="backup archivelog all not backed up 1 times;" ;;
  esac
  rman target / <<RMAN
catalog start with '$DEST/' noprompt;
crosscheck backup;
$WHAT
delete noprompt obsolete;
delete noprompt archivelog all;
list backup summary;
RMAN
elif [ "$ROLE" = PHYSICALSTANDBY ]; then
  [ "$KIND" = arch ] || { echo "== the standby: the backups are taken on the primary"; exit 0; }
  rman target / <<RMAN
catalog start with '$DEST/' noprompt;
crosscheck backup;
delete noprompt archivelog all;
RMAN
else
  echo "== the database is $ROLE: no backup" >&2
  exit 1
fi
# RMAN: its errors in the log (RMAN-00569 the banner of an error stack)
if grep -qE 'RMAN-00569|RMAN-03009|RMAN-03002|ORA-[0-9]+' "$LOG"; then
  echo "== $(date '+%F %T') FAILED: $LOG" >&2
  exit 1
fi
echo "== $(date '+%F %T') done: $LOG"
