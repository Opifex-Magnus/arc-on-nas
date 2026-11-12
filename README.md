# arc-on-nas

[![CI](https://github.com/kristofk/arc-on-nas/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kristofk/arc-on-nas/actions/workflows/ci.yml?query=branch%3Amain)

Self-hosted GitHub Actions runners on a single Docker host, such as a NAS, using GitHub's
[Actions Runner Controller](https://github.com/actions/actions-runner-controller) (ARC) on a
one-node [k3s](https://k3s.io) cluster that runs as a Docker Compose service. Jobs run in
ephemeral pods (one pod per job, deleted afterwards), are admitted by the Kubernetes scheduler
within fixed CPU and memory budgets so the host's other workloads keep priority, share a warm
build cache on the host's disk, and reach the internet only through an egress proxy that refuses
private addresses.

**Who it is for:** someone with one always-on Docker host (a NAS, a home server, a small VM host)
that already runs other services which must keep working, who wants CI jobs for their own
private repositories to run there instead of on GitHub-hosted minutes, and who manages that host
with Compose files rather than a Kubernetes distribution. It is not for multi-node clusters, for
public repositories (see [Limitations](#limitations)), or for jobs that need Docker.

Contents: [Status](#status) · [How it works](#how-it-works) · [Security posture](#security-posture) ·
[Requirements](#requirements) · [Quick start](#quick-start) · [Sizing](#sizing) ·
[Adding a toolchain](#adding-a-toolchain) · [Adding a repository](#adding-a-repository) ·
[Tenant namespaces](#tenant-namespaces) · [Building the images](#building-the-images) · [Operations](#operations) ·
[Troubleshooting](#troubleshooting) · [FAQ](#faq) · [Limitations](#limitations) ·
[Layout](#repository-layout)

## Status

Version 0.1.0, the first release. Pinned: k3s `v1.36.5+k3s1`, ARC charts `0.15.0`, runner
`2.338.0`, Swift `6.4.0`, Squid 6 (`ubuntu/squid:6.6-24.04_edge`), Helm `3.22.0`. Every image this
repository starts itself (compose services, CI, the scripts' test images, the runner images'
base) is pinned by digest; the runner images in `helm/` are pinned to the digests of the images
this repository's CI built (below); new packages on `ghcr.io` start private and their visibility is
the owner's to set, so pin your own build's reference and digest instead. The controller and listener images follow the chart version, and k3s's bundled
images follow the k3s release.

**Built once by CI.** [`images.yml`](.github/workflows/images.yml) built both runner images on
2026-10-10 (run 38055256920, dispatched on `main`), and the digests in `helm/` are that run's. The
first attempt (run 38055141576) failed at removing `sudo`, which Debian's package tools refuse
without `SUDO_FORCE_REMOVE=yes`; the Dockerfiles now set it. The images have been built and pushed,
not yet pulled or run by a cluster.

**Verified by this repository's CI** ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) on a
GitHub-hosted Ubuntu 24.04 runner (2 CPUs and 8 GB for a private repository, Docker 28 with
cgroup v2 on ext4):

- every static check: ShellCheck, hadolint, yamllint, actionlint, `helm lint` and `helm template`
  of both charts with the values in [`helm/`](helm), kubeconform on [`manifests/`](manifests),
  on the rendered charts and on the runner and listener pods the values produce, and
  [`scripts/check-consistency.sh`](scripts/check-consistency.sh);
- `scripts/preflight.sh` and `scripts/trial.sh` run to completion;
- the stack: `docker compose up` with this `docker-compose.yml`, the node `Ready` with every image
  pulled through the proxy, the manifests applied and the cache claim bound,
  `scripts/register.sh` storing both credential forms, the controller chart installed by the
  `helm` service through the proxy and its pod running, the controller pod compliant with Pod
  Security `restricted`, both runner pod templates admitted by `restricted` and a privileged pod
  refused;
- the k3s container idles at about 0.5 GiB of memory with no workloads (`trial.sh` on the
  hosted runner);
- the kubelet changing host-wide kernel settings ([Security posture](#security-posture)):
  `trial.sh` on the hosted runner reported `vm.overcommit_memory` 0 → 1, `kernel.panic` -1 → 10
  and `kernel.panic_on_oops` 0 → 1;
- egress from a pod shaped like a runner (uid 1001, restricted, the cache claim mounted): the
  cache is writable; HTTPS to github.com through the proxy works; the proxy refuses a link-local
  and a private address; cluster DNS works; the internet without the proxy is unreachable; a port
  on the host behind the stack network's gateway is reachable from a plain container on that
  network but not from the pod (the NetworkPolicy; the plain container is the control). Without
  the proxy the pod reaches nothing on the internet, which the internal network alone explains.
- the proxy's health check: it passes, and its command, run by hand on an access log padded past
  10 MB, rotates the log.

**Not verified, because a hosted runner cannot show it.** Each is a documented step in the
[Quick start](#quick-start) or [Operations](#operations), not an assumption:

- **Any NAS.** Nothing here has run on a NAS or on ZFS. `preflight.sh` and `trial.sh` are the
  test of your host; run them first.
- **A scale set registering with GitHub and running a job.** That needs a real credential and a
  repository; the smoke test installs only the controller. The listener's restricted
  security context (from `listenerTemplate`) is schema-checked but has never run, which is why
  `arc-systems` enforces `baseline`, not `restricted`.
- **The runner images in a cluster.** No pod tested by this repository has pulled or run them,
  and no registered ARC job is part of its CI. `images.yml` now tests the runner's .NET startup,
  Swift execution and bundled tool versions in Docker as uid 1001 before publishing. That is
  separate from a real registered job on your host.
- **The warm cache under real builds,** including SwiftPM's lock behaviour across pods and
  `prune-cache.sh` on a real cache.
- **The sizing numbers** in `.env.example` and [Sizing](#sizing): arithmetic from published
  figures, not measurements on your host.
- **How scale-set runners appear in GitHub's REST API** (their names and labels), which the
  example workflow's routing job relies on. Check after the first deploy
  ([Quick start](#quick-start), step 11).
- Egress details beyond those checks: that only ports 80 and 443 pass the proxy, that a public
  name resolving to a private address is refused, pod-to-pod isolation, and whether pods can
  resolve public names (CoreDNS has no reachable upstream on the internal network, so they should
  not; the proxy resolves for them).
- Whether a GitHub App owned by a personal account (rather than an organisation) works for
  repository-level registration; GitHub documents organisation-owned apps only.

## How it works

```
 host (Docker)
 ├─ ci-k3s-1   privileged; the Kubernetes node   ── stack network (internal, 172.31.250.0/24) ──┐
 │   ├─ arc-systems   controller, one listener per scale set                                      │
 │   └─ arc-runners   ephemeral runner pods  ── NetworkPolicy: DNS + proxy only                    │
 │        └─ /home/runner/cache  ◄── PersistentVolume ◄── CACHE_DIR on the host                    │
 └─ ci-proxy-1  Squid  ───────────────────────────────────────────────────────────────────────────┘
        └─ egress network ── internet (ports 80 and 443, public addresses only)
```

**k3s as one Compose service.** [`docker-compose.yml`](docker-compose.yml) runs the official
`rancher/k3s` image as a single server with no agents, the pattern k3s documents under
["Running K3s in Docker"](https://docs.k3s.io/advanced). One container holds the API server, a
SQLite datastore, the kubelet and containerd, plus what k3s bundles: CoreDNS, a NetworkPolicy
controller, metrics-server. Traefik, ServiceLB and k3s's Helm controller are disabled. Cluster
state lives in named Docker volumes, so `docker compose down` and host reboots keep it;
`restart: unless-stopped` brings the node back after a reboot and the controllers recreate the
pods. The cluster is disposable: its only state worth keeping is the GitHub credential, which you
can create again.

**The controller.** ARC's `gha-runner-scale-set-controller` chart runs in `arc-systems`. For each
scale set it starts a *listener* pod (also in `arc-systems`) that holds a long-poll HTTPS
connection to GitHub's Actions service; nothing connects inward, no webhook, no published port.

**Ephemeral runners.** Each scale set is one release of the `gha-runner-scale-set` chart, and
its release name is what workflows put in `runs-on:`. When a job is queued, the controller
creates a pod in `arc-runners` with a single-use just-in-time registration; the pod runs one job
and is deleted. `minRunners` keeps that many idle pods waiting; `maxRunners` caps concurrency.
This repository ships two examples: `swift` (a toolchain image, `minRunners: 1`) and `ubuntu`
(generic build tools, `minRunners: 0`). Jobs run inside the runner container itself (ARC's
default container mode); there is no Docker daemon.

**The warm cache.** A host directory (`CACHE_DIR`) is bind-mounted into the node and exposed as a
static PersistentVolume and claim ([`manifests/cache.yaml`](manifests/cache.yaml)); every runner
pod mounts it at `/home/runner/cache` and finds its path in `$CI_CACHE`. On one node a
ReadWriteOnce volume can be mounted by every pod at once. Workflows keep build folders there,
outside the job's fresh checkout, so the next job only compiles what changed. One claim per
repository: every job can write what later jobs read.

**The resource model.** Three layers:

1. The k3s container's caps (`cpus`, `mem_limit`, `pids_limit`) bound the whole cluster.
   `cpu_shares` gives it a lower CPU weight than the host's other containers, so under contention
   they win; when the host is idle the cluster may use everything up to its cap.
2. The kubelet sees the whole host, not the container's caps. `system-reserved` and
   `kube-reserved` subtract enough from its capacity that what is left (*allocatable*) fits
   inside the caps.
3. Every pod's requests equal its limits. The scheduler admits pods against allocatable; a pod
   that does not fit stays `Pending` and its job waits until an earlier pod finishes. Nothing
   looks at the host's actual load: see [Limitations](#limitations).

**The egress proxy.** The node sits on an `internal` Docker network, which Docker gives no route
out. Its only way to the internet is the Squid container ([`squid.conf`](squid.conf)), the one
container also on an outbound network. Squid forwards HTTP and HTTPS (ports 80 and 443) to public
addresses and refuses private, loopback, link-local, carrier-grade-NAT and multicast ranges after
resolving the name. containerd's image pulls use it (`HTTPS_PROXY` on the node); ARC sets it for
the controller's GitHub calls, the listeners and the runners (`proxy:` in the values). Squid's
access log lists every host contacted. A NetworkPolicy in `arc-runners` lets runner pods reach
only the cluster DNS and the proxy.

## Security posture

**The k3s container is privileged, and that makes it equivalent to root on the host.** A
Kubernetes node in a container needs it: k3s's and kind's own sources say so, and neither has a
tested smaller set of capabilities. `privileged: true` gives the container every capability, no
seccomp or AppArmor profile, every host device (`/dev`, so the disks), a writable `/proc/sys` and
`/sys/fs/cgroup`, and the ability to mount filesystems and load kernel modules. Whoever controls
the k3s process, or gets root in that container, controls the host. Treat the container like a
host service. This is strictly more exposure than running each runner as an unprivileged
container; it buys ephemeral pods, scheduler admission and the shared cache.

**The kubelet changes host-wide kernel settings, and you cannot keep yours.** Because `/proc/sys`
is writable, the kubelet compares six settings with the values it wants and, at every start,
writes its values over yours, for the whole host: `vm.overcommit_memory=1`, `vm.panic_on_oom=0`,
`kernel.panic=10`, `kernel.panic_on_oops=1`, `kernel.keys.root_maxkeys=1000000`,
`kernel.keys.root_maxbytes=25000000` (Kubernetes' `setupKernelTunables`). `--protect-kernel-defaults`
in `K3S_EXTRA_ARGS` does not keep your values either: with it, the kubelet refuses to start unless
the six are already set to its values. So there is no configuration of this stack that runs with
`kernel.panic_on_oops=0`: running it means a kernel oops reboots the host after 10 seconds. The
node sets the values again every time it starts, including after a host reboot while the stack is
up (`restart: unless-stopped`). They stay set after `docker compose down`, until the host reboots
or you reset them by hand. `preflight.sh` prints your current values; record them before the first
start, and restore them after `docker compose down`:

```sh
sysctl vm.overcommit_memory vm.panic_on_oom kernel.panic kernel.panic_on_oops \
  kernel.keys.root_maxkeys kernel.keys.root_maxbytes | tee sysctl-before.conf
sudo sysctl -p sysctl-before.conf      # after `docker compose down`: back to the recorded values
```

`trial.sh` records them itself, restores them when run as root, and otherwise prints the
`sudo sysctl -w` lines that restore them. kube-proxy would also try to set the host-wide
`nf_conntrack_max`, which the kernel refuses from a container's network namespace (the k3d FAQ's
`nf_conntrack_max: permission denied`); the compose file tells it not to. `trial.sh` watches only
the six kubelet settings above; other host-wide writes by a privileged node are possible.

**The point of the design is that jobs never run as the node.** A job runs in a pod under it, and
the pod boundary is what a job sees:

| | A job in a runner pod |
|---|---|
| User | uid 1001, no capabilities (`drop: [ALL]`), `allowPrivilegeEscalation: false`, seccomp `RuntimeDefault`. The images have no `sudo`. `arc-runners` enforces Pod Security `restricted`, so the API server refuses a runner pod that runs as root, keeps capabilities other than `NET_BIND_SERVICE`, allows privilege escalation, lacks a seccomp profile or mounts a hostPath; the refusal shows when the controller creates the pod, in the controller's log and the namespace's events, not at `helm install`. (`restricted` does not pin the uid to 1001.) |
| Files | its image, its job's empty workspace, the cache claim. Nothing else from the node or the host; the host's Docker socket is mounted nowhere. |
| Network | the proxy (public addresses on ports 80 and 443) and cluster DNS. Not the LAN, not the host's ports through the stack network's gateway, not other pods. Assume it can reach the node's own ports (the API server, the kubelet): the Kubernetes documentation says traffic between a pod and its own node is always allowed. (In this repository's smoke test the API server's service address was not reachable from a runner-like pod; do not rely on that.) |
| Kubernetes API | nothing: no service account token is mounted, and the runner's service account has no permissions. |
| Credentials | its single-use registration, and the job's `GITHUB_TOKEN` with the permissions the workflow grants. Not the scale set's GitHub credential, which is in Secrets the pod cannot read (in `arc-runners` and, mirrored for the listener, in `arc-systems`). |

What stays exposed: a kernel exploit from inside a pod lands on the host, as with any container,
but here the node it escapes into is privileged. A mistake in a pod template would be refused by
Pod Security in `arc-runners`; `arc-systems` enforces `baseline` (no privileged pods, host
namespaces or hostPath) and warns on anything below `restricted`. Docker's internal network does
not stop the *node* container from reaching the host's ports through the network's gateway
([Docker's documentation](https://docs.docker.com/reference/cli/docker/network/create/#internal));
the NetworkPolicy blocks that path for runner pods, and a host firewall rule on the interface
`br-ci-runners` would close it for the node too. A job can send what it can read to any public
host through the proxy.

**Public repositories: do not.** GitHub: "We recommend that you only use self-hosted runners with
private repositories. This is because forks of your public repository can potentially run
dangerous code on your self-hosted runner machine"
([add runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)).
Register only private repositories, and keep their "Fork pull request workflows" setting off.

**The kubeconfig** in `./kubeconfig/` is a cluster-admin client certificate. It is written by k3s
with mode 600 into a root-owned directory with mode 700, the API server is published on no port,
and administration happens with `docker compose exec k3s kubectl ...` on the host. Do not copy it
off the host.

**The GitHub credential** is stored only in Kubernetes Secrets: the one
[`scripts/register.sh`](scripts/register.sh) creates in `arc-runners` from a file or a prompt, and a
copy the controller mirrors into `arc-systems` for each scale set's listener (so
`kubectl get secrets -A` lists it twice). k3s keeps Secrets in its
SQLite datastore in the `k3s-data` volume, unencrypted unless you add `--secrets-encryption` to
`K3S_EXTRA_ARGS`; root on the host can read it either way.

**Tenant namespaces**, if you add them, are a second way into the cluster: users other than the
admin, with certificates allowed their own namespaces, reaching the API server through a
forwarder. What they can and cannot reach: [Tenant namespaces](#tenant-namespaces).

Reporting a vulnerability: [SECURITY.md](SECURITY.md).

## Requirements

- **Docker Engine 27 or later with Docker Compose v2** (2.24 or later), rootful, able to run
  privileged containers. A user-namespace-remapped daemon should work (the node opts out with
  `userns_mode: host`; untested); rootless Docker does not. CI runs on Docker 28 and Compose 2.38;
  27 and 2.24 are the oldest versions whose features the compose file uses, not tested ones.
- **cgroup v2** (the unified hierarchy) with the `cpu`, `memory`, `pids` and `cpuset` controllers.
- **A kernel with overlayfs** and the `br_netfilter` and `nf_conntrack` modules, and Docker's
  `overlay2` storage driver. The node's containerd mounts overlayfs on a Docker volume.
- **inotify limits** of at least `fs.inotify.max_user_watches=524288` and
  `fs.inotify.max_user_instances=512`, set persistently on the host (many NAS systems have a
  "sysctl" or "tunables" page for this). Many distributions default to 8192 and 128, which a
  Kubernetes node outgrows.
- **ZFS:** overlayfs on ZFS needs OpenZFS 2.2 or later
  ([2.2.0 release notes](https://github.com/openzfs/zfs/releases/tag/zfs-2.2.0)). If your Docker
  data root is on ZFS and Docker's `overlay2` already works there, the nested containerd should
  too, but the kubelet's disk accounting on pseudo-devices (ZFS, btrfs) has known failure modes
  ([kind known issues](https://kind.sigs.k8s.io/docs/user/known-issues/)). `trial.sh` is the test;
  the fallback is `K3S_SNAPSHOTTER=native`. Put `CACHE_DIR` on a dataset without snapshots.
- **Resources:** about 1.6 GB of memory for the control plane (k3s's own measurement,
  [resource profiling](https://docs.k3s.io/reference/resource-profiling)), plus what the runner
  pods need. The example sizing (`.env.example`, [Sizing](#sizing)) is for a host with 16 CPUs and
  32 GiB that gives CI 10 CPUs and 17 GiB; on any other host, recompute it before the first `up`
  (`preflight.sh` prints the values for a budget you give it). A useful budget starts at about 4 CPUs
  and 8 GiB: the control plane, the system pods and the headroom take about 1.6 CPUs and 4.5 GiB of
  it, which leaves room for one `swift` pod.
- **The stack subnet** `172.31.250.0/24` must not collide with another Docker network or a route
  on the host (`preflight.sh` checks).
- Outbound HTTPS to GitHub (the hosts in GitHub's
  [self-hosted runner reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)),
  `ghcr.io` and Docker Hub. No inbound connections.

## Quick start

One-time steps on the host, in the directory you clone this repository into (the *stack
directory*). Commands assume a user that may run `docker`; prefix `sudo` where your host
requires it (for the scripts, `DOCKER="sudo docker" scripts/...`).

1. **Clone.**
   ```sh
   git clone https://github.com/kristofk/arc-on-nas.git ci && cd ci
   ```
2. **Pre-flight checks.** Prints facts about the kernel, cgroups, Docker, storage, free resources
   and the stack subnet; changes nothing persistent (its overlayfs test runs a throwaway privileged
   container on a throwaway volume, removes both, and leaves the small `alpine` image it pulled).
   Fix every `FAIL`.
   ```sh
   scripts/preflight.sh
   ```
3. **The trial.** Starts a throwaway node named `k3s-trial`, waits for it to be `Ready`, runs a pod,
   reports the control plane's memory and the node's capacity, lists suspicious log lines and the
   host kernel settings the kubelet changed, and removes everything. Run it as root to have
   those settings restored. If it fails on storage, retry with `--snapshotter native`, and if that
   works put `K3S_SNAPSHOTTER=native` in `.env`.
   ```sh
   sudo scripts/trial.sh
   ```
4. **Directories and settings.** The cache directory and its first claim directory, owned by the
   runner (uid and gid 1001); the kubeconfig directory, root-owned with mode 700; `.env` from the
   example, with `CACHE_DIR` and the sizing for your host. The example's sizing is for a 16-CPU,
   32 GiB host; replace its four `K3S_*` sizing lines with the ones `preflight.sh` prints for the
   budget you give CI ([Sizing](#sizing)).
   ```sh
   sudo install -d -o 1001 -g 1001 -m 750 /path/to/ci-cache/default
   sudo install -d -o 0 -g 0 -m 700 kubeconfig
   BUDGET_CPUS=4 BUDGET_GIB=8 scripts/preflight.sh    # prints the K3S_* lines for that budget
   cp .env.example .env && chmod 600 .env && "${EDITOR:-vi}" .env
   scripts/preflight.sh            # now also checks .env's sizing, CACHE_DIR and kubeconfig/
   ```
5. **Bring the stack up** and wait for the node. The first start pulls k3s's system images
   through the proxy.
   ```sh
   docker compose up -d --wait
   docker compose exec k3s kubectl wait --for=condition=Ready node/ci-node --timeout=300s
   docker compose exec k3s kubectl get node ci-node -o jsonpath='{.status.allocatable}{"\n"}'
   ```
   Check that the allocatable CPU and memory are what you sized for.
6. **Namespaces, NetworkPolicies and the cache volume.**
   ```sh
   docker compose exec k3s kubectl apply -k /opt/arc-on-nas/manifests
   docker compose exec k3s kubectl -n arc-runners get pvc ci-cache    # STATUS Bound
   ```
7. **The GitHub credential.** For a repository on a personal account: a
   [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new)
   with access to the CI repositories only, repository permission **Administration: Read and
   write**, and an expiry date you put in your calendar. For an organisation, see
   [Adding a repository](#adding-a-repository). Then store it; the script prompts and never takes
   the token as an argument:
   ```sh
   scripts/register.sh
   ```
8. **The runner image.** Build it in a GitHub repository of your own: fork this repository (or
   push your clone to a new repository of yours), and enable Actions there (GitHub disables a
   fork's workflows until you do, on its Actions tab). Then run
   [`images.yml`](.github/workflows/images.yml) in it (push a tag `v*`, or
   `gh workflow run Images --repo OWNER/arc-on-nas`); it pushes to your account's packages on
   `ghcr.io` with the `packages: write` permission it declares. Put the printed
   `image@sha256:...` into `helm/swift.yaml` (and `helm/ubuntu.yaml`), replacing the `image:` line
(the files hold the repository owner's build). If the
   package is private, see [Building the images](#building-the-images).
9. **The controller.**
   ```sh
   docker compose run --rm helm upgrade --install arc \
     oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
     --version 0.15.0 --namespace arc-systems -f helm/controller.yaml --wait
   docker compose exec k3s kubectl -n arc-systems get pods            # arc-gha-rs-controller-... Running
   ```
10. **A runner scale set,** bound to one repository:
    ```sh
    docker compose run --rm helm upgrade --install swift \
      oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
      --version 0.15.0 --namespace arc-runners -f helm/swift.yaml \
      --set githubConfigUrl=https://github.com/OWNER/REPO --wait
    docker compose exec k3s kubectl -n arc-systems get pods            # swift-...-listener Running
    docker compose exec k3s kubectl -n arc-runners get pods            # one swift-...-runner-... Running
    ```
    The repository's Settings → Actions → Runners now lists the scale set `swift` with one idle
    runner. Repeat with `ubuntu` and `helm/ubuntu.yaml` if you want the generic set for the same
    repository (it shares that repository's cache claim); a set for another repository needs its
    own claim ([Adding a repository](#adding-a-repository)).
11. **Point a workflow at it:** `runs-on: swift`. [`examples/workflow.yml`](examples/workflow.yml)
    is a complete workflow that routes to the scale set when a runner is online and to
    GitHub-hosted runners otherwise. Before relying on its routing, check how GitHub lists the
    scale set's runners (the example matches a name starting `swift-` or a label `swift`):
    ```sh
    gh api repos/OWNER/REPO/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
    ```
    Run the workflow, then read which hosts the job contacted:
    `docker compose exec -u proxy proxy tail -n 50 /var/log/squid/access.log`.

## Sizing

The numbers that must agree, for a host whose kubelet reports `C` CPUs and `M` MiB (the node's
capacity; `preflight.sh` prints both):

```
allocatable    A = what the runner pods and the system pods may request, all at once
kube-reserved  K = the control plane: 500m CPU, 1536Mi (from k3s's measured 1.6 GB)
system-reserved  = C - A - K   (CPU and memory alike)
K3S_CPUS       >= A + K, plus headroom
K3S_MEMORY     >  A + K + headroom      (never less: see below)
maxRunners × pod size + system pods (~0.6 CPU, ~0.7 GiB) <= A
```

k3s's kubelet sets no memory eviction threshold, so nothing else is subtracted (the smoke test's
node reported exactly capacity minus both reservations). The memory rule is strict. The kubelet computes evictions from the host's memory, not the
container's limit, so it never evicts to protect `K3S_MEMORY`. If the pods' limits plus the
control plane exceed it, the kernel's OOM killer acts inside the container, and it may pick k3s
itself (which restarts; running jobs fail).

Example, the defaults in `.env.example`, for a host reporting 16 CPUs and 32 GiB with 4 cores and
about 15 GiB kept for everything else (a budget of 10 CPUs and 17 GiB for CI):

| | CPU | Memory |
|---|---|---|
| Capacity | 16 | 32768Mi |
| `K3S_SYSTEM_RESERVED` | 6500m | 17664Mi |
| `K3S_KUBE_RESERVED` | 500m | 1536Mi |
| Allocatable | 9 | 13568Mi (13.25 GiB) |
| `swift`: `maxRunners: 4` × 2 CPU, 3 GiB | 8 | 12 GiB |
| System pods (CoreDNS, metrics-server, controller, two listeners) | ~0.6 | ~0.7 GiB |
| `K3S_CPUS` / `K3S_MEMORY` (hard caps) | 10 | 17 GiB |
| Left to the host at full CI load / when CI is idle | 6 / 16 | 15 GiB / all |

`preflight.sh` does this arithmetic for your host: give it the budget, and it prints the four
`K3S_*` sizing lines for `.env`, with the example's headroom (0.5 CPU and 2.25 GiB above
allocatable plus `kube-reserved`). With a `.env`, it also checks the sizing against the host.

```sh
BUDGET_CPUS=10 BUDGET_GIB=17 scripts/preflight.sh    # on the example host: the values above
```

The `ubuntu` and `browser` sets (1 CPU, 2 GiB per pod) share the same allocatable: when the Swift pods fill it,
their pods wait, and the other way round. Pod sizes are a trade: 2 CPUs and 3 GiB suits a
medium Swift package; fewer, larger pods finish each job sooner, more, smaller pods run more jobs
at once. Keep requests equal to limits either way, and tell the tools in the job the pod's CPU
count (`RUNNER_CPUS`, or the cgroup quota as `examples/workflow.yml` reads it): inside a pod, the
software still sees every host core.

## Adding a toolchain

A toolchain is an image plus a scale set.

1. Add `images/<name>/Dockerfile` using the same pinned `ghcr.io/actions/actions-runner` source,
   install the toolchain (by checksum), omit or remove `sudo` as the existing images do, and end with
   `USER 1001`. The runner must stay at `/home/runner` with `/home/runner/run.sh`, and the
   container must be named `runner` in the values (ARC's requirements).
2. Add the image to the matrix in `.github/workflows/images.yml`, and its tag check to
   `scripts/check-consistency.sh` if it has its own version.
3. Copy `helm/ubuntu.yaml` to `helm/<name>.yaml`; set the image, the pod size (requests equal to
   limits), `RUNNER_CPUS`, `minRunners` and `maxRunners`, and redo the [Sizing](#sizing) sum.
4. Install it as in [Quick start](#quick-start) step 10 with the release name `<name>`; workflows
   use `runs-on: <name>`.

## Adding a repository

A scale set is bound to one `githubConfigUrl`. What that URL can be depends on who owns the
repositories.

**Facts from GitHub's documentation:**

- "Runner scale sets can be deployed at the repository, organization, or enterprise levels"
  ([deploy runner scale sets](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)).
  There is no user-account level: on a personal account, every repository needs its own scale
  set.
- Credentials
  ([authenticate to the API](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api)):

  | Method | Repository level | Organization level |
  |---|---|---|
  | GitHub App | Administration: read and write; Metadata: read-only | Self-hosted runners: read and write; Metadata: read-only |
  | Personal access token (classic) | `repo` | `admin:org` |
  | Fine-grained personal access token | Administration: read and write | Administration: read; Self-hosted runners: read and write |

  The documented GitHub App path starts with "Create a GitHub App that is owned by an
  organization". Enterprise-level scale sets need a classic token.
- Runner groups decide which repositories of an organisation may use a scale set: "All
  organizations have a single default runner group", additional groups need a paid plan, and "by
  default, only private repositories can access runners in a runner group"
  ([manage access](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/manage-access)).
  Repository-level scale sets have no group: leave `runnerGroup` unset.

**On a personal account**, for each additional repository:

1. Extend the fine-grained token to that repository (or create a second one and store it under
   another Secret name with `scripts/register.sh --name ...`, then set `githubConfigSecret`).
2. Give it its own cache: copy both objects in `manifests/cache.yaml` with a new name and
   subdirectory, create the directory owned by 1001:1001, apply.
3. Install the chart again with a release name of its own, its URL and the new claim, for
   example `swift-otherrepo` with `--set githubConfigUrl=https://github.com/OWNER/OTHERREPO` and
   `--set template.spec.volumes[1].persistentVolumeClaim.claimName=ci-cache-otherrepo`. Each
   release costs one small listener pod, and nothing else while idle at `minRunners: 0`.

**In an organisation**, one scale set per toolchain serves every repository:
`--set githubConfigUrl=https://github.com/ORG`, authenticated by a GitHub App owned by the
organisation and installed on it (`scripts/register.sh --app-id ... --installation-id ...
--private-key-file ...`), with runner groups choosing the repositories. Workflows in any allowed
repository use `runs-on: <name>` without touching the cluster. Repositories then share the scale
set and therefore its cache claim; give untrusted-to-each-other repositories separate scale sets.

## Tenant namespaces

Optional. A tenant namespace is one that somebody other than the cluster admin deploys into:
another project's trial, a build farm, an agent that measures what it builds. Each tenant user
gets a client certificate that is allowed their namespaces and nothing else: no shell on the
host, no admin kubeconfig, no other namespace. [`manifests/tenants/`](manifests/tenants) ships two,
`zuul-trial` and `build-farm`, with two users; rename the directories and edit
`base/rolebinding.yaml` for yours.

| | A tenant user |
|---|---|
| Kubernetes API | in their namespaces only ([`base/role.yaml`](manifests/tenants/base/role.yaml)): pods (with logs, `exec`, `attach`, `port-forward`), Deployments, StatefulSets, ReplicaSets, DaemonSets, Jobs, CronJobs, Services, ConfigMaps, Secrets, PersistentVolumeClaims, ServiceAccounts, HorizontalPodAutoscalers, PodDisruptionBudgets, Leases; read-only events, endpoints, NetworkPolicies, the quota and limits, pod metrics. Nothing cluster-scoped, no Roles or RoleBindings, no `escalate`, `bind` or `impersonate`. Like every authenticated user, they may also read the API's discovery documents and ask what they are allowed. |
| Pods | Pod Security `baseline` enforced, `restricted` warned about and audited: no privileged containers, no host network, PID or IPC namespace, no `hostPath`, no host ports, no capabilities beyond the runtime's defaults. On top of that ([`admission.yaml`](manifests/tenants/admission.yaml), which says why): every container drops `NET_RAW` (added for pods that do not), only `restricted`'s volume types without `csi`, images only from registries on the internet (not localhost, an IP address or a cluster Service), and no Service with `externalIPs`. No PriorityClass, so a tenant's pod never preempts a runner. Unlike the runners, tenant pods may run as root and without a seccomp profile: images that need that (a sandbox that makes user namespaces, say) still run, at the price of more of the kernel within reach of a pod on a privileged node. |
| Network | In: only from the namespace's own pods, so not from the runners or other tenants. Out: the internet through the proxy, and pods and Services in the cluster subject to their namespace's own policies; not the host, the node's own ports (the API server, also through its Service, and the kubelet) or anything else on the stack network; a NodePort leads to its pods as their own address does, so their namespace's ingress policy decides ([`base/networkpolicy.yaml`](manifests/tenants/base/networkpolicy.yaml)). A tenant cannot change these policies. The node's own image pulls are outside them, which is why images must come from the internet. |
| Resources | A `ResourceQuota` and a `LimitRange` per namespace (`<tenant>/quota.yaml`): CPU and memory requests and limits, claims and their storage, a count of every kind of object a tenant may create, no NodePorts or load balancers, and a default memory limit for every container that names none. |
| Reaching the API | Through the forwarder in [`api-forward.yml`](api-forward.yml): port 6443 of the node, and nothing else, on a Docker network of your choice. |

**Sizing.** A tenant's requests compete with the runners for the node's allocatable; its limits
compete for the k3s container's memory. The rule: the tenants' `requests.memory` plus the
runners' requests at their peak plus the system pods stay within allocatable, so the tenants never
keep a runner `Pending` for long; the tenants' `limits.memory` are what they may use when memory is
free, and when it is not, the kernel's OOM killer inside the container picks pods with small
requests first, which are theirs. The shipped quotas are the repository owner's host's (allocatable
14 GiB, runners peaking at about 8 GiB of requests): `zuul-trial` 1.5 CPU and 2 GiB of requests, 16
CPUs and 7 GiB of limits; `build-farm` 2 CPUs and 3 GiB, 12 CPUs and 8 GiB. CPU limits only
throttle a pod, and the k3s container's CPU cap and weight keep the host's share, so they are
generous. Each quota also bounds the number of objects of every kind a tenant may create, since
each one is a row in k3s's datastore, which the runners need too. Recompute them for yours.

**Disk is not bounded per tenant.** Quotas count claims and their requested sizes. local-path
(k3s's default StorageClass) does not enforce a claim's size, and on a host that runs the kubelet
with `--kubelet-arg=local-storage-capacity-isolation=false` (the way out when the kubelet cannot
measure its filesystem, as on some ZFS hosts) neither are `emptyDir` sizes nor a container's
writable layer. A tenant can fill the filesystems under the node's
`/var/lib/kubelet` (every pod's `emptyDir`, the runners' workspaces among them) and
`/var/lib/rancher/k3s` (images, local-path volumes). Give those their own filesystems with quotas
if that matters.

**Applying it**, once, and after every change to `manifests/tenants/`:

```sh
docker compose exec k3s kubectl apply -k /opt/arc-on-nas/manifests/tenants
API_FORWARD_NETWORK=<network> docker compose -f api-forward.yml up -d
```

`<network>` is an existing Docker network the tenants' machines or containers are on; they reach
the API server there as `https://k3s-api:6443`. Everything on that network can then reach the
API server's port; k3s allows no anonymous request, so without a certificate every path answers
401.
Removing it again: `docker compose -p ci-api down` and
`docker compose exec k3s kubectl delete -k /opt/arc-on-nas/manifests/tenants`, which deletes the
namespaces and everything in them.

Applied to a namespace whose pods already run, the admission policies leave those pods as they
are until they are recreated; restart its workloads to bring them under the rules
(`docker compose exec k3s kubectl -n <namespace> rollout restart deploy,sts,ds`), and recreate its
other pods (bare pods, Jobs).

**Issuing a user's certificate.** No secret moves: the user makes the key and keeps it, and
sends only a certificate request for their user name:

```sh
# On the user's machine. The key stays there, in a secret store.
openssl ecparam -name prime256v1 -genkey -noout -out tenant.key
openssl req -new -key tenant.key -subj "/CN=<user>/O=devinfra" -out tenant.csr
```

On the host, [`scripts/tenant-cert.sh`](scripts/tenant-cert.sh) checks the request's subject,
submits it to k3s's `kubernetes.io/kube-apiserver-client` signer for 90 days, approves it, and
writes `<user>.crt` and a `<user>.kubeconfig` that holds no key:

```sh
scripts/tenant-cert.sh <user> tenant.csr --namespace zuul-trial
```

Never approve such a request by hand without reading its subject: the signer signs whatever
subject it is given, and a request for `O=system:masters` would come back as a cluster-admin
certificate. The script refuses anything but `CN=<user>` and `O=devinfra` (`--org` for another).
Send both files back; neither is secret. The kubeconfig's user runs a credential plugin,
`tenant-credential` next to it, that prints the certificate and the key for kubectl, so that the
key never needs to be a file. For example, with the two in a secret store that has a command
line (`jq` builds the JSON):

```sh
#!/bin/sh
# ~/.kube/tenant-credential
set -eu
jq -n --arg cert "$(secret-store get k3s-cert)" --arg key "$(secret-store get k3s-key)" \
  '{apiVersion: "client.authentication.k8s.io/v1", kind: "ExecCredential",
    status: {clientCertificateData: ($cert + "\n"), clientKeyData: ($key + "\n")}}'
```

**Renewing** is the same with a new request, before the 90 days end
(`openssl x509 -in <user>.crt -noout -enddate`). **Revoking:** k3s cannot revoke a client
certificate, so remove the user from `base/rolebinding.yaml` and apply (or, at once,
`kubectl -n <namespace> delete rolebinding tenant`); the certificate then still authenticates
but is allowed nothing.

**What stays with the admin**, done by hand on the host, because each is cluster-scoped or
outside the cluster: PersistentVolumes (a hostPath volume for a tenant's cache, say), CRDs and
cluster roles a tenant's software asks for, the host's directories and their quotas, PriorityClasses,
and this directory. Give a PersistentVolume made for a tenant a `claimRef` naming that
namespace and claim: an unclaimed volume binds to any claim that fits, in any namespace.

## Building the images

[`.github/workflows/images.yml`](.github/workflows/images.yml) builds `images/swift`,
`images/ubuntu` and `images/browser` on GitHub-hosted runners. Pull requests build and run the images without
publishing, as do dispatches on feature branches. Pushing a tag `v*` or dispatching on `main`
(`gh workflow run Images --ref main`) publishes to `ghcr.io/<owner>/arc-runner-swift`,
`ghcr.io/<owner>/arc-runner-ubuntu` and `ghcr.io/<owner>/arc-runner-browser`, after the runtime checks pass, and prints
`image:tag@sha256:digest` in the job summary. Merging alone does not publish. Pin that full reference in the values file: tags are overwritten by later builds,
digests are not. The committed `helm/` references remain the previous published build until an
operator updates them deliberately. Deploy a build from the reviewed merged commit (or a
`v*` tag on it), with `CI_ARC_COMMIT` matching the image's revision. Branch-dispatch images
recorded in PR #3 are historical test artifacts, not rollout pins.

The new version tags are `6.4.0-2.338.0-ubuntu26.04-node24.22.0` (Swift) and
`2.338.0-node24.22.0` (Ubuntu); each also gets a commit-suffixed tag. The Swift image runs on
Ubuntu 26.04, with the runner, container hooks, Docker CLI and buildx copied from GitHub's
pinned runner image. The Ubuntu image stays on 24.04. Both carry Node 24.22.0 at `/opt/node`,
first on the job user's PATH. The Swift image is shared by ThunderBox's `swift` and
`swift-image` sets and also bundles Caddy 2.11.7, buildctl 0.34.0, kubectl 1.36.5, Python
(at least 3.10), curl and jq, matching AIDepartment's `ci/tools.pin`.

The browser image (`2.338.0-node24.22.0`, like Ubuntu's) is the Ubuntu image, step for step, plus
the shared libraries and fonts headless [Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/)
needs: the packages in its `deb.deps`, under Ubuntu 24.04's names, without GTK, Vulkan's loader,
libcurl and xdg-utils, which headless Chrome does not load. It does not contain Chrome: a job
installs the version it pins (into the warm cache, for example), and starts it with
`--no-sandbox --disable-dev-shm-usage`, since a runner pod has no user namespaces for Chrome's
sandbox and a small `/dev/shm`, and with `--use-angle=swiftshader --enable-unsafe-swiftshader` for
WebGL without a GPU. `scripts/check-consistency.sh` keeps its base, Node and packages a superset of
the Ubuntu image's; bump both Dockerfiles together.

Swift's 26.04 tarball is SHA-256-pinned and signature-checked during every build against the
vendored public Swift 6.x release key (`images/swift/swift-release-key.asc`, fingerprint
`52BB7E3DE28A71BE22EC05FFEF80A866B47A981F`). To bump Swift, verify its tarball and signature,
update the version and SHA-256, and refresh the public key from swift.org if needed. The 30-day
runner update rule applies to the Swift Dockerfile's source stage as well as Ubuntu's base.

`scripts/check-image.sh swift|ubuntu|browser IMAGE:TAG` checks the final image as uid 1001 without
capabilities or privilege escalation: distribution, runner startup, hooks, internal Node,
Docker CLI/buildx and bundled tools. The runner must initialize the en-US culture and reach
GitHub over TLS with an intentionally invalid token, producing an authentication rejection.
That check depends on GitHub's API and the runner's diagnostic text; after an API or runner
change, inspect the captured response and matcher before diagnosing an image dependency failure.
The Swift check builds, links, runs and tests a tiny Foundation package in `/tmp` as uid 1001.
The browser check downloads the Chrome for Testing build pinned in `images/browser/Dockerfile`
(by version and SHA-256), requires `ldd` to resolve all its libraries, and starts it headless with
the flags above, as uid 1001: WebGL must read back the pixel it cleared and Canvas 2D must draw text.
`images.yml` records the new image's versions in its job summary. The one-time before/after
Swift comparison is kept in PR #3, without pulling the old image on every build. Run these
builds in CI rather than on a busy NAS.

**Post-merge pin follow-up ([#4](https://github.com/kristofk/arc-on-nas/issues/4)).**
After the first successful Images run on the reviewed merged commit or its `v*` tag, record the immutable digests, revision and run URL in a
follow-up PR. Update `helm/swift.yaml` and `helm/ubuntu.yaml` together, then make the Ubuntu/Node
tag suffixes mandatory in `scripts/check-consistency.sh` (remove the temporary optional
suffixes). Run `mise exec -- scripts/lint.sh`. Until that follow-up merges, the examples still
use the old published images; do not use them to claim this migration is deployed. The pin
follow-up must use the main/tag build, not the earlier PR-branch publication.

**ThunderBox rollout and rollback (operator only).** First obtain Kristóf's decisions on the
shared image and bundling versus an overlay. In a reviewed ThunderBox pin commit, record the
previous pins, then update `CI_ARC_COMMIT`, `CI_SWIFT_IMAGE`, `ci/swift-image.yaml`, the admission
policy in `ci/image-runners.yaml`, and `ci/ci-light.yaml` together from that main/tag build.
Leave ci-light's graceful bootstrap fallback intact. AID's setup-node steps are all gated on
`download == 'true'`; with the bundled Node on PATH they do not run. ThunderBox can retain the
bootstrap (optionally pointing it at `/opt/node`) with its existing fallback, or remove it in
its own reviewed change.

**Rollout prerequisite: do not run the migration commands below until
[ThunderBox#61](https://github.com/kristofk/ThunderBox/issues/61) is implemented, reviewed and
merged.** The current `ci-redeploy-drained` target does not prune the old 24.04 Swift cache.
The issue tracks that missing step and a possible drained `ci-image` + `ci-install` target
without node recreation; choosing and adding that target belongs to ThunderBox.

Once that prerequisite lands, use ThunderBox's reviewed full-values installer from the
ThunderBox checkout on its operator's machine. The commands below describe its existing
node-recreation path; use the reviewed replacement if #61 adds a target without node recreation.
These commands use that repository's configured host access, not this build box:

```sh
make ci-test
make ci-sync
make ci-redeploy-drained
```

`ci-redeploy-drained` uses `ci/install-drained.sh`: it takes the drain lock, drains swift-image
then swift, and waits for ARC to acknowledge both twice (zero listener maxima/replicas and no
ephemeral runners, runner pods or image checks; bounded by `WAIT_POLLS`, 240 polls of 30 seconds
by default). Only then does it recreate the node, apply the `ci-image` bundle including the
new admission-policy pin, install all three sets from full values, and restore swift before
swift-image and restart listeners. Do not substitute `--reuse-values` plus list-index `--set`
for those full values: Helm replaces lists whole. `ci-install-drained` alone is suitable only
when the policy and node do not change; this migration changes the policy. ci-light is installed
but is not drained by these targets; the node restart interrupts any running ci-light job, so
the operator must schedule the window with that constraint.

The [ThunderBox#61](https://github.com/kristofk/ThunderBox/issues/61) rollout follow-up must put
the one-time prune of old Ubuntu 24.04 Swift `.build` entries inside the install command, after the acknowledged drain and before restoring runners.
That cache step must be reviewed with its pins before running the target; do not launch a
parallel cache prune or delete BuildKit/unrelated caches. **Pruning cannot be undone**: rollback
rebuilds a cold cache. After rollout check tools as uid 1001 in all three sets, pod imageIDs,
AID's CI and image jobs, and the libdispatch crash tracked by AIDepartment#338.

For rollback, revert the ThunderBox rollout pin commit (and its one-time prune hook) so the old
`CI_ARC_COMMIT`, both image digests, full runner values and admission-policy pin are restored
**together**, then use the same coordinated path:

```sh
# In ThunderBox; ROLLOUT_PIN_COMMIT is its reviewed migration commit, not the arc-on-nas commit.
git revert "$ROLLOUT_PIN_COMMIT"
make ci-test
make ci-sync
make ci-redeploy-drained
```

The recorded pre-migration pins are arc-on-nas commit
`979f3b5f2d556cbca402f95694d1962d5e750937`, Swift
`6.4.0-2.338.0@sha256:fc4829770130bba7ac913c5a53f14d77add6bc36ce8649971641a481294a5187`, and Ubuntu
`2.338.0@sha256:7abaf816286ac48485493ef1f401378d4f7144dd5369ba1ee256f8c367733dc8`
under `ghcr.io/kristofk/arc-runner-{swift,ubuntu}`. Confirm the actual pre-rollout pins in the
ThunderBox commit before reverting. `helm rollback` alone cannot restore the admission policy
and can leave swift-image's old pods refused. Re-check versions and AID jobs after rollback;
the deleted cache entries remain deleted. This repository's CI cannot deploy or verify a host.

Packages pushed from a private repository are private. Either make the package public in its
settings on GitHub, or create a pull secret with a token that has `read:packages` and uncomment
`imagePullSecrets` in the values:

```sh
read -rsp 'Token with read:packages: ' t; echo
auth=$(printf '%s:%s' OWNER "$t" | base64 -w0)
printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$auth" \
  | docker compose exec -T k3s kubectl -n arc-runners create secret generic ghcr-pull \
      --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
      --dry-run=client -o yaml \
  | docker compose exec -T k3s kubectl apply -f -
unset t auth
```

The token goes through standard input only, as with `scripts/register.sh`. (Not exercised by
this repository's CI.)

Without a registry: build on the host (`docker build -t arc-runner-swift:local images/swift`),
import the image into the node's containerd
(`docker save arc-runner-swift:local | docker compose exec -T k3s ctr -n k8s.io images import -`),
and use `image: docker.io/library/arc-runner-swift:local` with `imagePullPolicy: Never`. Also not
exercised by CI.

## Operations

**Updates are by digest, deliberately.** Nothing here updates itself: images are pinned by digest,
the compose services opt out of Watchtower, the charts are pinned by version, and a runner's
self-update cannot outlive its pod. To update an image, find the new tag's digest
(`docker buildx imagetools inspect <image>:<tag>`), change tag and digest together, and run
`scripts/check-consistency.sh`.

| Component | Where | Source | When |
|---|---|---|---|
| k3s | `docker-compose.yml`, `scripts/trial.sh` | [k3s releases](https://github.com/k3s-io/k3s/releases) | monthly patch releases; one minor version at a time |
| ARC charts | `--version` in `helm/` and the commands | [ARC releases](https://github.com/actions/actions-runner-controller/releases) | on release; see the CRD procedure below |
| Runner base image | `images/*/Dockerfile` | [actions/runner releases](https://github.com/actions/runner/releases) | **within 30 days** of each release |
| Swift | `images/swift/Dockerfile` | [swift.org](https://www.swift.org/install/linux/) | with your projects |
| Squid, Helm client | `docker-compose.yml` | Docker Hub | as needed |

Apply a compose change with `docker compose up -d`; recreating the node restarts every pod, and a
job running at that moment fails. Drain first if that matters: set both limits to 0 on each scale set and wait
for its runner pods to finish:

```sh
docker compose run --rm helm upgrade swift \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set --version 0.15.0 \
  --namespace arc-runners --reuse-values --set minRunners=0 --set maxRunners=0
```

Upgrade it again with `-f helm/swift.yaml --set githubConfigUrl=...` to restore it.

**The 30-day rule.** GitHub: "If you do not perform a software update within 30 days, the GitHub
Actions service will not queue jobs to your runner"
([self-hosted runners reference](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)).
Ephemeral pods cannot keep a self-update, so the runner version is the image's: rebuild the images
on the new `actions/runner` release and update the digests in `helm/` within 30 days. Whether
GitHub sends update requests to scale-set runners at all is not documented; the rule above holds
either way.

**Cache pruning.** The cache only grows. [`scripts/prune-cache.sh`](scripts/prune-cache.sh) lists
(or with `--apply` deletes) entries two levels down, such as `swiftpm-build/<package>`, in which
nothing changed for 30 days. It refuses a directory not owned by uid 1001, so a mistyped path
(a pool's root, say) is not pruned. Schedule it weekly with the host's task scheduler, as root:
`scripts/prune-cache.sh --days 30 --apply /path/to/ci-cache/default`. Emptying the cache entirely
is safe at any time no job runs; the next builds are cold. [`scripts/warm.sh`](scripts/warm.sh)
starts a consumer's workflow by hand to warm it again (the example workflow also runs weekly).

**Backups.** Back up `.env` and your edits to `helm/`. Nothing else needs it: the cluster can be
recreated from this repository (`docker compose down -v`, then the Quick start from step 5), the
credential re-created from GitHub, and the cache rebuilt by the next runs. Exclude `CACHE_DIR` and
Docker's volumes from snapshots. The kubeconfig is regenerated by k3s; a copy of it is a
cluster-admin credential.

**When a chart release changes the CRDs.** Helm does not upgrade or delete CRDs, and ARC's
documented procedure for a controller upgrade is to remove everything and install again
([deploy runner scale sets](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)).
Read the release notes; if the CRDs changed (or when in doubt):

```sh
docker compose run --rm helm uninstall swift --namespace arc-runners --wait     # every scale set
docker compose run --rm helm uninstall ubuntu --namespace arc-runners --wait
docker compose exec k3s kubectl get autoscalingrunnersets,ephemeralrunners -A   # wait until empty
docker compose run --rm helm uninstall arc --namespace arc-systems --wait
docker compose exec k3s kubectl delete crd autoscalinglisteners.actions.github.com \
  autoscalingrunnersets.actions.github.com ephemeralrunners.actions.github.com \
  ephemeralrunnersets.actions.github.com
# change the version in helm/*.yaml, scripts/lint.sh and the CI workflow, then install as in steps 9 and 10
```

The credential Secret, the namespaces and the cache survive this. Jobs queued meanwhile wait, or
run on GitHub-hosted runners if your workflow routes as the example does.

**Removing everything.** Uninstall the scale sets first (as above), so GitHub forgets them, then
`docker compose down -v`, and delete `CACHE_DIR` and `kubeconfig/` if you want them gone.

## Troubleshooting

Start with `docker compose exec k3s kubectl get pods -A`, `docker compose logs k3s`, and the
proxy's log (`docker compose exec -u proxy proxy tail -n 100 /var/log/squid/access.log`).

| Symptom | Likely cause and fix |
|---|---|
| `docker compose up`: "Pool overlaps with other one on this address space" | Another network uses `172.31.250.0/24`. Change the subnet and the fixed addresses in the files listed at the top of `docker-compose.yml`; `scripts/check-consistency.sh` checks the copies it knows about. |
| The node stays `NotReady`; k3s logs "failed to get rootfs info" or overlayfs/snapshotter errors | The storage under Docker's volumes (often ZFS or btrfs). Try `K3S_SNAPSHOTTER=native` in `.env` and `docker compose up -d`; test first with `scripts/trial.sh --snapshotter native`. |
| System pods stuck in `ContainerCreating` / `ErrImagePull` | Image pulls fail through the proxy. Check the proxy log for `TCP_DENIED`, the host's DNS, and that the proxy is running. |
| k3s logs "too many open files" or inotify errors | Raise `fs.inotify.max_user_watches` and `max_user_instances` on the host ([Requirements](#requirements)). |
| Runner pods `Pending` with "Insufficient cpu" or "memory" | Working as designed when the set is at capacity; otherwise `maxRunners` × pod size exceeds allocatable. Redo [Sizing](#sizing). |
| A runner pod is refused: "violates PodSecurity restricted" | The values file loosened the pod template (root, capabilities, privilege escalation, hostPath). Undo that change. |
| The listener restarts; logs mention 401, 403 or 404 | The credential lacks the permission in [Adding a repository](#adding-a-repository), has expired, or `githubConfigUrl` is wrong. `scripts/register.sh`, then delete the listener pod. |
| The listener cannot connect | The proxy URL in the values, or the proxy refusing GitHub (the log shows why). |
| Runner pods `ImagePullBackOff` | A private package without a pull secret, or a wrong digest ([Building the images](#building-the-images)). |
| A job cannot download something | Its host is on a private address, or it uses a port other than 80/443, or the tool ignores `https_proxy`. The proxy log shows the attempt. |
| Jobs fail with exit code 137, or k3s restarts | The OOM killer. A pod's limit is too small for the job, or the sum in [Sizing](#sizing) exceeds `K3S_MEMORY`. |
| Builds are slow or thrash | The tools inside the pod use every host core; pass the pod's CPU count (`RUNNER_CPUS`). |
| Jobs stop being picked up after a month | The runner image is older than 30 days behind the latest `actions/runner` release. |

## FAQ

**Does it run on TrueNAS SCALE, Synology DSM, Unraid, or on ZFS?** Not known: nothing here has
run on a NAS or on ZFS yet ([Status](#status)). What the stack needs is in
[Requirements](#requirements): rootful Docker that can run privileged containers, cgroup v2, and
overlayfs on Docker's data root. `scripts/preflight.sh` checks those, and `scripts/trial.sh` starts
a real node and removes it; together they are the test of a host. On ZFS, overlayfs needs
OpenZFS 2.2 or later; if the node does not come up, retry the trial with
`--snapshotter native`. Whether the kubelet's disk accounting works on ZFS is also unknown:
`trial.sh` lists any `failed to get rootfs info` lines. Reports from real hosts are the most useful
contribution ([CONTRIBUTING.md](CONTRIBUTING.md)).

**Can I keep `kernel.panic_on_oops=0` on my host?** No. The kubelet sets it to 1 and
`kernel.panic` to 10 at every start, and with `--protect-kernel-defaults` it refuses to start
instead. Running this stack means a kernel oops reboots the host after 10 seconds
([Security posture](#security-posture), which also gives the commands to restore your values after
`docker compose down`).

**Why a privileged Kubernetes node, rather than the runner image as plain ephemeral Docker
containers?** Kubernetes is the only place GitHub's own autoscaler (ARC) runs, and it is what buys
the rest: a fresh pod per job with a single-use registration, admission against fixed CPU and
memory budgets (a job waits instead of starving the host), a shared cache volume, Pod Security
`restricted` refusing a loosened runner template, and a NetworkPolicy that keeps jobs off the LAN.
Plain containers would need your own scaler, registration and cleanup, but no privileged node. The
cost is the privileged node: see [Security posture](#security-posture).

**My package mirror is on the LAN, or on port 8080. How do I allow it?** There is no setting for
it. Jobs reach only the proxy, and the proxy refuses private addresses and ports other than 80 and
443. To allow one host, add rules to `squid.conf` above the first `http_access` line, for example
for a mirror at `MIRROR_IP` on port 8080:

```
acl lan_mirror dst MIRROR_IP/32
acl lan_mirror_port port 8080
http_access allow runners lan_mirror lan_mirror_port
```

then `docker compose up -d --force-recreate proxy`. For a mirror on port 80 or 443, leave out the
port line and its name in the rule. Every job can then reach that host and port, so you are
opening that part of the LAN to every job. Not tested in CI.

**Why a denylist of private ranges, not an allowlist of GitHub's hosts?** Jobs download from
package registries (SwiftPM, npm, PyPI, crates.io, container registries) that no fixed list
covers, so an allowlist breaks builds. What the proxy protects is the host and the LAN; what jobs
contact on the internet is in its access log (the most recent 10 to 20 MB of it: `squid.conf`).
If your jobs need only a few hosts, add a
`dstdomain` allowlist to `squid.conf`.

**Does it run on arm64?** Not as written: the Swift image downloads the x86_64 toolchain, and
`images.yml` builds `linux/amd64` only. k3s and the runner base image exist for arm64, so the
images could be extended for it by selecting matching architecture-specific tool downloads
and checksums and adding `linux/arm64` to `platforms` in `images.yml`. Untested.

**How do I keep the runner image within 30 days of each `actions/runner` release without doing it
by hand?** Nothing here does it. Watch the [actions/runner releases](https://github.com/actions/runner/releases)
(GitHub's Watch → Custom → Releases), or configure Dependabot's `docker` ecosystem on
`images/swift`, `images/ubuntu` and `images/browser` in your copy to propose the new base digest; then rebuild with
`images.yml` and pin the new digests in `helm/`. See [Operations](#operations).

**Do `actions/cache`, artifacts and the `actions/setup-*` actions work?** Untested. The runner
pods have the proxy in their environment (`https_proxy`), and GitHub's cache and artifact
services are public HTTPS hosts, so they should pass the proxy. Actions that install system
packages with `sudo` or `apt-get` fail: the images have no `sudo` and the pods run as uid 1001.
Put the toolchain in the image instead ([Adding a toolchain](#adding-a-toolchain)).

**Can two repositories share one cache claim?** They can technically (the same `claimName`), but do
not: every job can write what later jobs read, so one repository's job could plant files that the
other's build uses. Give each repository its own claim
([Adding a repository](#adding-a-repository)). Repositories in one organisation that share a scale
set share its claim; give those that do not trust each other separate scale sets.

**What happens to a running job on `docker compose up -d` after a configuration change?** If the
change recreates the node, every pod restarts and the running job fails. Drain first: set
`minRunners` and `maxRunners` to 0 on each scale set and wait for its runner pods to finish
([Operations](#operations) has the command), apply the change, then restore the scale sets.

## Limitations

- **The k3s container is privileged** (see [Security posture](#security-posture)).
- **No awareness of host load.** The scheduler compares requests with allocatable; it does not
  see the host's real CPU use. Fixed budgets, `cpu_shares` under contention and `maxRunners` are
  the controls. ARC has no schedule for `minRunners`/`maxRunners`; a cron job running
  `helm upgrade --reuse-values --set maxRunners=...` can implement quiet hours.
- **One node.** No high availability; a host reboot interrupts running jobs.
- **No Docker in jobs.** No `container:` jobs, service containers or `docker build`: ARC's `dind`
  mode adds a privileged sidecar that, on a privileged node, is root on the host. Not supported
  here.
- **Personal accounts:** one scale set per repository, a personal access token with an expiry,
  no runner groups.
- **ARC is version 0.x;** chart upgrades may require the uninstall and reinstall procedure, and
  GitHub supports only the latest release
  ([support for ARC](https://docs.github.com/en/actions/concepts/runners/support-for-arc), which
  also excludes Kubernetes setup, template customisation and storage from GitHub's support).
- **The kubelet sets host kernel settings,** `kernel.panic_on_oops=1` and `kernel.panic=10` among
  them, whatever you configure; they outlive `docker compose down` until a reboot or a manual reset
  ([Security posture](#security-posture)).
- **The node container can reach the host's ports** through the stack network's gateway; only a
  host firewall rule closes that.
- **x86_64 only** for the Swift image as written.

## Repository layout

| Path | What |
|---|---|
| `docker-compose.yml`, `.env.example`, `squid.conf` | The stack: the node, the proxy, the Helm client. |
| `manifests/` | Namespaces with Pod Security labels, NetworkPolicies, the cache volume and claim; `manifests/tenants/`, the tenant namespaces. |
| `api-forward.yml` | The optional forwarder to the API server for tenant users. |
| `helm/` | Values for the controller and the `swift`, `ubuntu` and `browser` scale sets. |
| `images/` | The runner images. |
| `scripts/` | `preflight.sh`, `trial.sh`, `register.sh`, `tenant-cert.sh`, `warm.sh`, `prune-cache.sh`; `lint.sh` and `check-consistency.sh` for development. |
| `examples/workflow.yml` | A consumer repository's workflow. |
| `.github/workflows/` | This repository's CI (lint and the smoke test) and the image builds. |

Contributing: [CONTRIBUTING.md](CONTRIBUTING.md). Changes: [CHANGELOG.md](CHANGELOG.md).
Licence: [MIT](LICENSE).
