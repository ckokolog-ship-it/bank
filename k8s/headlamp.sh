#!/bin/bash
# headlamp.sh -- on the server of k3s (k3s1), as root (sudo): Headlamp, the web console of Kubernetes
# (kubernetes-sigs/headlamp), in the cluster, at http://<any node>/headlamp/ (Traefik, port 80, as the bank: its
# path /headlamp more particular than the / of the bank); a ServiceAccount of an administrator, its token to log in.
#
#   sudo ./headlamp.sh              install (or again), and a token of 8 hours
#   sudo ./headlamp.sh --token      only a new token (the one before ended)
#   sudo ./headlamp.sh --remove     all of it away
#
# The token: the cluster in full (cluster-admin). Plain HTTP on the home network: never to the internet; the token
# to nobody. HEADLAMP_MANIFEST: another manifest (a fixed version) in place of the one of main.
set -euo pipefail
K="/usr/local/bin/k3s kubectl"
[ -x /usr/local/bin/k3s ] || K=kubectl
NS=kube-system
URL=${HEADLAMP_MANIFEST:-https://raw.githubusercontent.com/kubernetes-sigs/headlamp/main/kubernetes-headlamp.yaml}
die() { echo "== $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "as root: sudo $0 $*"
token() {
  echo "== the token (8 hours; for http://$(hostname -I | awk '{print $1}')/headlamp/):"
  $K -n $NS create token headlamp-admin --duration=8h
}
case ${1:-} in
  --token) token; exit 0 ;;
  --remove)
    $K -n $NS delete ingress headlamp --ignore-not-found
    $K delete clusterrolebinding headlamp-admin --ignore-not-found
    $K -n $NS delete serviceaccount headlamp-admin --ignore-not-found
    curl -fsSL "$URL" | $K delete --ignore-not-found -f -
    exit 0 ;;
  '') ;;
  *) sed -n '2,12p' "$0"; exit 0 ;;
esac

echo "== Headlamp ($URL), at /headlamp"
M=$(mktemp)
trap 'rm -f "$M"' EXIT
curl -fsSL "$URL" -o "$M"
# its path /headlamp: an argument of it, and its probes there too (else they get 404 and restart it)
grep -q -- '-base-url=' "$M" || sed -i 's#^\(\s*\)- "-in-cluster"#&\n\1- "-base-url=/headlamp"#' "$M"
sed -i 's#^\(\s*path:\) /$#\1 /headlamp/#' "$M"
grep -q -- '- "-base-url=/headlamp"' "$M" || die "the manifest changed: no -in-cluster to put -base-url after ($URL)"
$K apply -f "$M"

$K apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: headlamp
  namespace: kube-system
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /headlamp
            pathType: Prefix
            backend:
              service:
                name: headlamp
                port:
                  number: 80
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: headlamp-admin
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: headlamp-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: headlamp-admin
    namespace: kube-system
YAML
$K -n $NS rollout status deploy/headlamp --timeout=300s
token
