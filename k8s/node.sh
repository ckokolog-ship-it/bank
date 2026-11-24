#!/bin/bash
# node.sh -- a new VM of Oracle Linux 9 (k8s/vms.ps1 made it) as a node of the cluster k3s, as root, on its console
# (its address changes: an ssh to it drops; or first the fixed address on the console, then ssh to it, where the
# token can be pasted):
#
#   sudo ./node.sh server 192.168.178.211                       the first one: the server of k3s (its token shown)
#   sudo ./node.sh agent  192.168.178.212 192.168.178.211       the others: a worker, joined to the server (its
#   sudo ./node.sh agent  192.168.178.213 192.168.178.211       token asked: on the server sudo cat
#                                                               /var/lib/rancher/k3s/server/node-token)
#
# It gives the VM a fixed address (GW, DNS: 192.168.178.1; the FRITZ!Box: give the same address to the device too,
# or keep it out of its range of DHCP), its name (k3s1, k3s2, ...: from the last number of the address, 211 -> 1),
# opens in firewalld the ports of k3s (the API 6443 on the server, the kubelet 10250, flannel 8472/udp, the
# Ingress 80/443) and trusts the networks of its pods and services; then installs k3s (https://get.k3s.io: with
# its SELinux policy, k3s-selinux). The user who ran it (sudo) may import an image to containerd without a
# password (k8s/ship_image.sh from forms1): that one command only.
set -euo pipefail
ROLE=${1:?server or agent}
IP=${2:?the address of this node, e.g. 192.168.178.211}
SERVER=${3:-}
GW=${BK_GW:-192.168.178.1}
DNS=${BK_DNS:-192.168.178.1}
PREFIX=${BK_PREFIX:-24}
K3S_VERSION=${K3S_VERSION:-v1.31.4+k3s1}
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo $0 $*"
# not forms1, nor any machine with the database or the forms: it would get a new name, a new address and k3s
case $(hostname -s) in forms1*) die "this is $(hostname): node.sh is for the new VMs (k3s1, k3s2, k3s3) only" ;; esac
if grep -qsv '^\s*\(#\|$\)' /etc/oratab || id oracle >/dev/null 2>&1; then
  die "Oracle on this machine (/etc/oratab, the user oracle): node.sh is for the new VMs only"
fi
case $ROLE in
  server) ;;
  agent) [ -n "$SERVER" ] || die "agent: the address of the server too (sudo $0 agent $IP 192.168.178.211)" ;;
  *) die "server or agent, not $ROLE" ;;
esac
N=$(( ${IP##*.} - 210 ))
[ "$N" -ge 1 ] 2>/dev/null || N=${IP##*.}
NAME=k3s$N

echo "== $NAME ($IP): its name"
hostnamectl set-hostname "$NAME.home.lan"

echo "== a fixed address: $IP/$PREFIX, gateway $GW"
CON=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: '$2 != "lo" && $2 != "" {print $1; exit}')
[ -n "$CON" ] || die "no connection of NetworkManager up"
nmcli con mod "$CON" ipv4.method manual ipv4.addresses "$IP/$PREFIX" ipv4.gateway "$GW" ipv4.dns "$DNS" ipv6.method auto
nmcli con up "$CON" >/dev/null

echo "== firewalld: the ports of k3s"
if systemctl is-active -q firewalld; then
  [ "$ROLE" = server ] && firewall-cmd -q --permanent --add-port=6443/tcp
  firewall-cmd -q --permanent --add-port=10250/tcp --add-port=8472/udp --add-port=80/tcp --add-port=443/tcp
  firewall-cmd -q --permanent --zone=trusted --add-source=10.42.0.0/16 --add-source=10.43.0.0/16
  firewall-cmd -q --reload
fi

echo "== sudo finds /usr/local/bin (k3s, kubectl): Oracle Linux leaves it out of secure_path"
printf 'Defaults secure_path = /sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin\n' > /etc/sudoers.d/local-bin
chmod 440 /etc/sudoers.d/local-bin
visudo -cq -f /etc/sudoers.d/local-bin || { rm -f /etc/sudoers.d/local-bin; die "sudoers (secure_path)"; }

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  echo "== $SUDO_USER may import an image (k8s/ship_image.sh) without a password"
  printf '%s ALL=(root) NOPASSWD: /usr/local/bin/k3s ctr images import -\n' "$SUDO_USER" > /etc/sudoers.d/bk-k3s-import
  chmod 440 /etc/sudoers.d/bk-k3s-import
  visudo -cq -f /etc/sudoers.d/bk-k3s-import || { rm -f /etc/sudoers.d/bk-k3s-import; die "sudoers"; }
fi

echo "== k3s $K3S_VERSION ($ROLE)"
if [ "$ROLE" = server ]; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" \
    INSTALL_K3S_EXEC="server --node-ip=$IP --advertise-address=$IP --tls-san=$IP --write-kubeconfig-mode=640" sh -
  echo "== the token of the cluster (the agents ask for it):"
  cat /var/lib/rancher/k3s/server/node-token
  echo "== kubectl: sudo k3s kubectl get nodes -o wide"
else
  # (the token of k3s: K10...::server:..., one line, from the server; not a key of ssh)
  read -rsp "Το token του server ($SERVER: sudo cat /var/lib/rancher/k3s/server/node-token, K10...): " TOKEN; echo
  case $TOKEN in K10*::server:*) ;; *) die "not a token of k3s (K10...::server:...): on $SERVER sudo cat /var/lib/rancher/k3s/server/node-token" ;; esac
  [ -n "$TOKEN" ] || die "no token"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" K3S_URL="https://$SERVER:6443" K3S_TOKEN="$TOKEN" \
    INSTALL_K3S_EXEC="agent --node-ip=$IP" sh -
  echo "== on the server: sudo k3s kubectl get nodes -o wide"
fi
