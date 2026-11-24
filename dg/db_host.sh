#!/bin/bash
# db_host.sh -- a new VM of Oracle Linux 9 (k8s/vms.ps1 -Names db1,db2) as a host of the database of the bank:
# Oracle AI Database 26ai Enterprise Edition (23.26), its software only (the database: dg/primary.sh, the standby:
# dg/standby.sh). As root, on each of db1 and db2:
#
#   sudo ./db_host.sh 192.168.178.221 ~/LINUX.X64_2326100_db_home.zip      db1 (the primary)
#   sudo ./db_host.sh 192.168.178.222 ~/LINUX.X64_2326100_db_home.zip      db2 (the standby)
#
# The zip: from the Windows of the laptop (scp, docs/ODIGIES_DG.md). It gives the VM its name (db1, db2: the last
# number of the address less 220) and a fixed address (best first on the console: docs), the names of the others in
# /etc/hosts, the package oracle-ai-database-preinstall-26ai (or ...-23ai: the users oracle, oinstall, dba, the
# kernel, the limits), the port 1521 in firewalld; then the home of Oracle in /u01/app/oracle/product/26ai/dbhome_1
# (the zip unzipped into it as oracle) and its silent install (software only: runInstaller with the response file of
# the zip itself, its keys filled in) and the scripts of root. Again: what is there is left; the install not twice.
set -euo pipefail
IP=${1:?the address of this host, e.g. 192.168.178.221}
ZIP=${2:?the zip of the database, e.g. ~/LINUX.X64_2326100_db_home.zip}
GW=${BK_GW:-192.168.178.1}
DNS=${BK_DNS:-192.168.178.1}
PREFIX=${BK_PREFIX:-24}
ORACLE_BASE=/u01/app/oracle
ORACLE_HOME=$ORACLE_BASE/product/26ai/dbhome_1
INVENTORY=/u01/app/oraInventory
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo $0 $*"
case $(hostname -s) in
  forms1*|k3s*) die "this is $(hostname): db_host.sh is for the new VMs db1, db2 only" ;;
