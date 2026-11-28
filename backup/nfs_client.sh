#!/bin/bash
# nfs_client.sh -- on db1, db2 (and rac1, rac2), as root: /backup of em1 mounted here (backup/nfs_server.sh there
# first) -- docs/ODIGIES_BACKUP.md:
#
#   sudo bash ~/nfs_client.sh
#
# The options of Oracle for RMAN on NFS (hard: a backup waits, never a half file; 1 MB reads and writes; NFS 4.2);
# _netdev,nofail: the host starts also when em1 is off (the backups then fail and say so; the database does not).
# A check: oracle (54321) writes there.
set -euo pipefail
EM=${EM_IP:-192.168.178.236}
MNT=/backup
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in db1|db2|rac1|rac2) ;; *) die "this is $(hostname): nfs_client.sh is for db1, db2, rac1, rac2" ;; esac
[ "$(id -u oracle 2>/dev/null)" = 54321 ] || die "the user oracle is not 54321 here: it would not own its backups on em1"
dnf -y -q install nfs-utils >/dev/null
mkdir -p "$MNT"
OPTS="rw,hard,rsize=1048576,wsize=1048576,timeo=600,vers=4.2,_netdev,nofail"
sed -i "\\#[[:space:]]${MNT}[[:space:]]#d" /etc/fstab
echo "$EM:$MNT $MNT nfs $OPTS 0 0" >> /etc/fstab
systemctl daemon-reload
findmnt -n "$MNT" >/dev/null || mount "$MNT" || die "em1 does not share $MNT (on em1: sudo bash ~/nfs_server.sh)"
runuser -u oracle -- bash -c "f=$MNT/BANK/.check-\$(hostname -s); date > \"\$f\" && rm -f \"\$f\"" \
  || die "oracle cannot write in $MNT/BANK"
echo "== $MNT of em1 here: $(df -h --output=size,avail "$MNT" | tail -1). Next: sudo bash ~/rman_setup.sh"
