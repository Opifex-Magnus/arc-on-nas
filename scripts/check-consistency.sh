#!/usr/bin/env bash
# check-consistency.sh: values that must agree across files, checked in one place.
#
# Some values cannot be shared through a variable: the proxy's fixed address is needed by
# Docker, Squid, a NetworkPolicy and the Helm values; the chart and image versions are repeated in
# documentation and scripts. This fails if any copy differs from the source of truth named below.
# CI runs it (scripts/lint.sh); run it after changing any of them.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
status=0
problem() { echo "MISMATCH: $1"; status=1; }

# Source of truth: docker-compose.yml.
proxy=$(sed -n '/^  proxy:/,/^  [a-z]/{s/^ *ipv4_address: *\([0-9.]*\).*/\1/p}' docker-compose.yml)
subnet=$(sed -n 's/^ *- subnet: *\([0-9./]*\).*/\1/p' docker-compose.yml)
k3s_image=$(sed -n 's/^ *image: *\(rancher\/k3s:[^ ]*\).*/\1/p' docker-compose.yml)
[ -n "$proxy" ] && [ -n "$subnet" ] && [ -n "$k3s_image" ] || { echo "cannot read docker-compose.yml"; exit 1; }
echo "proxy $proxy, subnet $subnet, k3s $k3s_image"

grep -q "HTTPS_PROXY: http://$proxy:3128" docker-compose.yml || problem "docker-compose.yml: an HTTPS_PROXY is not http://$proxy:3128"
if grep -nE 'HTTPS?_PROXY: ' docker-compose.yml | grep -v "http://$proxy:3128"; then problem "docker-compose.yml: proxy URL above differs"; fi
grep -q "cidr: $proxy/32" manifests/networkpolicy-runners.yaml || problem "manifests/networkpolicy-runners.yaml: ipBlock is not $proxy/32"
grep -q "acl runners src $subnet " squid.conf || problem "squid.conf: 'acl runners src' does not include $subnet"
for f in helm/swift.yaml helm/ubuntu.yaml helm/browser.yaml; do
  n=$(grep -c "url: http://$proxy:3128" "$f" || true)
  [ "$n" -eq 2 ] || problem "$f: expected the http and https proxy URLs to be http://$proxy:3128"
done
node=$(sed -n '/^  k3s:/,/^  [a-z]/{s/^ *ipv4_address: *\([0-9.]*\).*/\1/p}' docker-compose.yml)
grep -q -- "--node-ip=$node$" docker-compose.yml || problem "docker-compose.yml: --node-ip is not the k3s service's ipv4_address $node"
# The tenant namespaces' egress policy and the API forwarder (README, "Tenant namespaces").
tenant_policy=manifests/tenants/base/networkpolicy.yaml
grep -q "cidr: $proxy/32" "$tenant_policy" || problem "$tenant_policy: the proxy's ipBlock is not $proxy/32"
grep -q -- "- $subnet$" "$tenant_policy" || problem "$tenant_policy: the stack subnet $subnet is not excepted"
grep -q -- "- TCP4:$node:6443$" api-forward.yml || problem "api-forward.yml: the forwarder's target is not $node:6443"
forward=$(sed -n 's/^ *ipv4_address: *\([0-9.]*\).*/\1/p' api-forward.yml)
[ "${forward%.*}.0/24" = "$subnet" ] || problem "api-forward.yml: the forwarder's address $forward is not in $subnet"
if [ "$forward" = "$node" ] || [ "$forward" = "$proxy" ]; then problem "api-forward.yml: $forward is taken"; fi
grep -q "^subnet=$subnet$" scripts/preflight.sh || problem "scripts/preflight.sh: subnet is not $subnet"
grep -q "NO_PROXY: .*,$subnet," docker-compose.yml || problem "docker-compose.yml: NO_PROXY does not include $subnet"
gateway=$(sed -n 's/^ *gateway: *\([0-9.]*\).*/\1/p' docker-compose.yml)
grep -q "PROXY: http://$proxy:3128$" .github/workflows/ci.yml || problem ".github/workflows/ci.yml: PROXY is not http://$proxy:3128"
grep -q "GATEWAY: $gateway$" .github/workflows/ci.yml || problem ".github/workflows/ci.yml: GATEWAY is not $gateway"

# The cache: the compose mount target, the PersistentVolume's path, the claim the values mount.
# shellcheck disable=SC2016 # a literal ${CACHE_DIR...} in the compose file
mount=$(sed -n 's/^ *- \${CACHE_DIR[^}]*}:\(\/[^ ]*\).*/\1/p' docker-compose.yml)
grep -q "path: $mount/" manifests/cache.yaml || problem "manifests/cache.yaml: hostPath is not under the compose mount $mount"
claim=$(awk '/^kind: PersistentVolumeClaim/ {f=1} f && /^  name:/ {print $2; exit}' manifests/cache.yaml)
for f in helm/swift.yaml helm/ubuntu.yaml helm/browser.yaml; do
  grep -q "claimName: $claim$" "$f" || problem "$f: claimName is not $claim"
  grep -q "mountPath: /home/runner/cache$" "$f" || problem "$f: the cache is not mounted at /home/runner/cache"
  grep -q "runAsUser: 1001$" "$f" || problem "$f: runAsUser is not 1001"
  grep -q "name: arc-gha-rs-controller$" "$f" || problem "$f: controllerServiceAccount is not arc-gha-rs-controller (release arc)"
