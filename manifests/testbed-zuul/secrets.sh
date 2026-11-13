#!/usr/bin/env bash
# secrets.sh: Zuul's Secrets (README.md, "Secrets"), printed as JSON for `kubectl apply -f -`.
# Nothing is written to disk but the CA, and only by `ca`.
#
#   deploy/zuul/secrets.sh ca DIR
#       makes ZooKeeper's CA: DIR/ca.key (mode 600) and DIR/ca.crt, in a new directory DIR. Move the
#       key into a secret store and delete the file; ca.crt is public.
#   deploy/zuul/secrets.sh zuul --ca-cert FILE --ca-key FILE --keystore-password FILE
#       for the namespace zuul: zookeeper-tls (ZooKeeper's key pair), zuul-zookeeper-client (the
#       services' client key pair) and zuul-keystore.
#   deploy/zuul/secrets.sh executor --ca-cert FILE --ca-key FILE --keystore-password FILE
#       for the namespace zuul-executor: zuul-zookeeper-client (the executor's own client key pair)
#       and zuul-keystore.
#   deploy/zuul/secrets.sh db
#       for the namespace zuul: zuul-db, new random passwords for the database's users zuul and
#       root. Only before the database's first start: MariaDB sets them once, into an empty
#       directory, and a new Secret afterwards locks Zuul out (README.md, "Secrets").
# Options:
#   --days N   validity in days (default: 3650 for the CA, 1825 for a key pair, and never past the CA)
#
# The keystore password encrypts the project keys Zuul keeps in ZooKeeper: the same one in both
# namespaces, kept in a secret store, never changed (Zuul cannot re-encrypt its keys with another).
# Make it once, for example with `openssl rand -hex 32`. Every FILE may be a pipe:
# --ca-key <(secret-store get zuul-ca-key).
# Needs openssl and jq.
set -euo pipefail

days=""
ca_cert=""
ca_key=""
keystore=""
args=()

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --days) days=${2:?--days needs a value}; shift 2 ;;
    --ca-cert) ca_cert=${2:?--ca-cert needs a value}; shift 2 ;;
    --ca-key) ca_key=${2:?--ca-key needs a value}; shift 2 ;;
    --keystore-password) keystore=${2:?--keystore-password needs a value}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "${#args[@]}" -ge 1 ] || { usage >&2; exit 2; }
command=${args[0]}
args=("${args[@]:1}")
if [ -n "$days" ]; then
  [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -ge 1 ] || { echo "--days must be a positive number" >&2; exit 2; }
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# secret <name> <type> <key=file>...: a Secret as JSON, each key's value the file's contents.
secret() {
  local name=$1 type=$2 i=0 kv
  shift 2
  local jq_args=()
  for kv in "$@"; do
    jq_args+=(--arg "k$i" "${kv%%=*}" --rawfile "v$i" "${kv#*=}")
    i=$((i + 1))
  done
  jq -n --arg name "$name" --arg type "$type" --argjson n "$i" "${jq_args[@]}" '
    {apiVersion: "v1", kind: "Secret", type: $type,
     metadata: {name: $name, labels: {"app.kubernetes.io/part-of": "zuul"}},
     data: ([range($n) as $i | {($ARGS.named["k\($i)"]): ($ARGS.named["v\($i)"] | @base64)}] | add)}'
}

# read_ca: the CA's certificate and key, checked to belong together, the key copied once (it may
# be a pipe) into $tmp/ca.key.
read_ca() {
  [ -n "$ca_cert" ] && [ -n "$ca_key" ] || { echo "$command needs --ca-cert and --ca-key" >&2; exit 2; }
  (umask 077 && cat "$ca_key" > "$tmp/ca.key")
  [ "$(openssl x509 -in "$ca_cert" -noout -pubkey)" = "$(openssl pkey -in "$tmp/ca.key" -pubout)" ] \
    || { echo "the CA key is not $ca_cert's" >&2; exit 1; }
  cp "$ca_cert" "$tmp/ca.crt"
}

# read_keystore: the keystore password, once, into $tmp/keystore, without a trailing newline.
read_keystore() {
  [ -n "$keystore" ] || { echo "$command needs --keystore-password" >&2; exit 2; }
  (umask 077 && tr -d '\n' < "$keystore" > "$tmp/keystore")
  [ "$(wc -c < "$tmp/keystore")" -ge 16 ] || { echo "the keystore password is shorter than 16 characters" >&2; exit 1; }
  # Zuul reads zuul.conf with Python's configparser, for which % starts an interpolation.
  ! grep -q '%' "$tmp/keystore" || { echo "the keystore password must not contain %" >&2; exit 1; }
}

