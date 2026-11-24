#!/bin/bash
# deploy.sh -- on the server of k3s (k3s1), as root (sudo): the bank in the cluster (bank.yaml), its image
# localhost/bank/bk-api:<tag> (k8s/ship_image.sh took it to every node); the password of the database asked the
# first time (the Secret bk-db, never in a file of the repo). A new tag: a rolling update, one pod at a time.
#
#   sudo ./deploy.sh <tag>                   apply, and wait for the rollout
#   sudo ./deploy.sh <tag> --password        the password of BANK asked again too
#   sudo ./deploy.sh --status                the pods (on which node), the service, the Ingress, the autoscaler
#   sudo ./deploy.sh --undo                  back to the version before
#
# The database: BK_DB_URL (jdbc:oracle:thin:@//192.168.178.200:1521/FREEPDB1: forms1).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DB_URL=${BK_DB_URL:-jdbc:oracle:thin:@//192.168.178.200:1521/FREEPDB1}
# (k3s by its full path: sudo on Oracle Linux does not look in /usr/local/bin)
K="/usr/local/bin/k3s kubectl"
[ -x /usr/local/bin/k3s ] || K=kubectl
die() { echo "== $*" >&2; exit 1; }
status() {
  $K -n bank get pods -o wide
  $K -n bank get svc,ingress,hpa,pdb
}
case ${1:-} in
  --status) status; exit 0 ;;
  --undo) $K -n bank rollout undo deploy/bk-api; $K -n bank rollout status deploy/bk-api --timeout=300s; status; exit 0 ;;
  ''|-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
esac
TAG=$1
[ "$(id -u)" = 0 ] || [ -r /etc/rancher/k3s/k3s.yaml ] || die "as root: sudo $0 $*"
$K create namespace bank --dry-run=client -o yaml | $K apply -f - >/dev/null
if [ "${2:-}" = --password ] || ! $K -n bank get secret bk-db >/dev/null 2>&1; then
  read -rsp "Ο κωδικός του χρήστη BANK της βάσης: " P1; echo
  read -rsp "Ξανά: " P2; echo
  [ -n "$P1" ] && [ "$P1" = "$P2" ] || die "empty, or not the same"
  # (from stdin: not in the arguments of a process, not in a file)
  printf 'BK_DB_PASSWORD=%s\n' "$P1" | $K -n bank create secret generic bk-db --from-env-file=/dev/stdin \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
  unset P1 P2
  echo "== the Secret bk-db"
  $K -n bank rollout restart deploy/bk-api >/dev/null 2>&1 || true
fi
sed -e "s#@IMAGE@#localhost/bank/bk-api:$TAG#" -e "s#@DB_URL@#$DB_URL#" "$HERE/bank.yaml" | $K apply -f -
$K -n bank rollout status deploy/bk-api --timeout=300s
status