done
for f in images/swift/Dockerfile images/ubuntu/Dockerfile images/browser/Dockerfile; do
  grep -q "^USER 1001$" "$f" || problem "$f: USER is not 1001"
done

grep -q "^image=$k3s_image$" scripts/trial.sh || problem "scripts/trial.sh: image differs from docker-compose.yml"

# The chart version: helm/controller.yaml's install command is the source of truth.
chart=$(sed -n 's/.*--version \([0-9][0-9.]*\) --namespace arc-systems.*/\1/p' helm/controller.yaml | head -n 1)
[ -n "$chart" ] || { echo "cannot read the chart version from helm/controller.yaml"; exit 1; }
echo "chart $chart"
if grep -rnoE -- '--version [0-9]+\.[0-9]+\.[0-9]+|gha-runner-scale-set-[0-9]+\.[0-9]+\.[0-9]+|CHART_VERSION: "?[0-9.]+|chart_version=[0-9.]+' \
     helm README.md .github/workflows scripts \
     | grep -vE -- "(--version |gha-runner-scale-set-|CHART_VERSION: \"?|chart_version=)$chart\"?$"; then
  problem "chart versions above differ from $chart"
fi

# The runner source image: the same tag and digest in every Dockerfile, and the tags in helm/.
base=$(sed -n 's/^FROM \(ghcr.io\/actions\/actions-runner:[^ ]*\).*/\1/p' images/swift/Dockerfile)
for f in images/ubuntu/Dockerfile images/browser/Dockerfile; do
  grep -q "^FROM $base$" "$f" || problem "$f: base differs from images/swift/Dockerfile"
  for arg in NODE_VERSION NODE_SHA256; do
    value=$(sed -n "s/^ARG $arg=//p" images/swift/Dockerfile)
    if [ -z "$value" ] || ! grep -q "^ARG $arg=$value$" "$f"; then
      problem "$f: $arg differs from images/swift/Dockerfile"
    fi
  done
done
# The browser image is the ubuntu image plus Chrome's libraries: every package installed in
# images/ubuntu/Dockerfile is installed in images/browser/Dockerfile too.
packages() {
  awk '/apt-get install/ {f = 1; next} f && /^ *&&/ {f = 0} f {gsub(/\\/, ""); print}' "$1" \
    | tr -s ' ' '\n' | sed '/^$/d' | sort -u
}
[ -n "$(packages images/ubuntu/Dockerfile)" ] || { echo "cannot read the packages in images/ubuntu/Dockerfile"; exit 1; }
missing=$(comm -23 <(packages images/ubuntu/Dockerfile) <(packages images/browser/Dockerfile) | paste -sd ' ' -)
[ -z "$missing" ] || problem "images/browser/Dockerfile: does not install the ubuntu image's $missing"
runner=${base#*:}
runner=${runner%%@*}
swift=$(sed -n 's/^ARG SWIFT_VERSION=//p' images/swift/Dockerfile)
echo "runner $runner, swift $swift"
# Any owner, and the digest you pin after building (README, "Quick start" step 8) or none yet;
# optionally quoted, optionally followed by a comment.
image_re() {
  local ref="ghcr\.io/[^/ \"]+/arc-runner-$1:${2//./\\.}(@sha256:[0-9a-f]{64})?"
  echo "^ *image: ($ref|\"$ref\")( +#.*)?$"
}
node=$(sed -n 's/^ARG NODE_VERSION=//p' images/swift/Dockerfile)
# Temporary migration exception: https://github.com/kristofk/arc-on-nas/issues/4
# Pin the first reviewed main/tag build in helm/, then
# remove both optional suffixes below in that same follow-up. README records the rollout gate.
grep -qE "$(image_re swift "$swift-$runner(-ubuntu26.04-node$node)?")" helm/swift.yaml || problem "helm/swift.yaml: image tag is not $swift-$runner"
grep -qE "$(image_re ubuntu "$runner(-node$node)?")" helm/ubuntu.yaml || problem "helm/ubuntu.yaml: image tag is not $runner"
grep -qE "$(image_re browser "$runner-node$node")" helm/browser.yaml || problem "helm/browser.yaml: image tag is not $runner-node$node"

# Helper images used by more than one script.
alpine_pre=$(sed -n 's/^test_image=//p' scripts/preflight.sh)
alpine_trial=$(sed -n 's/^pod_image=//p' scripts/trial.sh)
[ "$alpine_pre" = "$alpine_trial" ] || problem "scripts/preflight.sh and scripts/trial.sh use different alpine images"

[ "$status" -eq 0 ] && echo "All consistent."
exit "$status"
