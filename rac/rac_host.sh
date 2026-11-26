#!/bin/bash
# rac_host.sh -- a node of the RAC of the lab (the i9: rac/rac_disks.ps1 first), as root, on each:
#
#   sudo bash ~/rac_host.sh 1 ~/LINUX.X64_2326100_grid_home.zip      on rac1 (the grid zip: there only)
#   sudo bash ~/rac_host.sh 2                                         on rac2
#
# The node N: its name racN, the public address 192.168.178.23N (its first card), the private 10.10.10.N (the second:
# the interconnect, racpriv), the names of the cluster in /etc/hosts (the nodes, their VIPs .233/.234 that the
# Clusterware moves, the SCAN .235 that the clients call), the package of the prerequisites of Oracle, the groups of
# ASM for oracle (one owner of the grid and of the database), the firewall (the other node and the interconnect:
# trusted; 1521 for the clients), the shared disks as /dev/oracleasm/{crs1,data1,reco1} owned by oracle:asmadmin
# (udev, by the serial of each disk: the same on both nodes); on rac1 the grid zip into the home of the grid.
# Then on rac1: rac/rac_ssh.sh (ssh between the nodes for oracle). Again: what is there is left.
set -euo pipefail
N=${1:?the number of this node: 1 or 2}
ZIP=${2:-}
case $N in 1|2) ;; *) echo "== the node: 1 or 2" >&2; exit 1 ;; esac
GW=${BK_GW:-192.168.178.1}
DNS=${BK_DNS:-192.168.178.1}
PUB=192.168.178.23$N
PRIV=10.10.10.$N
GRID_HOME=/u01/app/23.0.0/grid
ORACLE_BASE=/u01/app/oracle
INVENTORY=/u01/app/oraInventory
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0 $*"
case $(hostname -s) in
  forms1*|k3s*|db1|db2) die "this is $(hostname): rac_host.sh is for the new VMs rac1, rac2 only" ;;
esac
if [ "$N" = 1 ] && [ -n "$ZIP" ]; then [ -f "$ZIP" ] || die "no zip $ZIP"; fi

echo "== rac$N: its name, the public address $PUB"
hostnamectl set-hostname "rac$N.home.lan"
PUBDEV=$(ip -4 route show default | awk '{print $5; exit}')
[ -n "$PUBDEV" ] || PUBDEV=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="ethernet"{print $1; exit}')
CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$PUBDEV" '$2==d {print $1; exit}')
[ -n "$CON" ] || die "no connection on $PUBDEV"
if ! ip -4 addr show "$PUBDEV" | grep -q "inet $PUB/"; then
  nmcli con mod "$CON" ipv4.method manual ipv4.addresses "$PUB/24" ipv4.gateway "$GW" ipv4.dns "$DNS" ipv6.method auto
  nmcli con up "$CON" >/dev/null
fi

echo "== the interconnect: $PRIV"
PRIVDEV=$(nmcli -t -f DEVICE,TYPE dev | awk -F: -v p="$PUBDEV" '$2=="ethernet" && $1!=p {print $1; exit}')
[ -n "$PRIVDEV" ] || die "no second card (the internal network racpriv: rac_disks.ps1, with the VMs off)"
nmcli con delete racpriv >/dev/null 2>&1 || true
# (the names of connections have spaces: "Wired connection 2")
nmcli -t -f NAME,DEVICE con show | awk -F: -v d="$PRIVDEV" '$2==d {print $1}' | while IFS= read -r c; do
  nmcli con delete "$c" >/dev/null || true
done
nmcli con add type ethernet con-name racpriv ifname "$PRIVDEV" ipv4.method manual ipv4.addresses "$PRIV/24" \
  ipv6.method disabled connection.autoconnect yes >/dev/null
nmcli con up racpriv >/dev/null

echo "== /etc/hosts: the nodes, their VIPs, the interconnect, the SCAN"
sed -i '/# bank-rac$/d' /etc/hosts
cat >> /etc/hosts <<'HOSTS'
192.168.178.231 rac1.home.lan rac1 # bank-rac
192.168.178.232 rac2.home.lan rac2 # bank-rac
192.168.178.233 rac1-vip.home.lan rac1-vip # bank-rac
192.168.178.234 rac2-vip.home.lan rac2-vip # bank-rac
192.168.178.235 rac-scan.home.lan rac-scan # bank-rac
10.10.10.1 rac1-priv.home.lan rac1-priv # bank-rac
10.10.10.2 rac2-priv.home.lan rac2-priv # bank-rac
HOSTS
# (Oracle: no zeroconf route 169.254 on the interconnect)
grep -q '^NOZEROCONF=yes' /etc/sysconfig/network 2>/dev/null || echo NOZEROCONF=yes >> /etc/sysconfig/network
systemctl disable --now avahi-daemon.socket avahi-daemon.service >/dev/null 2>&1 || true

