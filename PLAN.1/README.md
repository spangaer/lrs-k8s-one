# Plan for ticket 1: k8s test environment

## Goal

Bring up a single-node Kubernetes cluster that can be driven from inside the devcontainer, and run
a hello-world container in it, including an image built and pushed locally.

This is the base for later tickets. The end goal is to learn about operators by managing a small
stack: 2 naive Spring Boot services that log straight to Kafka, with OpenSearch as a sink.

## Constraints

The devcontainer runs under rootless podman. These were probed, not assumed:

- no `/dev/kvm`, `/dev/net/tun` or `/dev/fuse`
- no effective capabilities, also not via `sudo`
- nested user namespaces work, and so do mount and pid namespaces inside them, but net namespaces
  don't

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
| Image builds | podman in the devcontainer | `--isolation chroot` assumed, see spike S2 |
| Image transport | `docker-registry` process in devcontainer | native speed, survives VM resets |
| Packages | Debian packages, `--no-install-recommends` | systemd is pinned out in the Dockerfile |
| Downloads | pinned versions, cached in `.local/cache/` | spares public mirrors, fast resets |

The systemd pin is already in the [Dockerfile](../.devcontainer/Dockerfile).

## Design

```
devcontainer                                   QEMU VM (TCG), Debian 13
┌───────────────────────────────┐              ┌───────────────────────────┐
│ podman build/push             │              │ k3s / containerd          │
│   → registry 127.0.0.1:5000 ◄─┼── slirp ─────┼── pull 10.0.2.2:5000      │
│ kubectl → 127.0.0.1:6443 ─────┼── hostfwd ──►│   apiserver :6443         │
│ ssh     → 127.0.0.1:2222 ─────┼── hostfwd ──►│   sshd :22                │
│ curl    → 127.0.0.1:8080 ─────┼── hostfwd ──►│   traefik :80             │
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
- **Podman.** `~/.config/containers/registries.conf` marks `localhost:5000` as `insecure`.
- **State.** Everything mutable lives under `.local/`, which is gitignored and sits in the
  workspace bind mount, so it survives a devcontainer rebuild:
  - `.local/cache/`: downloads, fetched once and checksum-verified: the Debian cloud image, and
    the k3s binary, `install.sh` and airgap images tarball. File names carry the pinned version
    (`just` variables), so a version bump fetches anew and old files can simply be deleted.
  - `.local/vm/`: qcow2 overlay (backed by the cached image), `seed.iso`, ssh key, pid file,
    serial log
  - `.local/registry/`: registry storage
  - `.local/kubeconfig`
- **VM sizing.** Defaults are 6 vCPU, 8 GB RAM and a 30 GB disk, overridable as `just` variables.
  TCG runs with `-accel tcg,thread=multi -cpu max`.

### Proposed source layout

```
justfile                       recipes, see below
env/vm/user-data.yaml          cloud-init template: ssh key, k3s install, registries.yaml
env/registry/config.yml        registry config
test/hello/Containerfile       tiny http hello-world image
test/hello/hello.yaml          Deployment + Service + Ingress
```

### Recipes (`just`)

| Recipe | Does |
|---|---|
| `setup` | idempotent devcontainer setup (containers config), run by `postCreateCommand` |
| `registry-up` / `registry-down` | start or stop the registry process |
| `vm-image` | fill the cache if needed, create the qcow2 overlay and seed |
| `vm-up` / `vm-down` | boot the VM (daemonized) and wait for k3s / shut down cleanly |
| `vm-ssh` | ssh into the guest, or run a command: `just vm-ssh <cmd> ...` |
| `vm-reset` | drop the overlay to get a fresh cluster (the cache stays) |
| `kubeconfig` | copy `k3s.yaml` out of the guest into `.local/kubeconfig` |
| `up` / `down` | registry and VM together |
| `hello` | build, push, deploy, then curl the hello-world image |

## Steps

We'll do this one step at a time: first the spikes, then the implementation. Spikes already
follow the planned layout (e.g. paths under `.local/`), so their results carry over. When a
step is done, tick its box, write a commit message and stop for review.

Avoid rebuild loops: every devcontainer change must also be applicable to the running container.
Run Dockerfile package installs by hand with the same `apt-get install` line, and put setup
logic in idempotent `just` recipes (or scripts they call), which `postCreateCommand` merely
invokes. A final rebuild then verifies it all, see [Done when](#done-when).

### Spikes first (de-risk)

- [ ] **S1, boot under TCG.** Boot the Debian `genericcloud` image with a minimal cloud-init seed
      and install k3s by hand. Measure boot time, k3s-ready time and idle CPU (with traefik and
      metrics-server running), and tune the vCPU/RAM defaults from that.
- [ ] **S2, podman builds.** Install podman and buildah. Get `podman build` and `podman push`
      working. Find the isolation mode (`chroot` expected) and storage driver (overlay with
      `userxattr` or `vfs`), and which helper packages (`uidmap`, `passt`, `fuse-overlayfs`, ...)
      are really needed. Record the result in the containers config.
- [ ] **S3, pull path.** From inside the S1 guest, `curl http://10.0.2.2:5000/v2/` reaches the
      registry in the devcontainer.

