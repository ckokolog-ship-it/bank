#!/bin/bash
# rac_grid.sh -- on rac1, as root, once both nodes and ssh are ready (rac/rac_host.sh, rac/rac_ssh.sh): the Grid
# Infrastructure of the cluster rac: the Clusterware on rac1 and rac2, ASM, the disk group CRS (/dev/oracleasm/crs1,
# external redundancy: the registry of the cluster and its voting file), the SCAN rac-scan, the VIPs. Silent:
#
#   sudo bash ~/rac_grid.sh
#
#   1. the checks: the grid unzipped, oracle on rac2 by ssh without a password, the shared disk seen on both
#   2. the password of ASM (SYS/SYSASM, ASMSNMP: one) asked twice, into a response file of the grid itself
#      (install/response/gridsetup.rsp, its keys filled in), readable by oracle only, deleted at the end
#   3. cluvfy: the prerequisites (its report kept; in a lab some fail: swap, the DNS of the SCAN; not fatal)
#   4. gridSetup.sh -silent (oracle): the software copied to rac2, the cluster configured
#   5. the scripts of root: orainstRoot.sh and root.sh on rac1, then on rac2 (by ssh as chris: its password and
#      sudo there); root.sh of rac1 first: it starts the cluster, rac2 joins it
#   6. gridSetup.sh -executeConfigTools: the rest of the configuration
#   7. what runs: crsctl stat res -t, the SCAN, ASM
set -euo pipefail
GRID_HOME=/u01/app/23.0.0/grid
ORACLE_BASE=/u01/app/oracle
INVENTORY=/u01/app/oraInventory
OTHER=rac2
LOG=$ORACLE_BASE/rac_grid
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in rac1) ;; *) die "this is $(hostname): rac_grid.sh is for rac1" ;; esac
ORA() { runuser -l oracle -c "$1"; }
CHRIS=${SUDO_USER:-chris}

echo "== 1. checks"
[ -x "$GRID_HOME/gridSetup.sh" ] || die "no $GRID_HOME/gridSetup.sh (rac_host.sh 1 with the grid zip)"
ORA "ssh -o BatchMode=yes $OTHER true" || die "oracle cannot ssh to $OTHER without a password (rac_ssh.sh)"
[ -b /dev/oracleasm/crs1 ] || die "no /dev/oracleasm/crs1 here (rac_host.sh)"
ORA "ssh -o BatchMode=yes $OTHER test -b /dev/oracleasm/crs1" || die "no /dev/oracleasm/crs1 on $OTHER (rac_host.sh 2)"
mkdir -p "$LOG" && chown oracle:oinstall "$LOG"

if ORA "$GRID_HOME/bin/crsctl check cluster -all" >/dev/null 2>&1; then
  echo "== the cluster runs already"
