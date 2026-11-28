#!/bin/bash
# em_host.sh -- the VM of Oracle Enterprise Manager 24ai (em1, on the i9: docs/ODIGIES_EM.md), as root, on its console
# (its address changes: an ssh to it drops):
#
#   sudo bash ~/em_host.sh ~/LINUX.X64_193000_db_home.zip       the repository on Oracle Database 19c (the default)
#   sudo bash ~/em_host.sh ~/LINUX.X64_2326100_db_home.zip      ... or on 26ai (23.26), the same as the RAC
#
# 1. The VM: its name em1, the fixed address 192.168.178.236, the names of the lab in /etc/hosts (the hosts that EM
#    watches: db1, db2, rac1, rac2, the SCAN, forms1), the package of the prerequisites of Oracle, swap of 8 GB, the
#    ports of EM in firewalld (7803 the console, 4903 the uploads of the agents, 7102 the console of WebLogic).
# 2. The software of the database for the repository: the zip into its home as oracle, runInstaller -silent (software
#    only; 19c on Oracle Linux 9: CV_ASSUME_DISTID=OL8, the check of the OS of 19.3 does not know OL9), root.sh.
# 3. The listener (1521) and the database of the repository: the CDB EMCDB, its PDB EMREP (dbca asks the passwords:
#    SYS, SYSTEM, the admin of the PDB -- never in a file), AL32UTF8, the parameters EM wants (processes,
#    open_cursors, session_cached_cursors, job_queue_processes, redo logs of 1 GB), started with the VM (systemd).
# Again: what is there is left. Then: em/em_oms.sh (Enterprise Manager itself).
set -euo pipefail
ZIP=${1:?the zip of the database: LINUX.X64_193000_db_home.zip (19c) or LINUX.X64_2326100_db_home.zip (26ai)}
IP=${EM_IP:-192.168.178.236}
GW=${BK_GW:-192.168.178.1}
DNS=${BK_DNS:-192.168.178.1}
ORACLE_BASE=/u01/app/oracle
INVENTORY=/u01/app/oraInventory
CDB=EMCDB
PDB=EMREP
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0 $*"
case $(hostname -s) in
  forms1*|k3s*|db1|db2|rac1|rac2) die "this is $(hostname): em_host.sh is for the new VM em1 only" ;;
esac
[ -f "$ZIP" ] || die "no zip $ZIP"
case $(basename "$ZIP") in
  LINUX.X64_193000_db_home.zip) VER=19c; ORACLE_HOME=$ORACLE_BASE/product/19c/dbhome_1 ;;
  LINUX.X64_23*_db_home.zip) VER=26ai; ORACLE_HOME=$ORACLE_BASE/product/26ai/dbhome_1 ;;
  *) die "which database is $(basename "$ZIP")? (LINUX.X64_193000_db_home.zip or LINUX.X64_23..._db_home.zip)" ;;
esac
. /etc/os-release
OLMAJOR=${VERSION_ID%%.*}

echo "== 1. em1: its name, the address $IP"
hostnamectl set-hostname em1.home.lan
DEV=$(ip -4 route show default | awk '{print $5; exit}')
[ -n "$DEV" ] || DEV=$(nmcli -t -f DEVICE,TYPE dev | awk -F: '$2=="ethernet"{print $1; exit}')
CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$DEV" '$2==d {print $1; exit}')
[ -n "$CON" ] || die "no connection on $DEV"
if ! ip -4 addr show "$DEV" | grep -q "inet $IP/"; then
  nmcli con mod "$CON" ipv4.method manual ipv4.addresses "$IP/24" ipv4.gateway "$GW" ipv4.dns "$DNS" ipv6.method auto
  nmcli con up "$CON" >/dev/null
fi
sed -i '/# bank-em$/d' /etc/hosts
cat >> /etc/hosts <<'HOSTS'
192.168.178.236 em1.home.lan em1 # bank-em
192.168.178.200 forms1.home.lan forms1 # bank-em
192.168.178.221 db1.home.lan db1 # bank-em
192.168.178.222 db2.home.lan db2 # bank-em
192.168.178.231 rac1.home.lan rac1 # bank-em
192.168.178.232 rac2.home.lan rac2 # bank-em
192.168.178.233 rac1-vip.home.lan rac1-vip # bank-em
192.168.178.234 rac2-vip.home.lan rac2-vip # bank-em
192.168.178.235 rac-scan.home.lan rac-scan # bank-em
HOSTS

echo "== the package of the prerequisites of Oracle ($VER)"
if [ "$VER" = 19c ]; then
  rpm -q oracle-database-preinstall-19c >/dev/null 2>&1 || dnf -y -q install oracle-database-preinstall-19c \
    || die "no package oracle-database-preinstall-19c (dnf repolist: ol${OLMAJOR}_appstream)"
