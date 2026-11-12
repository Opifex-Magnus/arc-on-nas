#!/usr/bin/env bash
# tenant-cert.sh: sign a tenant user's certificate request and write their certificate and a
# kubeconfig without a key (README, "Tenant namespaces").
#
# The user makes their private key and the request themselves and keeps the key; only the request
# (CSR) comes here. Their certificate and kubeconfig are not secret: send both back. k3s's
# kubernetes.io/kube-apiserver-client signer signs it for --days (90 by default). Renewing is the
# same command with a new request.
#
#   scripts/tenant-cert.sh USER CSR_FILE
# Options:
#   --org ORG             the one organisation (O) the request may carry (default devinfra)
#   --days N              validity in days (default 90)
#   --server URL          the API server as the user reaches it (default https://k3s-api:6443,
#                         the forwarder in api-forward.yml)
#   --namespace NS        the kubeconfig context's namespace (default: none)
#   --exec-command CMD    the kubeconfig's credential plugin, which prints the user's certificate
#                         and key; a relative path with a "/" is relative to the kubeconfig's
#                         directory, a bare name is looked up on PATH (default ./tenant-credential)
#   --out DIR             where USER.crt and USER.kubeconfig go (default .)
#
# It refuses a request whose subject is anything but CN=USER plus at most one O=ORG, or that
# carries attributes or extensions: a request for O=system:masters, say, signed by this signer,
# would be a cluster-admin certificate.
# Run from anywhere, as a user that may run docker (or DOCKER="sudo docker"); needs openssl.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
read -ra docker <<< "${DOCKER:-docker}"
org=devinfra
days=90
server=https://k3s-api:6443
namespace=""
exec_command=./tenant-credential
out=.
args=()

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --org) org=${2:?--org needs a value}; shift 2 ;;
    --days) days=${2:?--days needs a value}; shift 2 ;;
    --server) server=${2:?--server needs a value}; shift 2 ;;
    --namespace) namespace=${2:?--namespace needs a value}; shift 2 ;;
    --exec-command) exec_command=${2:?--exec-command needs a value}; shift 2 ;;
    --out) out=${2:?--out needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "${#args[@]}" -eq 2 ] || { usage >&2; exit 2; }
user=${args[0]}
csr=${args[1]}
[[ "$user" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "USER must be a DNS label: $user" >&2; exit 2; }
[[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -ge 1 ] || { echo "--days must be a positive number" >&2; exit 2; }
[[ "$org" != system:* ]] || { echo "--org may not be a system: group" >&2; exit 2; }
[[ "$org" =~ ^[a-z0-9][-a-z0-9.]*$ ]] || { echo "--org must be lowercase letters, digits, - and ." >&2; exit 2; }
server_re='^https://[][A-Za-z0-9.:-]+$'
[[ "$server" =~ $server_re ]] || { echo "--server must be https://HOST[:PORT]" >&2; exit 2; }
[ -z "$namespace" ] || [[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
  || { echo "--namespace must be a namespace name" >&2; exit 2; }
[[ "$exec_command" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "--exec-command must be a plain path" >&2; exit 2; }
[ -r "$csr" ] || { echo "Cannot read $csr" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is needed" >&2; exit 1; }

kubectl() { "${docker[@]}" compose --project-directory "$root" exec -T k3s kubectl "$@"; }

# The request is checked and submitted as one set of bytes: OpenSSL's re-encoding of the first
# request in the file, so that what the API server parses is what was checked here.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
openssl req -in "$csr" -outform PEM -out "$work/request.pem" 2>/dev/null \
  || { echo "$csr is not a certificate request" >&2; exit 1; }
check_request() {
  openssl req -in "$1" -noout -verify >/dev/null 2>&1 \
    || { echo "Refused: not a certificate request with a valid signature" >&2; return 1; }
  # RFC 2253 form: one line, special characters escaped, a multi-valued RDN joined with "+".
  local subject
  subject=$(openssl req -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
  echo "Request subject: $subject"
  case "$subject" in
    "CN=$user"|"CN=$user,O=$org"|"O=$org,CN=$user") ;;
    *) echo "Refused: the subject must be CN=$user, O=$org and nothing else" >&2; return 1 ;;
  esac
  # No attributes, so no requested extensions either (the signer copies subject alternative
  # names): the request's attribute set, the [0] at depth 2, is empty. Read from the DER
  # structure, which every OpenSSL version prints the same way.
  local attributes
  attributes=$(openssl asn1parse -in "$1" | awk '/d=2/ && /cont \[ 0 \]/')
  if ! printf '%s\n' "$attributes" | grep -qE 'l= *0 '; then
    echo "Refused: the request carries attributes or extensions" >&2; return 1
  fi
}
check_request "$work/request.pem" || exit 1

# Bound anywhere? Not required, but a certificate for nobody is likely a typo.
bindings=$(kubectl get rolebindings -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{range .subjects[*]}{.kind}={.name}{" "}{end}{"\n"}{end}' \
  | awk -v u="User=$user" '{ for (i = 2; i <= NF; i++) if ($i == u) print $1 }' | sort -u | paste -sd ' ' -)
if [ -n "$bindings" ]; then
  echo "$user is bound in: $bindings"
else
  echo "Warning: no RoleBinding names the user $user; the certificate will be allowed nothing." >&2
fi

name="tenant-$user-$(date -u +%Y%m%d-%H%M%S)"
request=$(base64 < "$work/request.pem" | tr -d '\n')
kubectl apply -f - >/dev/null <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $name
spec:
  request: $request
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: $((days * 86400))
  usages:
    - client auth
YAML
# What the API server stored is what is approved: decode it and check it once more.
kubectl get csr "$name" -o jsonpath='{.spec.request}' | base64 -d > "$work/stored.pem"
if ! cmp -s "$work/request.pem" "$work/stored.pem" || ! check_request "$work/stored.pem" >/dev/null; then
  kubectl delete csr "$name" >/dev/null
  echo "Refused: the stored request differs from the checked one; deleted $name" >&2
  exit 1
fi
kubectl certificate approve "$name" >/dev/null
cert=""
for _ in $(seq 1 30); do
  cert=$(kubectl get csr "$name" -o jsonpath='{.status.certificate}')
  [ -n "$cert" ] && break
  sleep 1
done
[ -n "$cert" ] || { echo "CertificateSigningRequest $name was approved but not signed" >&2; exit 1; }

mkdir -p "$out"
printf '%s' "$cert" | base64 -d > "$out/$user.crt"
# The cluster's CA, from the admin kubeconfig: public, and what the user checks the server against.
ca=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
context_namespace=""
[ -n "$namespace" ] && context_namespace="
      namespace: $namespace"
cat > "$out/$user.kubeconfig" <<YAML
# For $user: no key in here. The credential plugin prints the certificate and the key.
apiVersion: v1
kind: Config
clusters:
  - name: arc-on-nas
    cluster:
      server: $server
      # The API server's certificate names "kubernetes", not the forwarder.
      tls-server-name: kubernetes
      certificate-authority-data: $ca
users:
  - name: $user
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1
        command: $exec_command
        interactiveMode: Never
contexts:
  - name: $user@arc-on-nas
    context:
      cluster: arc-on-nas
      user: $user$context_namespace
current-context: $user@arc-on-nas
YAML
echo "Signed as CertificateSigningRequest $name:"
openssl x509 -in "$out/$user.crt" -noout -subject -issuer -enddate | sed 's/^/  /'
echo "Wrote $out/$user.crt and $out/$user.kubeconfig."
