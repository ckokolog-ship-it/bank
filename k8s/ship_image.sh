#!/bin/bash
# ship_image.sh -- on forms1, as root (sudo): the jar of the bank built again, its image (k8s/Dockerfile, podman),
# taken to the containerd of every node of k3s (no registry: ssh, k3s ctr images import), and k8s/bank.yaml with
# k8s/deploy.sh copied to the server; then the command to run there.
#
#   sudo ./ship_image.sh                         the nodes 192.168.178.211 .212 .213, as the user who ran sudo
#   sudo ./ship_image.sh --no-build 192.168.178.211 192.168.178.212
#
# The tag of the image: the commit of the repo (git rev-parse --short HEAD): every version its own tag, so a
# rollout to it and back (kubectl rollout undo). ssh to the nodes with a key (ssh-copy-id once); there the user may
# import without a password (k8s/node.sh gives it that one command).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BUILD=1
NODES=()
for a in "$@"; do
  case $a in
    --no-build) BUILD= ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) NODES+=("$a") ;;
  esac
done
[ ${#NODES[@]} -gt 0 ] || NODES=(192.168.178.211 192.168.178.212 192.168.178.213)
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo $0"
U=${SUDO_USER:-root}
OWNER=$(stat -c %U "$ROOT")
TAG=$(runuser -u "$OWNER" -- git -C "$ROOT" rev-parse --short HEAD)
IMAGE=localhost/bank/bk-api:$TAG
command -v podman >/dev/null || dnf -y -q install podman

if [ -n "$BUILD" ]; then
  echo "== the jar (as $OWNER)"
  runuser -u "$OWNER" -- bash -c "cd '$ROOT/api' && ./mvnw -q -B package -DskipTests"
fi
[ -f "$ROOT/api/target/bk-api.jar" ] || die "no api/target/bk-api.jar"
echo "== the image $IMAGE"
podman build -q -f "$HERE/Dockerfile" -t "$IMAGE" "$ROOT" >/dev/null
TAR=$(mktemp /tmp/bk-api-XXXXXX.tar)
trap 'rm -f "$TAR"' EXIT
podman save -q --format docker-archive -o "$TAR" "$IMAGE"
for n in "${NODES[@]}"; do
  echo "== to $n"
  runuser -u "$U" -- ssh -o BatchMode=yes -o ConnectTimeout=10 "$n" 'sudo -n /usr/local/bin/k3s ctr images import -' < "$TAR" >/dev/null
done
echo "== k8s/bank.yaml, k8s/deploy.sh to ${NODES[0]}:bank-k8s/"
# (read here as root: the user who runs ssh cannot read the home of the owner of the repo)
runuser -u "$U" -- ssh -o BatchMode=yes "${NODES[0]}" 'mkdir -p bank-k8s && cat > bank-k8s/bank.yaml' < "$HERE/bank.yaml"
runuser -u "$U" -- ssh -o BatchMode=yes "${NODES[0]}" 'cat > bank-k8s/deploy.sh && chmod +x bank-k8s/deploy.sh' < "$HERE/deploy.sh"
runuser -u "$U" -- ssh -o BatchMode=yes "${NODES[0]}" 'cat > bank-k8s/headlamp.sh && chmod +x bank-k8s/headlamp.sh' < "$HERE/headlamp.sh"
echo "== now on ${NODES[0]}:  sudo ~/bank-k8s/deploy.sh $TAG"
