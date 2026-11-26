#!/bin/bash
# rac_db.sh -- on rac1, as root, once the grid runs (rac/rac_grid.sh): the RAC database of the lab.
#
#   sudo bash ~/rac_db.sh ~/LINUX.X64_2326100_db_home.zip
#
#   1. the disk groups DATA (/dev/oracleasm/data1) and RECO (reco1), external redundancy, mounted on both nodes
#   2. the software of the database (26ai EE) in /u01/app/oracle/product/26ai/dbhome_1: the zip unzipped on rac1,
#      runInstaller -silent for the nodes rac1,rac2 (it copies the home to rac2 by ssh), root.sh on rac1 and on
#      rac2 (by ssh as chris: its password and sudo there)
#   3. dbca -silent: the RAC CDB BANKRAC, its instances BANKRAC1 (rac1) and BANKRAC2 (rac2), the PDB BANKPDB,
#      the files in +DATA, the recovery area in +RECO, archive log; dbca asks the passwords (SYS, SYSTEM, the PDB)
#   4. the environment of oracle: the commands grid and db switch between the two homes
#   5. what runs: srvctl status database, the services
# Again: what is there is left (the disk groups, the home, the database).
set -euo pipefail
ZIP=${1:-}
GRID_HOME=/u01/app/23.0.0/grid
ORACLE_BASE=/u01/app/oracle
DB_HOME=$ORACLE_BASE/product/26ai/dbhome_1
INVENTORY=/u01/app/oraInventory
DB=BANKRAC
OTHER=rac2
CHRIS=${SUDO_USER:-chris}
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0 $*"
case $(hostname -s) in rac1) ;; *) die "this is $(hostname): rac_db.sh is for rac1" ;; esac
G() { runuser -l oracle -c "export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM1 PATH=$GRID_HOME/bin:\$PATH; $1"; }
D() { runuser -l oracle -c "export ORACLE_HOME=$DB_HOME ORACLE_SID=${DB}1 PATH=$DB_HOME/bin:\$PATH; $1"; }
G "crsctl check cluster -all" >/dev/null 2>&1 || die "the cluster does not run (rac_grid.sh)"

