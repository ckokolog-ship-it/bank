#!/bin/bash
# rac_ssh.sh -- on rac1, as root, once both nodes are ready (rac/rac_host.sh): ssh for oracle between rac1 and rac2
# without a password (the installer of the grid copies its home to rac2 and runs there by it): one key of oracle,
# the same on both nodes, its public half allowed on both, the keys of both hosts known (all their names). The key
# goes to rac2 through the home of chris (scp, then sudo there: the password of chris asked, twice or three times),
# with the package cvuqdisk of the grid (the checks of the shared disks). At the end: oracle from rac1 to rac2 and
# back, no password.
#
#   sudo bash ~/rac_ssh.sh
set -euo pipefail
OTHER=${BK_RAC_OTHER:-rac2}
GRID_HOME=/u01/app/23.0.0/grid
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo bash $0"
case $(hostname -s) in rac1) ;; *) die "this is $(hostname): rac_ssh.sh is for rac1" ;; esac
getent hosts "$OTHER" >/dev/null || die "no $OTHER in /etc/hosts (rac_host.sh first)"
ping -c1 -W2 "$OTHER" >/dev/null || die "$OTHER does not answer"
H=/home/oracle/.ssh
install -d -o oracle -g oinstall -m 700 "$H"
[ -f "$H/id_rsa" ] || runuser -u oracle -- ssh-keygen -q -t rsa -b 4096 -N '' -f "$H/id_rsa"
cp "$H/id_rsa.pub" "$H/authorized_keys"
echo "== the keys of the hosts"
ssh-keyscan -T 5 rac1 rac2 rac1.home.lan rac2.home.lan rac1-priv rac2-priv 192.168.178.231 192.168.178.232 \
  10.10.10.1 10.10.10.2 2>/dev/null | sort -u > "$H/known_hosts"
chown oracle:oinstall "$H"/*
chmod 600 "$H"/id_rsa "$H/authorized_keys"

echo "== to $OTHER (the password of chris on $OTHER, then for its sudo)"
SUDO_HOME=$(getent passwd "${SUDO_USER:-chris}" | cut -d: -f6)
T=$SUDO_HOME/oracle_ssh.tgz
tar -C /home/oracle -czf "$T" .ssh
chown "${SUDO_USER:-chris}" "$T"
chmod 600 "$T"
FILES=("$T")
RPM=$(ls "$GRID_HOME"/cv/rpm/cvuqdisk-*.rpm 2>/dev/null | head -1 || true)
[ -n "$RPM" ] && FILES+=("$RPM")
runuser -u "${SUDO_USER:-chris}" -- scp -o StrictHostKeyChecking=accept-new "${FILES[@]}" "chris@$OTHER:"
rm -f "$T"
runuser -u "${SUDO_USER:-chris}" -- ssh -t -o StrictHostKeyChecking=accept-new "chris@$OTHER" \
  "sudo bash -c 'rm -rf /home/oracle/.ssh && tar -C /home/oracle -xzf ~chris/oracle_ssh.tgz && chown -R oracle:oinstall /home/oracle/.ssh && rm -f ~chris/oracle_ssh.tgz; R=\$(ls ~chris/cvuqdisk-*.rpm 2>/dev/null | head -1); if [ -n \"\$R\" ] && ! rpm -q cvuqdisk >/dev/null 2>&1; then CVUQDISK_GRP=oinstall rpm -i \"\$R\"; fi; rm -f ~chris/cvuqdisk-*.rpm'"

echo "== a check: oracle, rac1 -> $OTHER -> rac1, no password"
runuser -u oracle -- ssh -o BatchMode=yes "$OTHER" "hostname; ssh -o BatchMode=yes rac1 hostname" \
  || die "ssh of oracle without a password did not work"
echo "== ssh ready. Next: the grid (docs/ODIGIES_RAC.md)"
