# Plan for ticket 1: k8s test environment

## Goal

Bring up a single-node Kubernetes cluster that can be driven from inside the devcontainer, and run
a hello-world container in it, including an image built and pushed locally.

This is the base for later tickets. The end goal is to learn about operators by managing a small
stack: 2 naive Spring Boot services that log straight to Kafka, with OpenSearch as a sink.

## Constraints

The devcontainer runs under rootless podman. These were probed, not assumed:

- no `/dev/kvm`, `/dev/net/tun` or `/dev/fuse`
- no effective capabilities for `vscode`; `sudo` root has a reduced set, without `sys_admin`,
  `net_admin` or `mknod`
- nested user namespaces work, and so do mount, pid and net namespaces inside them
- a fresh `/proc` mount is denied, as Podman masks parts of `/proc`, but recursive bind mounts
  of `/proc`, `/sys` and `/dev` work
- the container only has IDs 0..65536, so subordinate ID ranges must fit inside that

Giving the devcontainer privileges or devices is **off limits**, so KVM, docker-in-docker and
kind/k3d are out.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Cluster runtime | QEMU, TCG software emulation | the only option that works without privileges |
| Guest OS | Debian 13 cloud image + cloud-init | matches the devcontainer, familiar |
| Kubernetes | k3s, single node | light, and includes `local-path` PVC support |
| Networking | QEMU user mode (slirp) + `hostfwd` | needs no tun device or capabilities |
| Ingress | k3s's bundled traefik | later tickets need one, keeps the cluster realistic |
| Image builds | `podman build` in the devcontainer | native speed, no new rights, Docker's CLI |
| Fallback builds | Docker in a separate build VM, on demand | real root, if Podman falls short |
| Local runs | `podman run`, host network, bind-mounted `/proc` | build tools, quick image checks |
| Image transport | `docker-registry` process in devcontainer | native speed, survives VM resets |
| Packages | Debian packages, `--no-install-recommends` | systemd is pinned out in the Dockerfile |
| Downloads | pinned versions, cached in `.local/cache/` | spares public mirrors, fast resets |

The systemd pin is already in the [Dockerfile](../.devcontainer/Dockerfile).

k3s and kubectl are pinned to the same Kubernetes minor version. kubectl is always the
upstream binary, cached and checksum-verified; Debian's package lags behind k3s.

Resolved: k3s `v1.36.5+k3s1` (the `stable` channel) and kubectl `v1.36.5`. All pins live in
[versions.just](../versions.just).

## Design

```
devcontainer                                   cluster VM (TCG), Debian 13
┌───────────────────────────────┐              ┌───────────────────────────┐
│ podman build/push             │              │ k3s / containerd          │
│   → registry 127.0.0.1:5000 ◄─┼── slirp ─────┼── pull 10.0.2.2:5000      │
│ kubectl → 127.0.0.1:6443 ─────┼── hostfwd ──►│   apiserver :6443         │
│ ssh     → 127.0.0.1:2222 ─────┼── hostfwd ──►│   sshd :22                │
│ curl    → 127.0.0.1:8080 ─────┼── hostfwd ──►│   traefik :80             │
│                               │              └───────────────────────────┘
│                               │              build VM (TCG), on demand
│                               │              ┌───────────────────────────┐
│ docker  → 127.0.0.1:2375 ─────┼── hostfwd ──►│   dockerd :2375           │
│ ssh     → 127.0.0.1:2223 ─────┼── hostfwd ──►│   sshd :22                │
│   registry 127.0.0.1:5000 ◄───┼── slirp ─────┼── push 10.0.2.2:5000      │
└───────────────────────────────┘              └───────────────────────────┘
```

- **Image names.** Manifests use `image: localhost:5000/<name>`. A k3s `registries.yaml` mirror
  maps `localhost:5000` to `http://10.0.2.2:5000`, which slirp routes to the devcontainer's
  loopback.
- **Registry.** Debian `docker-registry` (distribution 2.8.3), started directly with our own
  config. Its systemd unit is ignored. It listens on `127.0.0.1:5000` only, over plain HTTP.
