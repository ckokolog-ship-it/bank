#!/bin/bash
# nfs_server.sh -- on em1, as root: the disk of the backups (backup/disk.ps1 added it on the i9) as /backup, shared by
# NFS to the hosts of the databases (db1, db2, rac1, rac2) only -- docs/ODIGIES_BACKUP.md:
#
#   sudo bash ~/nfs_server.sh
#
# The empty second disk (no partition, no filesystem, of 100 GB or more) formatted XFS, /backup in fstab; the folders
# of each database (BANK: Data Guard; BANKRAC; EMCDB) owned by oracle (uid 54321 on every host: the package of the
# prerequisites of Oracle); /etc/exports for the four addresses (rw, root_squash); firewalld: nfs for them only.
# Again: what is there is left (a disk with a filesystem is never formatted).
set -euo pipefail
CLIENTS=(192.168.178.221 192.168.178.222 192.168.178.231 192.168.178.232)
MNT=/backup
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
[ "$(hostname -s)" = em1 ] || die "this is $(hostname): nfs_server.sh is for em1"
[ "$(id -u oracle 2>/dev/null)" = 54321 ] || die "the user oracle is not 54321 here: the owner of the backups must be the same everywhere"

if ! findmnt -n "$MNT" >/dev/null; then
  echo "== the disk of the backups"
  DISK=
  for d in $(lsblk -dnbo NAME,TYPE | awk '$2=="disk"{print $1}'); do
    [ -z "$(lsblk -no FSTYPE "/dev/$d" | tr -d '[:space:]')" ] || continue      # a filesystem or LVM: not ours
    [ "$(lsblk -no NAME "/dev/$d" | wc -l)" = 1 ] || continue                   # partitions: not ours
    GB=$(( $(lsblk -dnbo SIZE "/dev/$d") / 1073741824 ))
    [ "$GB" -ge 100 ] || continue
    DISK=/dev/$d
    echo "   $DISK ($GB GB, empty)"
    break
  done
  [ -n "$DISK" ] || die "no empty disk of 100 GB or more (on the i9, with em1 off: backup/disk.ps1)"
  dnf -y -q install xfsprogs >/dev/null
  mkfs.xfs -q -L backup "$DISK"
  mkdir -p "$MNT"
  grep -q "^LABEL=backup " /etc/fstab || echo "LABEL=backup $MNT xfs defaults,nofail 0 0" >> /etc/fstab
  systemctl daemon-reload
  mount "$MNT"
fi
echo "== $MNT: $(df -h --output=size,avail "$MNT" | tail -1)"
for db in BANK BANKRAC EMCDB; do install -d -o oracle -g oinstall -m 750 "$MNT/$db" "$MNT/$db/logs"; done
chown oracle:oinstall "$MNT"
chmod 750 "$MNT"

echo "== NFS: $MNT to ${CLIENTS[*]}"
dnf -y -q install nfs-utils >/dev/null
OPTS="rw,sync,root_squash,no_subtree_check"
LINE="$MNT"
for c in "${CLIENTS[@]}"; do LINE="$LINE $c($OPTS)"; done
sed -i "\\#^$MNT #d" /etc/exports
echo "$LINE" >> /etc/exports
systemctl enable -q --now nfs-server
exportfs -ra
if systemctl is-active -q firewalld; then
  for c in "${CLIENTS[@]}"; do
    firewall-cmd -q --permanent --add-rich-rule="rule family=ipv4 source address=$c service name=nfs accept"
  done
  firewall-cmd -q --reload
fi
exportfs -v | grep "$MNT"
echo "== em1 shares $MNT. Next, on db1 and db2: sudo bash ~/nfs_client.sh"