esac
[ -f "$ZIP" ] || die "no zip $ZIP (scp it from the Windows: docs/ODIGIES_DG.md)"
N=$(( ${IP##*.} - 220 ))
[ "$N" -ge 1 ] 2>/dev/null || die "the address: 192.168.178.221 (db1) or .222 (db2)"
NAME=db$N

echo "== $NAME ($IP): its name, a fixed address"
hostnamectl set-hostname "$NAME.home.lan"
CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: '$2 != "lo" && $2 != "" {print $1; exit}')
[ -n "$CON" ] || die "no connection of NetworkManager up"
if ! ip -4 addr show | grep -q "inet $IP/"; then
  nmcli con mod "$CON" ipv4.method manual ipv4.addresses "$IP/$PREFIX" ipv4.gateway "$GW" ipv4.dns "$DNS" ipv6.method auto
  nmcli con up "$CON" >/dev/null
fi

echo "== /etc/hosts: forms1, db1, db2, the nodes of k3s"
sed -i '/# bank-hosts$/d' /etc/hosts
cat >> /etc/hosts <<'HOSTS'
192.168.178.200 forms1.home.lan forms1 # bank-hosts
192.168.178.221 db1.home.lan db1 # bank-hosts
192.168.178.222 db2.home.lan db2 # bank-hosts
192.168.178.211 k3s1.home.lan k3s1 # bank-hosts
192.168.178.212 k3s2.home.lan k3s2 # bank-hosts
192.168.178.213 k3s3.home.lan k3s3 # bank-hosts
HOSTS

echo "== the package of the prerequisites of Oracle"
if ! rpm -q oracle-ai-database-preinstall-26ai >/dev/null 2>&1 && ! rpm -q oracle-database-preinstall-23ai >/dev/null 2>&1; then
  dnf -y -q install oracle-ai-database-preinstall-26ai 2>/dev/null || dnf -y -q install oracle-database-preinstall-23ai \
    || die "no package oracle-ai-database-preinstall-26ai nor -23ai (dnf repolist: ol9_appstream, ol9_baseos_latest)"
fi
dnf -y -q install unzip tar
id oracle >/dev/null || die "no user oracle after the package"

echo "== firewalld: 1521 (the listener: the clients, the redo of Data Guard)"
if systemctl is-active -q firewalld; then
  firewall-cmd -q --permanent --add-port=1521/tcp
  firewall-cmd -q --reload
fi

echo "== the home of Oracle: $ORACLE_HOME"
mkdir -p "$ORACLE_HOME" "$INVENTORY" "$ORACLE_BASE/oradata" "$ORACLE_BASE/fast_recovery_area"
chown -R oracle:oinstall /u01
chmod -R 775 /u01
if [ -x "$ORACLE_HOME/bin/oracle" ]; then
  echo "== installed already: $ORACLE_HOME/bin/oracle"
else
  if [ ! -x "$ORACLE_HOME/runInstaller" ]; then
    echo "== unzip (some minutes)"
    ZIPCOPY=/u01/app/db_home.zip
    install -o oracle -g oinstall -m 644 "$ZIP" "$ZIPCOPY"
    runuser -u oracle -- unzip -q -o "$ZIPCOPY" -d "$ORACLE_HOME"
    rm -f "$ZIPCOPY"
  fi
  # the response file of the zip itself, its keys filled in (their names: with oracle.install. or without, by version)
  TPL=$(ls "$ORACLE_HOME"/install/response/db_install.rsp 2>/dev/null || true)
  [ -n "$TPL" ] || die "no install/response/db_install.rsp in the zip"
  RSP=$ORACLE_BASE/db_install.rsp
  cp "$TPL" "$RSP"
  setk() {
    local k
    for k in "$@"; do :; done
    local v=$k n
    for n in "${@:1:$#-1}"; do
      if grep -qE "^${n//./\\.}=" "$RSP"; then sed -i "s#^${n//./\\.}=.*#${n}=${v}#" "$RSP"; return 0; fi
    done
    echo "${1}=${v}" >> "$RSP"
  }
  setk oracle.install.option installOption INSTALL_DB_SWONLY
  setk UNIX_GROUP_NAME oinstall
  setk INVENTORY_LOCATION "$INVENTORY"
  setk ORACLE_BASE "$ORACLE_BASE"
  setk ORACLE_HOME "$ORACLE_HOME"
  setk oracle.install.db.InstallEdition installEdition EE
  setk oracle.install.db.OSDBA_GROUP OSDBA dba
  setk oracle.install.db.OSOPER_GROUP OSOPER oper
  setk oracle.install.db.OSBACKUPDBA_GROUP OSBACKUPDBA backupdba
  setk oracle.install.db.OSDGDBA_GROUP OSDGDBA dgdba
  setk oracle.install.db.OSKMDBA_GROUP OSKMDBA kmdba
  setk oracle.install.db.OSRACDBA_GROUP OSRACDBA racdba
  chown oracle:oinstall "$RSP"
  echo "== runInstaller -silent (software only; some minutes)"
  set +e
  runuser -l oracle -c "cd '$ORACLE_HOME' && ./runInstaller -silent -ignorePrereqFailure -waitforcompletion -responseFile '$RSP'"
  rc=$?
  set -e
  # (6: done, with warnings of the prerequisites)
  [ $rc = 0 ] || [ $rc = 6 ] || die "runInstaller: $rc (its log: $INVENTORY/logs/)"
  [ -x "$INVENTORY/orainstRoot.sh" ] && "$INVENTORY/orainstRoot.sh"
  "$ORACLE_HOME/root.sh"
fi

echo "== the environment of oracle (~oracle/.bash_profile)"
P=/home/oracle/.bash_profile
sed -i '/# bank-oracle$/d' "$P"
cat >> "$P" <<ENV
export ORACLE_BASE=$ORACLE_BASE # bank-oracle
export ORACLE_HOME=$ORACLE_HOME # bank-oracle
export ORACLE_SID=BANK # bank-oracle
export PATH=\$ORACLE_HOME/bin:\$PATH # bank-oracle
export NLS_LANG=GREEK_GREECE.AL32UTF8 # bank-oracle
ENV
chown oracle:oinstall "$P"
runuser -l oracle -c 'sqlplus -v'
echo "== $NAME ready (software). Next: docs/ODIGIES_DG.md"