- **Ingress.** k3s's bundled traefik and metrics-server stay enabled, as later tickets need an
  ingress anyway. `hostfwd` maps `127.0.0.1:8080` to traefik's port 80, since a non-root process
  can't bind ports below 1024. Ingress hosts use `<name>.localhost`, which curl and browsers
  resolve to loopback, e.g. `curl http://hello.localhost:8080/`.
- **Builders.** Podman is the default, as it's fast. The build VM is there for builds that
  rootless Podman can't handle, or for when the devcontainer setup breaks. Both take the same
  `build` and `push` arguments, so recipes pick the command, `podman` or `docker`, from the
  `builder` variable. Either one pushes to the same registry, so the cluster can't tell them
  apart.
- **Podman.** Runs rootless, for builds and local runs. Buildah isn't needed as a separate
  tool, `podman build` uses it as a library. Details and measurements are in
  [spike-s2.md](./spike-s2.md), part 3.
  - ID mapping: `/etc/subuid` and `/etc/subgid` hold `vscode:1:999` and `vscode:1001:64536`,
    and `newuidmap` / `newgidmap` use file capabilities (`cap_setuid` / `cap_setgid`) instead
    of setuid root, which fails here for lack of `sys_admin`. Without either fix, Podman
    falls back to a single ID with only a warning, and `chown` in builds is lost.
  - `containers.conf` sets `netns = "host"` and binds `/proc:/proc:rbind`. crun can't mount a
    fresh `/proc` here, so without the bind every `RUN` step and every `podman run` fails.
    With it, both get Podman's default private PID namespace, rather than needing
    `--pid=host`.
  - builds: plain `podman build`, with the default `oci` isolation and layer caching. Each
    `RUN` step gets its own PID namespace, so daemons it starts are killed when it ends.
    `--isolation chroot` works too, but shares the devcontainer's PID namespace and leaves
    such daemons running.
  - runs: `podman stop` cleans up the whole process tree. Inside, `/proc`
    shows the devcontainer's processes and PIDs, so `ps` and `/proc/<pid>` lookups are off;
    `--pid=host` fixes that per run, but then `podman stop` hangs. Ports bind straight on the
    devcontainer's loopback, and resource limits are silently ignored.
  - `registries.conf` marks `localhost:5000` as `insecure`; `cgroup_manager` is `cgroupfs`.
  - `netavark` must be installed, even though it isn't used with the host network.
- **Build VM.** A second QEMU VM with Docker, BuildKit via `docker-buildx`, see
  [spike-s2.md](./spike-s2.md), part 2. Separate from the cluster VM, so builds don't compete
  with k3s and `vm-reset` keeps the build cache. Started on demand, not by `up`.
  - the devcontainer's `docker` CLI talks to `DOCKER_HOST=tcp://127.0.0.1:2375`, a `hostfwd`
    to the daemon. A systemd drop-in adds `-H tcp://0.0.0.0:2375` and keeps `$DOCKER_OPTS`;
    `hosts` in `daemon.json` conflicts with the unit's `-H fd://`. The API is unauthenticated,
    which is acceptable as the forward is bound to loopback.
  - pushes run inside the VM, so images are tagged `10.0.2.2:5000/<name>`; `daemon.json`
    marks that registry as insecure. It's the same registry and repository as
    `localhost:5000/<name>`, so manifests don't change.
  - cloud-init installs `docker.io`, `docker-cli` and `docker-buildx` from the Debian mirror
    on first boot, with recommends off, and adds `debian` to the `docker` group.
- **State.** Persistent runtime state lives under `.local/`, which is gitignored and sits in
  the workspace bind mount, so it survives a devcontainer rebuild. User-level containers config
  is recreated by `setup`, and temporary process state is recreated on startup:
  - `.local/cache/`: downloads, fetched once and checksum-verified: the Debian cloud image, and
    the k3s binary, `install.sh`, airgap images tarball and kubectl binary. File names
    carry the pinned version or revision from `versions.just`, so a version bump fetches anew.
    Pin `install.sh` to an immutable revision as well. Never delete a cached cloud image while
    an overlay still uses it as its backing image.
  - `.local/vm/`: the ssh key, shared by both VMs, and a dir per VM, `cluster/` and `build/`,
    each with a qcow2 overlay (backed by the cached image), `seed.iso`, `known_hosts`, pid
    file and serial log
  - `.local/registry/`: registry storage
  - `.local/podman/`: Podman image/build storage, configured by `setup`. It holds files owned
    by mapped IDs, so plain `rm` and `du` fail. Clean up with `podman rmi`,
    `podman system prune` or, to wipe it all, `podman system reset`; for raw file access, use
    `podman unshare`
  - `.local/kubeconfig`: admin credentials, written automatically with mode `0600`
