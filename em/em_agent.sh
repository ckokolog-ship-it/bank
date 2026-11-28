#!/bin/bash
# em_agent.sh -- the agent of Enterprise Manager on a host of the lab (em/em_oms.sh first: EM on em1), as root, on
# each one (docs/ODIGIES_EM.md §4):
#
#   sudo bash ~/em_agent.sh          on db1, db2, rac1, rac2, forms1
#
# The host pulls the agent from em1 by itself (AgentPull of EM: no ssh from em1 to it): the name em1 in /etc/hosts,
# the port of the agent (3872) in firewalld for em1, the script AgentPull.sh from https://em1.home.lan:4903, the
# agent as the owner of Oracle there (oracle) in /u01/app/oracle/agent, registered with the password of the
# registration of the agents (em_oms.sh); then its root.sh, and its state. The passwords (SYSMAN: to download the
# agent; the registration) asked, not shown, only in a temporary response file of 600 while AgentPull.sh runs.
# Again: an agent that is there is left (its state shown). Then the targets in the console (§5).
set -euo pipefail
EM_IP=${EM_IP:-192.168.178.236}
EM=em1.home.lan
UPLOAD_PORT=${EM_UPLOAD_PORT:-4903}
AGENT_PORT=3872
OWNER=oracle
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0 $*"
H=$(hostname -s)
case $H in
  db1|db2|rac1|rac2|forms1) ;;
  *) die "this is $(hostname): em_agent.sh is for db1, db2, rac1, rac2, forms1 (em1 has its own agent already)" ;;
esac
id "$OWNER" >/dev/null 2>&1 || die "no user $OWNER on $H"
if [ -d /u01/app/oracle ]; then BASE=/u01/app/oracle/agent; else BASE=/home/$OWNER/agent; fi
O() { runuser -l "$OWNER" -c "$*"; }

if [ -x "$BASE/agent_inst/bin/emctl" ] && O "$BASE/agent_inst/bin/emctl status agent" >/dev/null 2>&1; then
  echo "== the agent is on $H already ($BASE): its state"
  O "$BASE/agent_inst/bin/emctl status agent" || true
  exit 0
fi
if [ -d "$BASE" ] && [ -n "$(ls -A "$BASE" 2>/dev/null)" ]; then
  # an agent of before that did not finish its configuration (or does not run): aside, its logs kept
  OLD="$BASE.failed-$(date +%Y%m%d-%H%M%S)"
  mv "$BASE" "$OLD"
  echo "   (an agent that did not finish: moved to $OLD)"
fi

echo "== $H: the name of em1 ($EM_IP), the port of the agent ($AGENT_PORT) for it"
sed -i '/# bank-em-agent$/d' /etc/hosts
echo "$EM_IP $EM em1 # bank-em-agent" >> /etc/hosts
if systemctl is-active -q firewalld; then
  firewall-cmd -q --permanent --add-rich-rule="rule family=ipv4 source address=$EM_IP port port=$AGENT_PORT protocol=tcp accept"
  firewall-cmd -q --reload
fi
# (the agent: libnsl.so.1 -- not in the prerequisites of 26ai)
dnf -y -q install curl libnsl >/dev/null
curl -sk --max-time 10 -o /dev/null "https://$EM:$UPLOAD_PORT/empbs/upload" \
  || die "em1 does not answer on $UPLOAD_PORT: is EM up there? (on em1: emctl status oms)"

FREEGB=$(df -BG --output=avail "$(dirname "$BASE")" | tail -1 | tr -dc 0-9)
[ "$FREEGB" -ge 3 ] || die "$(dirname "$BASE") has ${FREEGB} GB free: 3 for the agent"
install -d -o "$OWNER" -g "$(id -gn "$OWNER")" -m 755 "$BASE"

ask() { # the variable, the question: twice, not shown
  local a b
  while true; do
    read -rsp "$2: " a; echo
    read -rsp "   ξανά: " b; echo
    [ -n "$a" ] && [ "$a" = "$b" ] && break
    echo "   κενός, ή όχι ο ίδιος: ξανά"
  done
  printf -v "$1" '%s' "$a"
}
ask P_SYSMAN "SYSMAN του EM (για να κατέβει ο agent)"
ask P_REG "εγγραφή των agents (του em_oms.sh)"

WORK=$(runuser -u "$OWNER" -- mktemp -d "/home/$OWNER/em-agent-XXXXXX")
RSP=$WORK/agent.properties
trap 'shred -u "$RSP" 2>/dev/null || rm -f "$RSP"; rm -rf "$WORK"' EXIT
install -o "$OWNER" -m 600 /dev/null "$RSP"
printf 'LOGIN_USER=sysman\nLOGIN_PASSWORD=%s\nPLATFORM="Linux x86-64"\nAGENT_REGISTRATION_PASSWORD=%s\nAGENT_PORT=%s\nORACLE_HOSTNAME=%s\n' \
  "$P_SYSMAN" "$P_REG" "$AGENT_PORT" "$(hostname -f)" > "$RSP"
unset P_SYSMAN P_REG

echo "== AgentPull.sh from em1, then the agent (some minutes)"
O "cd '$WORK' && curl -sfk 'https://$EM:$UPLOAD_PORT/em/install/getAgentImage' -o AgentPull.sh && chmod +x AgentPull.sh" \
  || die "AgentPull.sh did not come from https://$EM:$UPLOAD_PORT/em/install/getAgentImage"
set +e
O "cd '$WORK' && ./AgentPull.sh RSPFILE_LOC='$RSP' AGENT_BASE_DIR='$BASE' -ignorePrereqs"
rc=$?
set -e
[ $rc = 0 ] || die "AgentPull.sh: $rc (its logs: $WORK and $BASE/agent_inst/install/logs; the console of EM: Setup → Agents)"

echo "== root.sh of the agent"
ROOTSH=$(ls "$BASE"/agent_*/root.sh 2>/dev/null | head -1 || true)
[ -n "$ROOTSH" ] && "$ROOTSH"
O "$BASE/agent_inst/bin/emctl status agent" || true
echo "== the agent of $H is in EM. Next: the targets in the console (docs/ODIGIES_EM.md §5)"