# leaf <name> <CN> <serverAuth|clientAuth> [DNS name...]: a key pair signed by the CA, as
# $tmp/<name>.key and $tmp/<name>.crt.
leaf() {
  local name=$1 cn=$2 usage=$3; shift 3
  local leaf_days=${days:-1825} ca_days san=""
  # Never past the CA's own end.
  ca_days=$(( ($(date -d "$(openssl x509 -in "$tmp/ca.crt" -noout -enddate | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))
  [ "$ca_days" -gt 30 ] || { echo "the CA expires within 30 days: make a new CA first (README.md)" >&2; exit 1; }
  [ "$leaf_days" -le "$ca_days" ] || leaf_days=$ca_days
  (umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$tmp/$name.key")
  for n in "$@"; do san+=",DNS:$n"; done
  {
    echo "basicConstraints = critical,CA:false"
    echo "keyUsage = critical,digitalSignature"
    echo "extendedKeyUsage = $usage"
    echo "subjectKeyIdentifier = hash"
    echo "authorityKeyIdentifier = keyid"
    [ -z "$san" ] || echo "subjectAltName = ${san#,}"
  } > "$tmp/$name.cnf"
  openssl req -new -key "$tmp/$name.key" -subj "/O=AIDepartment/CN=$cn" -out "$tmp/$name.csr"
  # A random positive serial of 120 bits.
  openssl x509 -req -in "$tmp/$name.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -sha256 \
    -set_serial "0x7$(openssl rand -hex 15)" -days "$leaf_days" -extfile "$tmp/$name.cnf" \
    -out "$tmp/$name.crt" 2> /dev/null
  local purpose=sslserver; [ "$usage" = clientAuth ] && purpose=sslclient
  openssl verify -CAfile "$tmp/ca.crt" -purpose "$purpose" "$tmp/$name.crt" > /dev/null
  echo "$name: $(openssl x509 -in "$tmp/$name.crt" -noout -subject -enddate | paste -sd ' ' -)" >&2
}

# The services' and the executor's client key pair, and the keystore password, for one namespace.
client_secrets() {
  leaf client "zuul client $1" clientAuth
  secret zuul-zookeeper-client kubernetes.io/tls \
    "tls.crt=$tmp/client.crt" "tls.key=$tmp/client.key" "ca.crt=$tmp/ca.crt"
  secret zuul-keystore Opaque "password=$tmp/keystore"
}

case "$command" in
  ca)
    [ "${#args[@]}" -eq 1 ] || { usage >&2; exit 2; }
    dir=${args[0]}
    [ ! -e "$dir" ] || { echo "$dir exists: the CA goes into a new directory" >&2; exit 2; }
    (umask 077 && mkdir -p "$dir")
    (umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$dir/ca.key")
    # A CA for ZooKeeper's server and its clients only, with no CA below it.
    openssl req -new -x509 -key "$dir/ca.key" -sha256 -days "${days:-3650}" \
      -subj "/O=AIDepartment/CN=Zuul ZooKeeper CA $(date -u +%Y-%m-%d)" \
      -addext "basicConstraints=critical,CA:true,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -addext "subjectKeyIdentifier=hash" \
      -out "$dir/ca.crt"
    openssl x509 -in "$dir/ca.crt" -noout -subject -enddate -fingerprint -sha256 >&2
    ;;

  zuul)
    [ "${#args[@]}" -eq 0 ] || { usage >&2; exit 2; }
    read_ca
    read_keystore
    # The names the services reach ZooKeeper by (zuul.conf), and the shorter ones.
    leaf server zookeeper.zuul serverAuth zookeeper zookeeper.zuul zookeeper.zuul.svc \
      zookeeper.zuul.svc.cluster.local
    # ZooKeeper reads its key pair as one PEM file, the certificate first.
    cat "$tmp/server.crt" "$tmp/server.key" > "$tmp/keystore.pem"
    {
      secret zookeeper-tls Opaque "keystore.pem=$tmp/keystore.pem" "ca.crt=$tmp/ca.crt"
      client_secrets zuul
    } | jq -s '{apiVersion: "v1", kind: "List", items: .}'
    ;;

  executor)
    [ "${#args[@]}" -eq 0 ] || { usage >&2; exit 2; }
    read_ca
    read_keystore
    client_secrets zuul-executor | jq -s '{apiVersion: "v1", kind: "List", items: .}'
    ;;

  db)
    [ "${#args[@]}" -eq 0 ] || { usage >&2; exit 2; }
    # Hex: nothing that needs quoting in the database's URL or configparser.
    (umask 077 && openssl rand -hex 24 | tr -d '\n' > "$tmp/password" && openssl rand -hex 24 | tr -d '\n' > "$tmp/root")
    secret zuul-db Opaque "password=$tmp/password" "root-password=$tmp/root"
    echo "zuul-db: new passwords for zuul and root" >&2
    ;;

  *) usage >&2; exit 2 ;;
esac