- **VM sizing.** Let `n` be the number of vCPUs available to the devcontainer. The guest defaults
  to `n` vCPUs if `n < 4`, 4 if `4 <= n < 8`, and `floor(n / 2)` otherwise. RAM defaults to
  6 GB and disk to 30 GB; all sizes are overridable as `just` variables.
  The build VM defaults to 4 vCPUs (fewer if `n < 4`), 3 GB RAM and 20 GB disk.
  TCG runs with `-accel tcg,thread=multi -cpu max`.

### Proposed source layout

```
justfile                       recipes, see below
versions.just                  pinned versions and checksums, imported by the justfile
env/vm/cluster/user-data.yaml  cloud-init template: ssh key, k3s install, registries.yaml
env/vm/build/user-data.yaml    cloud-init template: ssh key, Docker install, TCP drop-in
env/registry/config.yml        registry config
test/hello/Dockerfile          tiny http hello-world image
test/hello/hello.yaml          Deployment + Service + Ingress
```

### Recipes (`just`)

The `vm-*` recipes act on the cluster VM by default, and on the build VM with `just vm=build ...`.
`hello` builds with Podman by default, and through the build VM with `just builder=docker ...`.

| Recipe | Does |
|---|---|
| `setup` | devcontainer setup: ID mapping, kubectl, containers config; run on create |
| `registry-up` / `registry-down` | start or stop the registry process |
| `vm-image` | fill the cache if needed, create the qcow2 overlay and seed |
| `vm-up` / `vm-down` | boot the VM (daemonized) and wait for k3s or Docker / shut down cleanly |
| `vm-ssh` | ssh into the guest, or run a command: `just vm-ssh <cmd> ...` |
| `vm-reset` | drop the overlay to get a fresh VM (the cache stays) |
| `kubeconfig` | copy `k3s.yaml` out of the guest into `.local/kubeconfig` |
| `up` / `down` | registry and cluster VM together; `down` also stops a running build VM |
| `hello` | build, push, deploy, then curl the hello-world image |

## Steps

We'll do this one step at a time: first the spikes, then the implementation. Spikes already
follow the planned layout (e.g. paths under `.local/`), so their results carry over. When a
step is done, tick its box, write a commit message and stop for review.