else
  rpm -q oracle-ai-database-preinstall-26ai >/dev/null 2>&1 || rpm -q oracle-database-preinstall-23ai >/dev/null 2>&1 \
    || dnf -y -q install oracle-ai-database-preinstall-26ai 2>/dev/null || dnf -y -q install oracle-database-preinstall-23ai \
    || die "no package oracle-ai-database-preinstall-26ai nor -23ai"
fi
# (EM: make, binutils, glibc-devel for its own links; libnsl for 19c on OL9)
dnf -y -q install unzip tar chrony make binutils gcc glibc-devel libnsl libaio tmux
systemctl enable -q --now chronyd
id oracle >/dev/null || die "no user oracle after the package"

echo "== swap: 8 GB at least (the installer of EM checks it)"
SWAPMB=$(free -m | awk '/^Swap:/ {print $2}')
if [ "${SWAPMB:-0}" -lt 8000 ]; then
  # each step on its own (again after a stop: a file made but not yet swap)
  if [ ! -f /swapfile ] || [ "$(stat -c %s /swapfile)" -lt 8589934592 ]; then
    dd if=/dev/zero of=/swapfile bs=1M count=8192 status=none
  fi
  chmod 600 /swapfile
  # (mkswap of Oracle Linux 9 has no -q)
  blkid -t TYPE=swap /swapfile >/dev/null 2>&1 || mkswap /swapfile >/dev/null
  swapon --show=NAME --noheadings | grep -qx /swapfile || swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

echo "== firewalld: 7803 the console, 4903 the agents, 7102 WebLogic, 1521"
if systemctl is-active -q firewalld; then
  for p in 7803 4903 7102 1521; do firewall-cmd -q --permanent --add-port=$p/tcp; done
  firewall-cmd -q --reload
fi

echo "== the space: / (the software, the data) and /home (the zips of EM while they are unzipped)"
ROOTFREE=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "$ROOTFREE" -ge 40 ] || die "/ has ${ROOTFREE} GB free: 40 at least"
mkdir -p "$ORACLE_HOME" "$ORACLE_BASE/middleware" "$ORACLE_BASE/agent" "$ORACLE_BASE/swlib" "$ORACLE_BASE/oradata" "$INVENTORY"
chown -R oracle:oinstall /u01
chmod -R 775 /u01

echo "== 2. the software of the database ($VER) in $ORACLE_HOME"
# installed = the home in the inventory of Oracle (root.sh done): not a file of it -- the zip of 26ai is an image
# that has bin/oracle before any install
installed() { grep -qs "LOC=\"$ORACLE_HOME\"" "$INVENTORY/ContentsXML/inventory.xml" && [ -f /etc/oratab ]; }
if ! installed; then
  if [ ! -x "$ORACLE_HOME/runInstaller" ]; then
    echo "   unzip (some minutes)"
    install -o oracle -g oinstall -m 644 "$ZIP" /u01/app/db_home.zip
    runuser -u oracle -- unzip -q -o /u01/app/db_home.zip -d "$ORACLE_HOME"
    rm -f /u01/app/db_home.zip
  fi
  # an inventory left by an install that stopped before orainstRoot.sh (no /etc/oraInst.loc, no inventory.xml:
  # only its logs) -- the installer wants an empty one: its logs kept aside
  if [ ! -f /etc/oraInst.loc ] && [ -d "$INVENTORY" ] && [ ! -f "$INVENTORY/ContentsXML/inventory.xml" ] \
     && [ -n "$(ls -A "$INVENTORY")" ]; then
    OLD="/u01/app/oraInventory.failed-$(date +%Y%m%d-%H%M%S)"
    mv "$INVENTORY" "$OLD"
    install -d -o oracle -g oinstall -m 775 "$INVENTORY"
    echo "   (an inventory of an install that did not finish: moved to $OLD)"
  fi
  RSP=$ORACLE_BASE/em_db_install.rsp
  install -o oracle -g oinstall -m 644 "$ORACLE_HOME/install/response/db_install.rsp" "$RSP"
  # a key of the response file: its name in 19c (oracle.install...) or in 26ai (the short one), whichever is there
  setk() {
    local v=$3
    for n in "$1" "$2"; do
      if grep -qE "^${n//./\\.}=" "$RSP"; then
        V="$v" N="$n" perl -pi -e 's/^\Q$ENV{N}\E=.*/$ENV{N}=$ENV{V}/' "$RSP"
        return
      fi
    done
    printf '%s=%s\n' "$1" "$v" >> "$RSP"
  }
  setk oracle.install.option installOption INSTALL_DB_SWONLY
  setk UNIX_GROUP_NAME UNIX_GROUP_NAME oinstall
  setk INVENTORY_LOCATION INVENTORY_LOCATION "$INVENTORY"
  setk ORACLE_HOME ORACLE_HOME "$ORACLE_HOME"
  setk ORACLE_BASE ORACLE_BASE "$ORACLE_BASE"
  setk oracle.install.db.InstallEdition installEdition EE
  setk oracle.install.db.OSDBA_GROUP OSDBA dba
  setk oracle.install.db.OSOPER_GROUP OSOPER oper
  setk oracle.install.db.OSBACKUPDBA_GROUP OSBACKUPDBA backupdba
  setk oracle.install.db.OSDGDBA_GROUP OSDGDBA dgdba
  setk oracle.install.db.OSKMDBA_GROUP OSKMDBA kmdba
  setk oracle.install.db.OSRACDBA_GROUP OSRACDBA racdba
  # 19.3 knows Oracle Linux up to 8: it checks the OS by its name, OL9 is the same for it
  DISTID=
  [ "$VER" = 19c ] && [ "$OLMAJOR" -ge 9 ] && DISTID="export CV_ASSUME_DISTID=OL8; "
  echo "   runInstaller -silent (software only; some minutes)"
  set +e
  runuser -l oracle -c "${DISTID}cd '$ORACLE_HOME' && ./runInstaller -silent -ignorePrereqFailure -waitforcompletion -responseFile '$RSP'"
  rc=$?
  set -e
  # 6: installed with warnings (the prerequisites ignored)
  [ $rc = 0 ] || [ $rc = 6 ] || die "runInstaller: $rc (its log: $INVENTORY/logs/; 19c on OL9: docs/ODIGIES_EM.md §2, the 26ai instead)"
  [ -x "$INVENTORY/orainstRoot.sh" ] && "$INVENTORY/orainstRoot.sh" >/dev/null
  "$ORACLE_HOME/root.sh" >/dev/null