echo "== 1. the disk groups DATA, RECO"
for dg in DATA:data1 RECO:reco1; do
  name=${dg%%:*}; disk=/dev/oracleasm/${dg##*:}
  if G "srvctl status diskgroup -diskgroup $name" >/dev/null 2>&1; then
    echo "   $name: there already"
  else
    printf "whenever sqlerror exit failure\ncreate diskgroup %s external redundancy disk '%s' attribute 'au_size'='4M', 'compatible.asm'='23.0', 'compatible.rdbms'='23.0';\n" "$name" "$disk" \
      | G "sqlplus -s / as sysasm"
  fi
  G "srvctl start diskgroup -diskgroup $name -node rac1,rac2" 2>/dev/null || true
done
G "asmcmd lsdg"

echo "== 2. the software of the database: $DB_HOME (rac1, rac2)"
if [ -x "$DB_HOME/bin/oracle" ] && runuser -u oracle -- ssh -o BatchMode=yes "$OTHER" test -x "$DB_HOME/bin/oracle"; then
  echo "   installed already"
else
  mkdir -p "$DB_HOME"; chown -R oracle:oinstall "$ORACLE_BASE/product"
  if [ ! -x "$DB_HOME/runInstaller" ]; then
    [ -n "$ZIP" ] && [ -f "$ZIP" ] || die "the zip of the database: sudo bash $0 ~/LINUX.X64_2326100_db_home.zip"
    echo "   unzip (some minutes)"
    install -o oracle -g oinstall -m 644 "$ZIP" /u01/app/db_home.zip
    runuser -u oracle -- unzip -q -o /u01/app/db_home.zip -d "$DB_HOME"
    rm -f /u01/app/db_home.zip
  fi
  runuser -u oracle -- ssh -o BatchMode=yes "$OTHER" "mkdir -p $DB_HOME"
  RSP=$ORACLE_BASE/rac_db_install.rsp
  install -o oracle -g oinstall -m 644 "$DB_HOME/install/response/db_install.rsp" "$RSP"
  # a key by its name in this version, the value; not there: added by its first name
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
  setk oracle.install.option installOption INSTALL_DB_SWONLY
  setk UNIX_GROUP_NAME oinstall
  setk INVENTORY_LOCATION "$INVENTORY"
  setk ORACLE_BASE "$ORACLE_BASE"
  setk ORACLE_HOME "$DB_HOME"
  setk oracle.install.db.InstallEdition installEdition EE
  setk oracle.install.db.OSDBA_GROUP OSDBA dba
  setk oracle.install.db.OSOPER_GROUP OSOPER oper
  setk oracle.install.db.OSBACKUPDBA_GROUP OSBACKUPDBA backupdba
  setk oracle.install.db.OSDGDBA_GROUP OSDGDBA dgdba
  setk oracle.install.db.OSKMDBA_GROUP OSKMDBA kmdba
  setk oracle.install.db.OSRACDBA_GROUP OSRACDBA racdba
  setk oracle.install.db.CLUSTER_NODES clusterNodes rac1,rac2
  echo "   runInstaller -silent for rac1,rac2 (10-20 minutes)"
  set +e
  runuser -l oracle -c "cd $DB_HOME && ./runInstaller -silent -ignorePrereqFailure -waitforcompletion -responseFile $RSP"
  rc=$?
  set -e
  [ $rc = 0 ] || [ $rc = 6 ] || die "runInstaller: $rc (its log: $INVENTORY/logs/; the response file: $RSP)"
  echo "   root.sh: rac1, then $OTHER (the password of chris, then for sudo there)"
  "$DB_HOME/root.sh"
  runuser -u "$CHRIS" -- ssh -t -o StrictHostKeyChecking=accept-new "chris@$OTHER" "sudo $DB_HOME/root.sh"
fi

echo "== 3. dbca: the RAC database $DB (some 30-60 minutes)"
if G "srvctl status database -db $DB" >/dev/null 2>&1 || D "srvctl status database -db $DB" >/dev/null 2>&1; then
  echo "   there already"
else
  echo "   dbca asks the passwords: SYS, SYSTEM, the admin of the PDB (one strong one; no @, no \")"
  D "dbca -silent -createDatabase -templateName General_Purpose.dbc \
    -gdbName $DB -sid $DB -databaseConfigType RAC -nodelist rac1,rac2 \
    -createAsContainerDatabase true -numberOfPDBs 1 -pdbName BANKPDB -useLocalUndoForPDBs true \
    -storageType ASM -diskGroupName +DATA -recoveryGroupName +RECO -recoveryAreaSize 15360 -enableArchive true \
    -useOMF true -characterSet AL32UTF8 -nationalCharacterSet AL16UTF16 \
    -memoryMgmtType AUTO_SGA -totalMemory 4096 -redoLogFileSize 200 -emConfiguration NONE" \
    || die "dbca failed (its log: $ORACLE_BASE/cfgtoollogs/dbca/$DB/)"
fi

echo "== 4. the environment of oracle: grid / db"
for host in rac1 "$OTHER"; do
  N=${host#rac}
  BLOCK="# bank-rac-env
grid() { export ORACLE_HOME=$GRID_HOME ORACLE_SID=+ASM$N; export PATH=$GRID_HOME/bin:\$(echo \"\$PATH\" | sed -E 's#[^:]*/(grid|dbhome_1)/bin:##g'); }
db() { export ORACLE_HOME=$DB_HOME ORACLE_SID=$DB$N; export PATH=$DB_HOME/bin:\$(echo \"\$PATH\" | sed -E 's#[^:]*/(grid|dbhome_1)/bin:##g'); }
db
# bank-rac-env-end"
  if [ "$host" = rac1 ]; then
    sed -i '/^# bank-rac-env$/,/^# bank-rac-env-end$/d' /home/oracle/.bash_profile
    printf '%s\n' "$BLOCK" >> /home/oracle/.bash_profile
  else
    printf '%s\n' "$BLOCK" | runuser -u oracle -- ssh -o BatchMode=yes "$OTHER" \
      "sed -i '/^# bank-rac-env\$/,/^# bank-rac-env-end\$/d' ~/.bash_profile; cat >> ~/.bash_profile"
  fi
done

echo "== 5. what runs"
D "srvctl status database -db $DB -verbose; srvctl config database -db $DB | grep -E 'Database unique name|Instances|Configured nodes|Spfile|Services|Disk Groups'"
printf 'set lines 160 pages 50\ncol host_name for a16\nselect inst_id, instance_name, host_name, status from gv$instance order by 1;\nselect inst_id, name, open_mode from gv$pdbs where name = %s order by 1;\n' "'BANKPDB'" | D "sqlplus -s / as sysdba"
echo "== the RAC database ready. Next: the bank on it (docs/ODIGIES_RAC.md)"