echo "== the package of the prerequisites of Oracle; the groups of ASM"
if ! rpm -q oracle-ai-database-preinstall-26ai >/dev/null 2>&1 && ! rpm -q oracle-database-preinstall-23ai >/dev/null 2>&1; then
  dnf -y -q install oracle-ai-database-preinstall-26ai 2>/dev/null || dnf -y -q install oracle-database-preinstall-23ai \
    || die "no package oracle-ai-database-preinstall-26ai nor -23ai"
fi
dnf -y -q install unzip tar chrony
systemctl enable -q --now chronyd
id oracle >/dev/null || die "no user oracle after the package"
for g in asmadmin asmdba asmoper; do groupadd -f "$g"; done
usermod -aG asmadmin,asmdba,asmoper oracle

echo "== firewalld: the other node and the interconnect trusted, 1521 for the clients"
if systemctl is-active -q firewalld; then
  firewall-cmd -q --permanent --zone=trusted --add-source=10.10.10.0/24
  for a in 231 232 233 234 235; do firewall-cmd -q --permanent --zone=trusted --add-source=192.168.178.$a; done
  firewall-cmd -q --permanent --add-port=1521/tcp
  firewall-cmd -q --reload
fi

echo "== the shared disks: /dev/oracleasm (udev, by serial)"
ROOTDISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
ROOTDISK=${ROOTDISK:-sda}
RULES=/etc/udev/rules.d/99-oracle-asm.rules
: > "$RULES.new"
for d in $(lsblk -dnbo NAME,TYPE | awk '$2=="disk"{print $1}'); do
  [ "$d" = "$ROOTDISK" ] && continue
  # LVM of the system on it: not one of ours
  pvs --noheadings -o pv_name 2>/dev/null | grep -q "/dev/$d" && continue
  GB=$(( $(lsblk -dnbo SIZE "/dev/$d") / 1073741824 ))
  case $GB in
    9|10) NAME=crs1 ;;
    39|40) NAME=data1 ;;
    19|20) NAME=reco1 ;;
    *) continue ;;
  esac
  SER=$(udevadm info --query=property --name="/dev/$d" | sed -n 's/^ID_SERIAL=//p')
  [ -n "$SER" ] || die "no serial for /dev/$d"
  echo "KERNEL==\"sd*\", ENV{DEVTYPE}==\"disk\", ENV{ID_SERIAL}==\"$SER\", SYMLINK+=\"oracleasm/$NAME\", OWNER=\"oracle\", GROUP=\"asmadmin\", MODE=\"0660\"" >> "$RULES.new"
  echo "   /dev/$d ($GB GB) -> /dev/oracleasm/$NAME"
done
[ "$(grep -c oracleasm "$RULES.new")" = 3 ] || die "not the 3 shared disks (10, 40, 20 GB): rac_disks.ps1 with the VMs off ($(lsblk -dno NAME,SIZE | tr '\n' ' '))"
mv "$RULES.new" "$RULES"
udevadm control --reload-rules
udevadm trigger --type=devices --action=change
sleep 2
ls -lL /dev/oracleasm/

echo "== the homes: $GRID_HOME (the grid), $ORACLE_BASE"
mkdir -p "$GRID_HOME" "$ORACLE_BASE" "$INVENTORY"
chown -R oracle:oinstall /u01
chmod -R 775 /u01
if [ "$N" = 1 ] && [ -n "$ZIP" ] && [ ! -x "$GRID_HOME/gridSetup.sh" ]; then
  echo "== unzip the grid (some minutes)"
  install -o oracle -g oinstall -m 644 "$ZIP" /u01/app/grid_home.zip
  runuser -u oracle -- unzip -q -o /u01/app/grid_home.zip -d "$GRID_HOME"
  rm -f /u01/app/grid_home.zip
fi
RPM=$(ls "$GRID_HOME"/cv/rpm/cvuqdisk-*.rpm 2>/dev/null | head -1 || true)
if [ -n "$RPM" ] && ! rpm -q cvuqdisk >/dev/null 2>&1; then CVUQDISK_GRP=oinstall rpm -iv "$RPM"; fi

echo "== the environment of oracle"
P=/home/oracle/.bash_profile
sed -i '/# bank-rac$/d' "$P"
cat >> "$P" <<ENV
export ORACLE_BASE=$ORACLE_BASE # bank-rac
export GRID_HOME=$GRID_HOME # bank-rac
export PATH=\$GRID_HOME/bin:\$PATH # bank-rac
ENV
chown oracle:oinstall "$P"
echo "== rac$N ready. Next: $( [ "$N" = 1 ] && echo 'on rac1: sudo bash ~/rac_ssh.sh' || echo 'rac_host.sh on rac1 too, then rac_ssh.sh there')"
