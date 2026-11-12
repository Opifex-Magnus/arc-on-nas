# Changelog

All notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Tenant namespaces (`manifests/tenants/`, README "Tenant namespaces"): `zuul-trial` and
  `build-farm`, for users other than the cluster admin, each with Pod Security `baseline` enforced
  and `restricted` warned and audited, a ResourceQuota (CPU, memory, storage and a count of every
  kind a tenant may create) and LimitRange, a Role limited to namespaced workload, configuration
  and Service resources bound to two users, and NetworkPolicies that admit only the namespace's
  own pods and keep egress off the host and the node. Admission policies close what `baseline`
  leaves open: every container drops `NET_RAW` (added when missing), only `restricted`'s volume
  types without `csi`, images only from internet registries (also on updates), no Service
  `externalIPs`. `scripts/tenant-cert.sh` signs a user's certificate request after checking its
  subject, attributes and the stored copy, for 90 days, and writes a kubeconfig without a key;
  `api-forward.yml` forwards the API server's port 6443, and nothing else, to another Docker
  network. The smoke test checks all of it.
- A browser runner image, `arc-runner-browser`, and its example scale set `helm/browser.yaml`: the
  Ubuntu image plus the shared libraries and fonts headless Chrome for Testing needs, so jobs can
  run page tests without installing packages. Image CI downloads a pinned Chrome for Testing build,
  checks its libraries with `ldd` and starts it headless as uid 1001, drawing with WebGL
  (SwiftShader) and Canvas 2D. `helm/browser.yaml` pins the build of Images run 41937445042 on
  main by digest.

### Changed

- Swift runners use Ubuntu 26.04 and swift.org's matching Swift 6.4.0 build, verified by its
  release signature and pinned SHA-256, while retaining GitHub's runner and container hooks.
- Both runner images bundle Node 24.22.0; the shared Swift/image runner also carries Caddy
  2.11.7, Python 3.10 or newer, curl, jq, buildctl 0.34.0 and kubectl 1.36.5 (#2).
- Image CI builds pull requests without publishing, checks the runner and tools as uid 1001,
  compiles, links, runs and tests a Foundation package, checks the runner's TLS/globalization
  with an expected GitHub authentication rejection, and publishes only from main or v* tags
  with Node (and Swift's Ubuntu release) in their tags. Existing Helm image digests stay pinned
  until an operator updates them.
- The Swift image omits the upstream image's lsb-release, software-properties-common and Docker
  daemon/containerd binaries; the Docker client, buildx, Git, curl, jq and container hooks remain.

## [0.1.0] - 2026-10-09

First release.

### Added

- A Compose stack: k3s `v1.36.5+k3s1` as a single privileged node on an internal Docker network,
  a Squid egress proxy that refuses private destinations and rotates its access log, and an
  on-demand Helm `3.22.0` client.
- Manifests: the `arc-systems` and `arc-runners` namespaces with Pod Security labels, NetworkPolicies
  (runner pods reach only DNS and the proxy; nothing reaches the controller), and a static
  PersistentVolume and claim for the warm build cache.
- Helm values for Actions Runner Controller `0.15.0`: the controller and two scale sets, `swift`
  (`minRunners: 1`) and `ubuntu` (`minRunners: 0`), with restricted pod templates, requests equal
  to limits, the proxy and the cache.
- Runner images on `ghcr.io/actions/actions-runner:2.338.0` without sudo: `swift` (Swift `6.4.0`)
  and `ubuntu` (common build tools), and a workflow that builds and pushes them.
- Scripts: `preflight.sh` (which also prints the `.env` sizing for a budget), `trial.sh`,
  `register.sh`, `warm.sh`, `prune-cache.sh`, and for development `lint.sh` and
  `check-consistency.sh`.
- An example consumer workflow with routing to GitHub-hosted runners as a fallback.
- CI: static checks and a smoke test of the stack on a GitHub-hosted runner.

[Unreleased]: https://github.com/kristofk/arc-on-nas/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kristofk/arc-on-nas/releases/tag/v0.1.0