else
  echo "== 2. the password of ASM (SYS, ASMSNMP): no @, no \" (they break the tools)"
  read -rsp "   password: " P1; echo
  read -rsp "   again: " P2; echo
  [ -n "$P1" ] && [ "$P1" = "$P2" ] || die "empty, or not the same"
  case $P1 in *@*|*\"*|*/*) die "no @, \" or / in it" ;; esac
  TPL=$GRID_HOME/install/response/gridsetup.rsp
  [ -f "$TPL" ] || die "no $TPL"
  RSP=$LOG/grid.rsp
  trap 'rm -f "$RSP"' EXIT
  install -o oracle -g oinstall -m 600 "$TPL" "$RSP"
  # a key by its name in this version (with oracle.install. or without), the value; not there: added
  setk() {
    local v=${!#} n
    for n in "${@:1:$#-1}"; do
      if grep -qE "^${n//./\\.}=" "$RSP"; then
        V="$v" N="$n" perl -pi -e 's/^\Q$ENV{N}\E=.*/$ENV{N}=$ENV{V}/' "$RSP"
        return 0
      fi
    done
    printf '%s=%s\n' "$1" "$v" >> "$RSP"
  }
  setk oracle.install.option installOption CRS_CONFIG
  setk INVENTORY_LOCATION "$INVENTORY"
  setk ORACLE_BASE "$ORACLE_BASE"
  setk oracle.install.asm.OSDBA OSDBA asmdba
  setk oracle.install.asm.OSOPER OSOPER asmoper
  setk oracle.install.asm.OSASM OSASM asmadmin
  setk oracle.install.crs.config.ClusterConfiguration clusterUsage STANDALONE
  setk oracle.install.crs.config.configureAsExtendedCluster configureAsExtendedCluster false
  setk oracle.install.crs.config.clusterName clusterName rac
  setk oracle.install.crs.config.gpnp.scanName scanName rac-scan.home.lan
  setk oracle.install.crs.config.gpnp.scanPort scanPort 1521
  setk oracle.install.crs.config.scanType scanType LOCAL_SCAN
  setk oracle.install.crs.config.gpnp.configureGNS configureGNS false
  setk oracle.install.crs.config.autoConfigureClusterNodeVIP configureDHCPAssignedVIPs false
  setk oracle.install.crs.config.clusterNodes clusterNodes "rac1.home.lan:rac1-vip.home.lan,rac2.home.lan:rac2-vip.home.lan"
  # (1: public; 5: the interconnect and ASM)
  setk oracle.install.crs.config.networkInterfaceList networkInterfaceList "$(ip -4 route show default | awk '{print $5; exit}'):192.168.178.0:1,$(nmcli -t -f GENERAL.DEVICES con show racpriv | cut -d: -f2):10.10.10.0:5"
  setk oracle.install.crs.config.storageOption storageOption FLEX_ASM_STORAGE
  setk oracle.install.asm.diskGroup.name diskGroupName CRS
  setk oracle.install.asm.diskGroup.redundancy redundancy EXTERNAL
  setk oracle.install.asm.diskGroup.AUSize auSize 4
  setk oracle.install.asm.diskGroup.disks diskList /dev/oracleasm/crs1
  setk oracle.install.asm.diskGroup.diskDiscoveryString diskString "/dev/oracleasm/*"
  setk oracle.install.asm.configureAFD configureAFD false
  setk oracle.install.crs.configureRHPS configureRHPS false
  setk oracle.install.crs.config.ignoreDownNodes ignoreDownNodes false
  setk oracle.install.config.managementOption managementOption NONE
  setk oracle.install.crs.rootconfig.executeRootScript executeRootScript false
  setk oracle.install.asm.SYSASMPassword sysasmPassword "$P1"
  setk oracle.install.asm.monitorPassword asmsnmpPassword "$P1"
  unset P1 P2
  echo "   the response file (without the passwords):"
  grep -vE '^#|^$|[Pp]assword=' "$RSP" | sed 's/^/     /'

  echo "== 3. cluvfy: the prerequisites (its report: $LOG/cluvfy.txt; not fatal)"
  ORA "$GRID_HOME/runcluvfy.sh stage -pre crsinst -n rac1,rac2 -verbose" > "$LOG/cluvfy.txt" 2>&1 || true
  grep -E "FAILED|PASSED|WARNING" "$LOG/cluvfy.txt" | sort | uniq -c | sort -rn | head -5 || true

  echo "== 4. gridSetup.sh -silent (some 10-20 minutes)"
  set +e
  ORA "cd $GRID_HOME && ./gridSetup.sh -silent -ignorePrereqFailure -waitforcompletion -responseFile $RSP"
  rc=$?
  set -e
  # (6: done, with warnings of the prerequisites)
  [ $rc = 0 ] || [ $rc = 6 ] || die "gridSetup.sh: $rc (its logs: $INVENTORY/logs/, /tmp/GridSetupActions*)"

  echo "== 5. the scripts of root: rac1 first, then $OTHER"
  [ -x "$INVENTORY/orainstRoot.sh" ] && "$INVENTORY/orainstRoot.sh"
  "$GRID_HOME/root.sh"
  echo "   on $OTHER (the password of chris, then for sudo there)"
  runuser -u "$CHRIS" -- ssh -t -o StrictHostKeyChecking=accept-new "chris@$OTHER" \
    "sudo bash -c '[ -x $INVENTORY/orainstRoot.sh ] && $INVENTORY/orainstRoot.sh; $GRID_HOME/root.sh'"

  echo "== 6. the configuration tools"
  set +e
  ORA "cd $GRID_HOME && ./gridSetup.sh -silent -executeConfigTools -responseFile $RSP"
  rc=$?
  set -e
  [ $rc = 0 ] || [ $rc = 6 ] || echo "== gridSetup.sh -executeConfigTools: $rc (often harmless in a lab: the logs, then crsctl below)"
  rm -f "$RSP"
fi

echo "== 7. what runs"
ORA "$GRID_HOME/bin/crsctl check cluster -all; $GRID_HOME/bin/crsctl stat res -t; $GRID_HOME/bin/srvctl status scan; $GRID_HOME/bin/srvctl status asm"
echo "== the grid ready. Next: the database (docs/ODIGIES_RAC.md)"
