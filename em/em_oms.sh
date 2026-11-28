#!/bin/bash
# em_oms.sh -- Oracle Enterprise Manager 24ai on em1 (em/em_host.sh first: the database of the repository), as root;
# long (1-2 hours): in tmux, so that a dropped ssh does not stop it (docs/ODIGIES_EM.md §3):
#
#   sudo bash ~/em_oms.sh ~/em        the folder with the 5 zips of edelivery (V1046951-01.zip ... V1046955-01.zip)
#
# 1. The 5 zips unzipped as oracle into /home/oracle/em-stage: em24100_linux64.bin and its em24*.zip.
# 2. The templates of the response files from the installer itself (-getResponseFileTemplates): its new_install.rsp
#    filled -- the homes under /u01/app/oracle, the repository EMREP on em1:1521, a SMALL deployment, the software
#    library; the keys the template does not have are said (the name of a key changed in 24ai: look in it).
#    The passwords asked here, not shown: SYS of the repository (as dbca of em_host.sh), SYSMAN (the user of the
#    console), weblogic and the node manager (of the WebLogic of EM -- new ones, not of the forms), the registration
#    of the agents; in the response file only while the installer runs (600, oracle), then deleted.
# 3. The installer -silent, then allroot.sh (the start with the VM: gcstartup), and the address of the console.
set -euo pipefail
SRC=${1:?the folder with the zips V1046951-01.zip ... V1046955-01.zip}
STAGE=/home/oracle/em-stage
ORACLE_BASE=/u01/app/oracle
MW=$ORACLE_BASE/middleware
AGENT=$ORACLE_BASE/agent
INVENTORY=/u01/app/oraInventory
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0 $*"
[ "$(hostname -s)" = em1 ] || die "this is $(hostname): em_oms.sh is for em1 (em_host.sh first)"
grep -q '^EMCDB:' /etc/oratab || die "no database EMCDB: em_host.sh first"
MEMGB=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1048576 ))
[ "$MEMGB" -ge 14 ] || die "em1 has ${MEMGB} GB of memory: 16 for EM and its repository"
O() { runuser -l oracle -c "$*"; }

echo "== 1. the zips"
for z in V1046951-01.zip V1046952-01.zip V1046953-01.zip V1046954-01.zip V1046955-01.zip; do
  [ -f "$SRC/$z" ] || die "no $SRC/$z (the 5 zips of edelivery)"
done
install -d -o oracle -g oinstall -m 755 "$STAGE"
if [ ! -x "$STAGE/em24100_linux64.bin" ]; then
  HOMEFREE=$(df -BG --output=avail "$STAGE" | tail -1 | tr -dc 0-9)
  [ "$HOMEFREE" -ge 12 ] || die "$STAGE has ${HOMEFREE} GB free: 12 at least"
  for z in "$SRC"/V10469*.zip; do
    echo "   unzip $(basename "$z")"
    runuser -u oracle -- unzip -q -o "$z" -d "$STAGE"
  done
  chmod +x "$STAGE"/em24100_linux64.bin
fi
[ -x "$STAGE/em24100_linux64.bin" ] || die "no em24100_linux64.bin after the unzip (its files: $(ls "$STAGE" | tr '\n' ' '))"

if [ -x "$MW/bin/emctl" ]; then
  echo "== EM is installed already ($MW): its state"
  O "$MW/bin/emctl status oms" || true
  exit 0
fi

echo "== 2. the templates of the response files (from the installer)"
TPL=$STAGE/rsp
if [ ! -f "$TPL/new_install.rsp" ]; then
  install -d -o oracle -g oinstall -m 700 "$TPL"
  O "cd '$STAGE' && ./em24100_linux64.bin -getResponseFileTemplates -outputLoc '$TPL'" >/dev/null \
    || die "em24100_linux64.bin -getResponseFileTemplates (its log: /tmp/OraInstall*)"
fi
[ -f "$TPL/new_install.rsp" ] || die "no new_install.rsp among the templates: $(ls "$TPL" | tr '\n' ' ')"