Avoid rebuild loops: every devcontainer change must also be applicable to the running container.
Run Dockerfile package installs by hand with the same `apt-get install` line, and put setup
logic in idempotent `just` recipes (or scripts they call), which `postCreateCommand` merely
invokes. Changes that need root, like `/etc/subuid` or `setcap`, are lost on rebuild when
applied by hand. `setup` makes them with `sudo -n`, as `vscode` has passwordless sudo; it
checks first with `sudo -n true` and fails with an actionable error otherwise. So one recipe
covers both the running container and rebuilds, and rerunning it repairs what a package
upgrade reset. Only package installs stay in the Dockerfile. A final rebuild then verifies it
all, see [Done when](#done-when).

Recipes must be safe to repeat and converge on the requested state. An already running process
must not be started twice, and stopping an already stopped process is a no-op. Validate process
identity before acting on PID files; stale files must never cause an unrelated process to be
stopped. Failures and bounded readiness timeouts return nonzero with an actionable error and
relevant log locations, rather than silently continuing. Long waits print a progress line about
every 20 s, with the current phase, elapsed time and, where within reach, a concrete status
rather than a generic heartbeat, so it's clear what they're doing. Wait for process exit before
removing its state. `vm-reset` deliberately replaces the cluster, but preserves caches and
registry/build storage; it clears stale host keys and kubeconfig, which the next startup
regenerates.
`vm-image` preserves existing disks and seeds. If pinned versions or bootstrap settings differ
from an existing VM, report the mismatch and require an explicit reset rather than silently
changing it.

### Spikes first (de-risk)

- [x] **S1, boot under TCG.** Boot the Debian `genericcloud` image with a minimal cloud-init seed
      and install k3s by hand. Measure boot time, k3s-ready time and idle CPU (with traefik and
      metrics-server running), and tune the vCPU/RAM defaults from that.

      Results, with 16 host vCPUs, measured with 6 guest vCPUs and 8 GB (see
      [spike-s1.md](./spike-s1.md) for the commands):
      - first boot: ssh after 59 s, cloud-init done after 67 s; root fs grew to 30 GB
      - airgapped k3s install from a 274 MB `seed.iso` (works fine, no data disk needed):
        script 88 s, node `Ready` 95 s, traefik and metrics-server running 262 s
      - warm restart: ssh 52 s, node `Ready` 92 s, traefik serving 197 s; clean shutdown 16 s
      - idle: ~1 host core for QEMU, ~560m and ~1.2 GB used in the guest, QEMU RSS ~4.3 GB
      - startup saturates the vCPUs (load ~7.7), so more vCPUs mostly speed up startup
      - clock: NTP synced, no drift seen against the devcontainer
      - `helm-install-traefik` restarts a few times while it waits for its CRDs, that's normal

      Defaults changed: RAM 8 → 6 GB, as the guest uses ~1.2 GB idle and host RAM is tight;
      vCPUs 40 → 50% of `n`, since startup is CPU bound. Readiness timeouts: 10 min for first
      boot plus install, 5 min for a warm start.
- [x] **S2, rootless builds.** Get image builds working as the normal devcontainer user: fetch
      a base image and build an image with a real `RUN` instruction, without new devices or
      privileges.

      Results, with the same 16 host vCPUs (see [spike-s2.md](./spike-s2.md)):
      - Podman's default runtime path fails: crun can't mount a fresh `/proc`. Setuid
        `newuidmap` fails too, and the default subordinate range `100000:65536` lies outside
        the container's IDs.
      - a separate build VM with Docker works (part 2): 80 s cold build, 68 s warm boot,
        ~1.2 GB RSS.
      - Buildah with chroot isolation in the devcontainer works (part 3), once the ID ranges
        and `newuidmap` file capabilities are fixed: 11 s cold build, 0-1 s rebuilds with
        `--layers`, 1 s push. Ownership (`chown 1234`, base image groups) survives into the
        pushed layers. Storage is native overlay on the ext4 workspace, no `fuse-overlayfs`.
      - `podman build` works the same way; `podman run` works with the host network and a
        bind-mounted `/proc`, see the Podman notes in [Design](#design).

      - later finding: with that `containers.conf`, `podman build` works with the default `oci`
        isolation too, 5 s cold. Each `RUN` step gets a private PID namespace, so leftover
        background processes are killed, unlike with chroot isolation.

      Decision: build and run with Podman by default, and keep the build VM as a second builder
      for when Podman falls short.
- [x] **S3, pull path.** From inside the S1 guest, `curl http://10.0.2.2:5000/v2/` reaches the
      registry in the devcontainer.

      Covered by S2, part 2: the build VM pushed to `10.0.2.2:5000`, with the same Debian
      image and slirp networking as the cluster VM. The k3s mirror config for plain-HTTP
      pulls is left to step 9, which tests it end to end; a separate spike would mean building
      the cluster VM by hand once more.

### Implementation

1. [ ] Dockerfile: add a separate tooling line with `--no-install-recommends`: `qemu-system-x86`,
       `qemu-utils`, `cloud-image-utils`, `podman`, `uidmap`, `netavark`,
       `docker-registry`, `docker-cli`, `docker-buildx`. Run the same package installation
       line in the running container.
2. [ ] Devcontainer setup, by an idempotent `setup` recipe; `postCreateCommand` runs
       `just setup`. With `sudo -n`, the ID mapping: write `/etc/subuid` and `/etc/subgid`, drop
       setuid from `newuidmap` and `newgidmap` and give them file capabilities, see
       [Design](#design); only change what differs. Also with `sudo -n`, install the pinned
       kubectl from `.local/cache/` (fetched if missing) to `/usr/local/bin/kubectl`, as
       `~/.local/bin` isn't on `PATH`. In `~/.config/containers/`:
       `storage.conf` (overlay, `graphroot` at an absolute `.local/podman/storage` path,
       `runroot` under `/tmp` as `XDG_RUNTIME_DIR` is unset), `containers.conf` (host network,
       `/proc` bind, `cgroupfs`) and `registries.conf`. Recreate temporary runtime storage
       rather than relying on it surviving rebuilds. `setup` fails with an actionable error if
       `podman unshare cat /proc/self/uid_map` shows a single line.
3. [x] `.gitignore`: add `.local/` (done early, during S1).
4. [ ] Registry config plus `registry-up` / `registry-down`.
5. [ ] Cluster VM cloud-init `user-data`: generated ssh key for the image's default `debian`
       user (no `users:` block, which would replace it), k3s install with kubeconfig mode
       `0600` (traefik and metrics-server kept), and `/etc/rancher/k3s/registries.yaml` with
       the mirror.
       The ssh key is generated once into `.local/vm/` if missing; `vm-image` renders the
       template (`${SSH_PUBKEY}`) into `.local/vm/cluster/`. Generate NoCloud `meta-data` with an
       instance ID that stays stable across boots and changes on reset. Label `seed.iso` as
       `cidata`.
       Verify the guest filesystem grows to the configured disk size.
       k3s is installed airgapped: `seed.iso` (built with `genisoimage`, a `cloud-image-utils`
       dependency) also carries the cached k3s files; `runcmd` mounts it, installs the executable
       binary at `/usr/local/bin/k3s`, places the matching images tarball under
       `/var/lib/rancher/k3s/agent/images/`, and runs the pinned `install.sh` with
       `INSTALL_K3S_SKIP_DOWNLOAD=true`.
6. [ ] VM recipes, for any VM named by `vm`, see [Recipes](#recipes-just): `vm-image`, `vm-up`
       (readiness wait with generous TCG timeouts), `vm-down`, `vm-ssh`, `vm-reset`,
       `kubeconfig`. `vm-up` checks cloud-init completion and reports
       bootstrap errors rather than treating SSH availability as successful provisioning.
       While waiting for QEMU to exit, `vm-down` shows the last serial log line. `vm-up`'s
       progress lines name the phase and show its status, e.g. `[1m40s] cloud-init: running`:

       - boot, until ssh: last line of the serial log
       - cloud-init: `cloud-init status`, plus the last line of its output log
       - node: the node's `Ready` condition and reason
       - addons: pod counts by phase in `kube-system`, and which ones aren't ready yet
       - ingress: HTTP status from traefik through the `8080` hostfwd

       Verify `vm-ssh *args` argument handling against the guest: compare received argument
       counts and values for spaces, empty strings, quotes and literal shell metacharacters.
       Choose the implementation from those results and keep the checks as regression tests.
       Other recipes reuse this helper. Host keys go to `.local/vm/<vm>/known_hosts`
       (`StrictHostKeyChecking=accept-new`); `vm-reset` deletes that file. Each VM has its own
       ssh port, sizing, user-data and readiness phases; only the cluster VM is built here.
       `kubeconfig` reads the guest file via non-interactive `sudo -n`, writes the local copy
       atomically with mode `0600`, and uses `https://127.0.0.1:6443` as the API endpoint. The
       `debian` user already gets passwordless sudo from cloud-init.
7. [ ] `KUBECONFIG` and `DOCKER_HOST`: the `justfile` exports both, so recipes work in any
       context, e.g. CI, not only the devcontainer. Use `env()` defaults, so a caller's value
       wins: `env("KUBECONFIG", justfile_directory() / ".local/kubeconfig")`. `remoteEnv` in
       devcontainer.json sets the same values, so a plain `kubectl` and `docker` work in VS
       Code terminals too.
8. [ ] Smoke test with a public image (`traefik/whoami`) to verify the cluster without the
       registry.
9. [ ] `hello`: build a tiny image with `podman build`, push it to `localhost:5000`, deploy
       it, then reach it through the ingress with `curl http://hello.localhost:8080/`. Use a
       fresh image tag for each invocation, update the Deployment image, and wait for rollout
       before checking the expected response. Verify a changed image is served on a repeated run.
10. [ ] Build VM: `env/vm/build/user-data.yaml` with the Docker install, `daemon.json` and the
        TCP drop-in, see [Design](#design), and the build VM's settings for the step 6 recipes:
        ssh on `2223`, `hostfwd` for `2375`, and `vm-up` waits until `docker version` reaches
        the daemon. `hello` with `builder=docker` brings the build VM up if needed, then builds
        with `docker build` and pushes as `10.0.2.2:5000/hello:<tag>`.
11. [ ] Agent skill to bump pinned versions in `versions.just` (cloud image, k3s artifacts,
        `install.sh` revision, kubectl). Take checksums from the upstream checksum
        files, keep k3s and kubectl on the same minor, and validate with `just vm-reset`,
        `just up`, `just hello` and `just builder=docker hello`.
12. [ ] Transfer the spike learnings, so the spike logs are no longer needed. The why goes
        next to the what: inline comments in scripts, recipes, config and cloud-init
        templates are the first choice. The overview goes to `docs/udd/testsetup/`: how the
        pieces fit together, the devcontainer constraints and how each part works around
        them, the decisions with the alternatives that were rejected, and the gotchas that
        don't belong to a single file. Drop the redundant parts, like command transcripts
        and the step-by-step probing, but keep the explanations of why, and the key
        measurements behind sizing and timeouts.
13. [ ] Docs: fill in [project.md](../.agents/project.md) with the layout and recipes, and add
        the skill to the [agent index](../.agents/README.md). In the root README, add the end
        goal (see [Goal](#goal)) and a short usage section that links to `docs/udd/testsetup/`.

## Done when

- [ ] After a devcontainer rebuild, `just up` gives a `Ready` node in `kubectl get nodes`
- [ ] the public image and the locally built `hello` image both serve requests, with `hello`
      built by either builder
- [ ] `podman run --rm` of the `hello` image works in the devcontainer, and
      `podman unshare cat /proc/self/uid_map` shows 3 lines
- [ ] the cluster VM and the build VM run side by side within the host's RAM
- [ ] `just down` followed by `just up` keeps the cluster state, and `just vm-reset` gives a
      fresh cluster without downloading the image or k3s again
- [ ] no systemd is installed in the devcontainer (`dpkg -l systemd` finds nothing)

## Risks and open points

- **TCG speed.** Boot and k3s startup may take minutes. Readiness waits must be generous, and
  later JVM workloads will be slow.
- **External downloads.** The cloud image and k3s artifacts come from `cloud.debian.org` and the
  k3s GitHub releases. They're cached in `.local/cache/`, so only the first run or a version bump
  hits the network. Public images pulled inside the guest (e.g. `traefik/whoami`) aren't cached
  and are fetched again after a `vm-reset`. The build VM installs Docker from the Debian
  mirror on first boot, so after its reset, too.
- **Seed ISO size.** The airgap images tarball makes `seed.iso` a few hundred MB. Verify in S1
  that this boots fine; a separate read-only data disk is the fallback.
- **Plain-HTTP registry.** Acceptable because it's loopback only and local dev only.
- **Clock drift.** Possible under TCG. Check during S1 (cert validity, NTP in the guest).

## Later tickets (not in scope)

- persistent data disk for `local-path` PVCs (second qcow2 disk)
- 2 naive Spring Boot services, logging straight to Kafka from the JVM (no files, no shipper)
- Kafka (KRaft, single broker) and OpenSearch (single node, small heap) on PVCs
- if JVM startup under TCG gets painful: a generous `startupProbe` and
  `-XX:TieredStopAtLevel=1`
- the operator itself, in Rust (kube-rs), running natively in the devcontainer against `:6443`
