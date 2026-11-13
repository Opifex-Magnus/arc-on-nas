#!/usr/bin/env bash
# lint.sh: every static check CI runs, runnable locally. Needs the tools pinned in mise.toml
# (`mise install`, then `mise exec -- scripts/lint.sh`) and network access to pull the two charts.
#
#   ShellCheck       scripts/*.sh
#   hadolint         images/*/Dockerfile
#   yamllint         every YAML file
#   actionlint       .github/workflows and examples/workflow.yml
#   helm lint        the ARC charts with helm/*.yaml
#   helm template    the same, rendered; the runner and listener pod templates are extracted
#   kubeconform      manifests/, the rendered charts and the extracted pod templates
#   kustomize        the build farm's server rendered, then kubeconform on it
#   jsonnet          the build farm's server configuration evaluates
#   consistency      scripts/check-consistency.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
chart_version=0.15.0
charts=oci://ghcr.io/actions/actions-runner-controller-charts
repo_url=https://github.com/OWNER/REPO
out=.cache/lint
step() { printf '\n== %s\n' "$1"; }

step shellcheck
shellcheck scripts/*.sh

step hadolint
hadolint images/*/Dockerfile

step yamllint
yamllint --strict .

step actionlint
actionlint .github/workflows/*.yml
# The example is a consumer's workflow; lint it as one.
actionlint examples/workflow.yml

step "helm pull $chart_version"
mkdir -p .cache/charts "$out"
for c in gha-runner-scale-set-controller gha-runner-scale-set; do
  if [ ! -d ".cache/charts/$c-$chart_version" ]; then
    rm -rf ".cache/charts/tmp" && mkdir -p .cache/charts/tmp
    helm pull "$charts/$c" --version "$chart_version" --untar --untardir .cache/charts/tmp
    mv ".cache/charts/tmp/$c" ".cache/charts/$c-$chart_version"
  fi
done
controller_chart=.cache/charts/gha-runner-scale-set-controller-$chart_version
scaleset_chart=.cache/charts/gha-runner-scale-set-$chart_version

step "helm lint"
helm lint "$controller_chart" -f helm/controller.yaml --namespace arc-systems
for s in swift ubuntu browser; do
  helm lint "$scaleset_chart" -f "helm/$s.yaml" --set githubConfigUrl="$repo_url" --namespace arc-runners
done

step "helm template"
helm template arc "$controller_chart" -f helm/controller.yaml --namespace arc-systems > "$out/controller.yaml"
for s in swift ubuntu browser; do
  helm template "$s" "$scaleset_chart" -f "helm/$s.yaml" --set githubConfigUrl="$repo_url" \
    --namespace arc-runners > "$out/$s.yaml"
  # The pods ARC will create from the templates, as Pod objects a schema can check.
  yq 'select(.kind == "AutoscalingRunnerSet") | {"apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "'"$s"'-runner", "namespace": "arc-runners"}, "spec": .spec.template.spec}' \
    "$out/$s.yaml" > "$out/$s-runner-pod.yaml"
  yq 'select(.kind == "AutoscalingRunnerSet") | {"apiVersion": "v1", "kind": "Pod",
      "metadata": {"name": "'"$s"'-listener", "namespace": "arc-systems"},
      "spec": (.spec.listenerTemplate.spec | .containers[0].image = "listener")}' \
    "$out/$s.yaml" > "$out/$s-listener-pod.yaml"
done
echo "rendered into $out/"

step kubeconform
# The Zuul test bed's tenant configuration (main.yaml) is Zuul's, not a Kubernetes object.
kubeconform -strict -summary -ignore-filename-pattern kustomization.yaml \
  -ignore-filename-pattern 'testbed-zuul/server/config/main\.yaml$' manifests/
# ARC's own resources (AutoscalingRunnerSet) have no published schema; everything else is checked.
kubeconform -strict -summary -skip AutoscalingRunnerSet \
  "$out/controller.yaml" "$out/swift.yaml" "$out/ubuntu.yaml" "$out/browser.yaml" \
  "$out/swift-runner-pod.yaml" "$out/ubuntu-runner-pod.yaml" "$out/browser-runner-pod.yaml" \
  "$out/swift-listener-pod.yaml" "$out/ubuntu-listener-pod.yaml" "$out/browser-listener-pod.yaml"

step kustomize
# The server's manifests with their generated ConfigMap, as the tenant applies them.
kustomize build manifests/tenants/build-farm/server > "$out/build-farm-server.yaml"
kubeconform -strict -summary "$out/build-farm-server.yaml"

step jsonnet
for f in manifests/tenants/build-farm/server/config/*.libsonnet manifests/tenants/build-farm/server/config/*.jsonnet; do
  jsonnet "$f" > /dev/null
  echo "$f evaluates"
done

step consistency
scripts/check-consistency.sh

printf '\nAll checks passed.\n'