ask() { # the variable, the question: asked twice, not shown, not empty
  local a b
  read -rsp "$2: " a; echo
  read -rsp "   ξανά: " b; echo
  [ -n "$a" ] && [ "$a" = "$b" ] || die "empty, or not the same"
  printf -v "$1" '%s' "$a"
}
echo "   Οι κωδικοί (δεν φαίνονται· 8+ χαρακτήρες, από γράμμα, με κεφαλαίο, μικρό και ψηφίο· μόνο γράμματα, ψηφία, _ #):"
ask P_SYS "SYS της βάσης EMCDB (αυτός του dbca)"
ask P_SYSMAN "SYSMAN (ο χρήστης της κονσόλας του EM)"
ask P_WLS "weblogic του EM (καινούργιος)"
ask P_NM "node manager του EM (καινούργιος)"
ask P_AGENT "εγγραφή των agents"
for v in "$P_SYS" "$P_SYSMAN" "$P_WLS" "$P_NM" "$P_AGENT"; do
  [[ $v =~ ^[A-Za-z][A-Za-z0-9_#]{7,29}$ ]] || die "a password: 8-30 letters, digits, _ or #, starting with a letter"
  # (SYSMAN and weblogic of EM: a capital, a small letter and a digit)
  [[ $v =~ [A-Z] && $v =~ [a-z] && $v =~ [0-9] ]] || die "a password: at least one capital, one small letter, one digit"
done

RSP=$(runuser -u oracle -- mktemp /home/oracle/em-new_install-XXXXXX.rsp)
chmod 600 "$RSP"
trap 'shred -u "$RSP" 2>/dev/null || rm -f "$RSP"' EXIT
cat "$TPL/new_install.rsp" > "$RSP"
MISSING=()
setk() { # the key, the value: replaced where it is in the template (also a commented #KEY=), else added and said
  local k=$1 v=$2
  if grep -qE "^#?[[:space:]]*${k}[[:space:]]*=" "$RSP"; then
    K="$k" V="$v" perl -pi -e 's/^#?\s*\Q$ENV{K}\E\s*=.*/$ENV{K}=$ENV{V}/' "$RSP"
  else
    printf '%s=%s\n' "$k" "$v" >> "$RSP"
    MISSING+=("$k")
  fi
}
setk UNIX_GROUP_NAME oinstall
setk INVENTORY_LOCATION "$INVENTORY"
setk INSTALL_UPDATES_SELECTION skip
setk ORACLE_MIDDLEWARE_HOME_LOCATION "$MW"
setk AGENT_BASE_DIR "$AGENT"
setk ORACLE_HOSTNAME em1.home.lan
setk WLS_ADMIN_SERVER_USERNAME weblogic
setk WLS_ADMIN_SERVER_PASSWORD "$P_WLS"
setk WLS_ADMIN_SERVER_CONFIRM_PASSWORD "$P_WLS"
setk NODE_MANAGER_PASSWORD "$P_NM"
setk NODE_MANAGER_CONFIRM_PASSWORD "$P_NM"
setk ORACLE_INSTANCE_HOME_LOCATION "$ORACLE_BASE/gc_inst"
setk CONFIGURE_ORACLE_SOFTWARE_LIBRARY true
setk SOFTWARE_LIBRARY_LOCATION "$ORACLE_BASE/swlib"
setk DATABASE_HOSTNAME em1.home.lan
setk LISTENER_PORT 1521
setk SERVICENAME_OR_SID EMREP
setk SYS_PASSWORD "$P_SYS"
setk SYSMAN_PASSWORD "$P_SYSMAN"
setk SYSMAN_CONFIRM_PASSWORD "$P_SYSMAN"
setk AGENT_REGISTRATION_PASSWORD "$P_AGENT"
setk AGENT_REGISTRATION_CONFIRM_PASSWORD "$P_AGENT"
setk DEPLOYMENT_SIZE SMALL
setk MANAGEMENT_TABLESPACE_LOCATION "$ORACLE_BASE/oradata/EMCDB/EMREP/mgmt.dbf"
setk CONFIGURATION_DATA_TABLESPACE_LOCATION "$ORACLE_BASE/oradata/EMCDB/EMREP/mgmt_ecm_depot1.dbf"
setk JVM_DIAGNOSTICS_TABLESPACE_LOCATION "$ORACLE_BASE/oradata/EMCDB/EMREP/mgmt_deepdive.dbf"
setk EMPREREQ_AUTO_CORRECTION true
setk b_upgrade false
setk EM_INSTALL_TYPE NOSEED
setk CONFIGURATION_TYPE ADVANCED
unset P_SYS P_SYSMAN P_WLS P_NM P_AGENT
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "   (not in the template of 24ai, added: ${MISSING[*]})"
fi
chown oracle:oinstall "$RSP"

echo "== 3. the installer -silent (1-2 hours; its log: $INVENTORY/logs/ and $MW/cfgtoollogs/)"
set +e
O "cd '$STAGE' && ./em24100_linux64.bin -silent -responseFile '$RSP'"
rc=$?
set -e
[ $rc = 0 ] || die "the installer: $rc (its logs: $INVENTORY/logs/, $MW/cfgtoollogs/cfgfw/; the keys of its template: $TPL/new_install.rsp)"
[ -x "$MW/allroot.sh" ] && "$MW/allroot.sh"
O "$MW/bin/emctl status oms" || true
echo "== EM ready: https://em1.home.lan:7803/em (or https://192.168.178.236:7803/em), user SYSMAN."
echo "   Next: the agents on db1, db2, rac1, rac2 (docs/ODIGIES_EM.md §4)."