fi
installed || die "$ORACLE_HOME not in the inventory after runInstaller (its log: $INVENTORY/logs/)"

echo "== the environment of oracle"
P=/home/oracle/.bash_profile
sed -i '/# bank-em$/d' "$P"
cat >> "$P" <<ENV
export ORACLE_BASE=$ORACLE_BASE # bank-em
export ORACLE_HOME=$ORACLE_HOME # bank-em
export ORACLE_SID=$CDB # bank-em
export PATH=\$ORACLE_HOME/bin:\$PATH # bank-em
ENV
chown oracle:oinstall "$P"
O() { runuser -l oracle -c "$*"; }

echo "== 3. the listener (1521)"
if ! O "lsnrctl status" >/dev/null 2>&1; then
  O "netca -silent -responsefile \$ORACLE_HOME/assistants/netca/netca.rsp" >/dev/null || die "netca"
fi

echo "== the database of the repository: $CDB, its PDB $PDB (dbca: some 20-40 minutes)"
if ! grep -qs "^$CDB:" /etc/oratab; then
  echo "   dbca asks the passwords: SYS, SYSTEM, the admin of the PDB (strong; no @, no \"). Keep the one of SYS:"
  echo "   em_oms.sh asks it again."
  PARAMS="processes=600,open_cursors=300,session_cached_cursors=200,job_queue_processes=20,db_files=400"
  # (19c: EM asks for it; the later versions do not need it)
  [ "$VER" = 19c ] && PARAMS="$PARAMS,_allow_insert_with_update_check=TRUE"
  O "dbca -silent -createDatabase -templateName General_Purpose.dbc -gdbName $CDB -sid $CDB \
      -createAsContainerDatabase true -numberOfPDBs 1 -pdbName $PDB -characterSet AL32UTF8 -nationalCharacterSet AL16UTF16 \
      -storageType FS -datafileDestination $ORACLE_BASE/oradata -redoLogFileSize 1024 -memoryMgmtType AUTO_SGA \
      -totalMemory 5120 -emConfiguration NONE -initParams $PARAMS" \
    || die "dbca failed (its log: $ORACLE_BASE/cfgtoollogs/dbca/$CDB/)"
fi
O "sqlplus -s / as sysdba" <<'SQL'
whenever sqlerror exit failure
alter pluggable database all open;
alter pluggable database all save state;
exit
SQL

echo "== started with the VM: /etc/oratab Y, the unit oracle-em (the listener, then the database)"
sed -i "s|^$CDB:\(.*\):[NY]\$|$CDB:\1:Y|" /etc/oratab
cat > /etc/systemd/system/oracle-em.service <<UNIT
[Unit]
Description=Oracle: the listener and the database of the repository of EM ($CDB)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=oracle
Group=oinstall
Environment=ORACLE_HOME=$ORACLE_HOME
ExecStart=$ORACLE_HOME/bin/dbstart $ORACLE_HOME
ExecStop=$ORACLE_HOME/bin/dbshut $ORACLE_HOME
RemainAfterExit=yes
TimeoutSec=600

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable -q oracle-em
echo "== em1 ready: the database $CDB / $PDB on $IP:1521 ($VER). Next: em/em_oms.sh (docs/ODIGIES_EM.md §3)"