### Implementation

1. [ ] Dockerfile: add a separate tooling line with `--no-install-recommends`: `qemu-system-x86`,
       `qemu-utils`, `cloud-image-utils`, `podman`, `buildah`, `docker-registry`,
       `kubernetes-client`, plus any helpers found in S2. Run the same line in the running
       container.
2. [ ] Containers config (registries.conf, and containers.conf/storage.conf as S2 dictates),
       written by an idempotent `setup` recipe; `postCreateCommand` runs `just setup`.
3. [ ] `.gitignore`: add `.local/`.
4. [ ] Registry config plus `registry-up` / `registry-down`.
5. [ ] cloud-init `user-data`: user + generated ssh key, k3s install with
       `--write-kubeconfig-mode 644` (traefik and metrics-server kept), and
       `/etc/rancher/k3s/registries.yaml` with the mirror.
       The ssh key is generated once into `.local/vm/` if missing; `vm-image` renders the
       template (`${SSH_PUBKEY}`) into `.local/vm/` and builds `seed.iso` from it.
       k3s is installed airgapped: `seed.iso` (built with `genisoimage`, a `cloud-image-utils`
       dependency) also carries the cached k3s files; `runcmd` mounts it, places the binary and
       images tarball, and runs `install.sh` with `INSTALL_K3S_SKIP_DOWNLOAD=true`.
6. [ ] VM recipes: `vm-image`, `vm-up` (readiness wait with generous TCG timeouts), `vm-down`,
       `vm-ssh`, `vm-reset`, `kubeconfig`.
       `vm-ssh *args` uses the recipe-local `[positional-arguments]` attribute and passes
       `"$@"` to ssh, so arguments keep their quoting; other recipes reuse it for remote
       commands. Host keys go to `.local/vm/known_hosts` (`StrictHostKeyChecking=accept-new`);
       `vm-reset` deletes that file, as the fresh guest gets new host keys.
7. [ ] `KUBECONFIG` set via the `justfile` and `remoteEnv` in devcontainer.json, so a plain
       `kubectl` works in any terminal.
8. [ ] Smoke test with a public image (`traefik/whoami`) to verify the cluster without the
       registry.
9. [ ] `hello`: build a tiny image, push it to `localhost:5000`, deploy it, then reach it
       through the ingress with `curl http://hello.localhost:8080/`.
10. [ ] Docs: fill in [project.md](../.agents/project.md) with the layout and recipes. In the root
        README, add the end goal (see [Goal](#goal)) and a short usage section.

## Done when

- [ ] After a devcontainer rebuild, `just up` gives a `Ready` node in `kubectl get nodes`
- [ ] the public image and the locally built `hello` image both serve requests
- [ ] `just down` followed by `just up` keeps the cluster state, and `just vm-reset` gives a
      fresh cluster without downloading the image or k3s again
- [ ] no systemd is installed in the devcontainer (`dpkg -l systemd` finds nothing)

## Risks and open points

- **TCG speed.** Boot and k3s startup may take minutes. Readiness waits must be generous, and
  later JVM workloads will be slow.
- **External downloads.** The cloud image and k3s artifacts come from `cloud.debian.org` and the
  k3s GitHub releases. They're cached in `.local/cache/`, so only the first run or a version bump
  hits the network. Public images pulled inside the guest (e.g. `traefik/whoami`) aren't cached
  and are fetched again after a `vm-reset`.
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
