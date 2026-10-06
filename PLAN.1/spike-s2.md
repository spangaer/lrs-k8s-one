# Spike log for S2 (ticket 1)

S2 started with Podman in the devcontainer, which stranded on kernel rights we don't want to
open up. After a devcontainer rebuild it continued with a separate build VM running Docker,
which works. Part 3 then found why Part 1 failed, and got Buildah and Podman working in the
devcontainer with chroot isolation and host namespaces, much faster. Paths are relative to
the workspace root.

## Part 1: Podman in the devcontainer (abandoned)

### Changes made to the running container

All were undone by the rebuild, none are in the Dockerfile.

- `apt-get install --no-install-recommends podman buildah`, which pulled in `buildah conmon
  containernetworking-plugins crun golang-github-containers-common
  golang-github-containers-image iptables netavark uidmap` and a few libs; still no systemd
- `strace` and `libcap2-bin`, for debugging only
- `/etc/subuid` and `/etc/subgid` rewritten to `vscode:1:999` and `vscode:1001:64536`, the
  originals saved as `*.orig`
- `newuidmap` / `newgidmap` are **unchanged**, still setuid root

Kept in the workspace: `.local/s2/ctx/Containerfile`, a test build with a real `RUN`, `useradd`
and `chown` to a non-root UID.

### Probes

```sh
id; cat /etc/subuid /etc/subgid
cat /proc/self/uid_map                 # 0 1 1000 / 1000 0 1 / 1001 1001 64536
grep -E 'Cap(Eff|Bnd)' /proc/self/status
sudo -n grep CapEff /proc/self/status  # 0x800c05fb
unshare --user --map-root-user --mount --pid --fork sh -c 'id'
unshare --user --map-root-user --net sh -c 'ip link set lo up && echo ok'
unshare --user --map-root-user --mount --pid --fork sh -c 'mount -t proc proc /proc'
```

Findings:

- the container's user namespace maps only IDs 0..65536, with host IDs not visible
- `sudo` root has a reduced bounding set: `chown dac_override fowner fsetid kill setgid setuid
  setpcap net_bind_service sys_chroot sys_ptrace setfcap`, so no `sys_admin`, `net_admin`,
  `mknod` and so on
- no seccomp filter, `NoNewPrivs` is 0
- nested user, mount and pid namespaces work, as the plan says
- **a nested net namespace works too**, including `lo` up; this contradicts the plan's
  constraint, and still holds after the rebuild
- mounting `/proc` in a nested namespace is denied, which breaks a normal container runtime
- `/` and `$HOME` are overlayfs (`userxattr`), the workspace is ext4
- cgroup v2 with `cpu memory pids` delegated; `XDG_RUNTIME_DIR` is unset

### Podman user namespace setup

```sh
podman info
# newuidmap 156042 0 1000 1 1 100000 65536: write to uid_map failed: Operation not permitted
```

1. The default subuid range `100000:65536` is outside the container's ID range, so it can't
   work. In-range ranges `1:999` and `1001:64536` still failed with the same `EPERM`.
2. Writing the same multi-range map from a non-setuid process with only `CAP_SETUID` works:

   ```sh
   unshare --user sh -c 'sleep 20' & P=$!; sleep 0.5
   sudo -n setpriv --reuid=1000 --regid=1000 --init-groups \
     --inh-caps=+setuid --ambient-caps=+setuid \
     sh -c "printf '0 1000 1\n1 1 999\n1000 1001 64536\n' > /proc/$P/uid_map && echo OK"
   ```

3. `strace` shows that setuid `newuidmap` fails on exactly that `write` to `uid_map`, while
   holding the full root capability set. Writing to `uid_map` as euid 0 seems to be denied
   here, while the real uid of the target namespace's owner works.

The untested fix: drop the setuid bit and give the binaries file capabilities instead, like
Podman's own container images do:

```sh
sudo chmod u-s /usr/bin/newuidmap /usr/bin/newgidmap
sudo setcap cap_setuid=ep /usr/bin/newuidmap
sudo setcap cap_setgid=ep /usr/bin/newgidmap
```

Even then, the `/proc` mount denial is still open, as are rootless networking (`pasta` isn't
installed) and storage (overlay with `userxattr` vs `vfs`).

### Rechecks after the rebuild

```sh
unshare --user --map-root-user --net sh -c 'ip link set lo up && echo ok'      # ok
unshare --user --map-root-user --mount --pid --fork sh -c 'mount -t proc proc /proc'  # denied
sudo -n grep CapEff /proc/self/status  # 0x800c05fb, as before
```

- nested net namespaces work, so the plan's constraint is wrong
- `sudo` still has the reduced capability set, so "no effective capabilities, also not via
  `sudo`" is wrong as well

### Outcome

Podman in this rootless podman container may need kernel rights on the host that we don't want
to open up, so part 2 builds images in QEMU, where root is real.

## Part 2: build VM with Docker

A separate build VM, rather than building in the cluster VM: builds don't compete with k3s,
`vm-reset` keeps the build cache, and each VM can be reset on its own. Building in the cluster
VM (Debian `buildah`/`podman`, or BuildKit on k3s's containerd) was rejected for those reasons,
and it would still need a way to get the build context in.

Host RAM is 31 GB total, with ~11.7 GB available with nothing running, so a 3 GB build VM
next to the 6 GB cluster VM fits.

### Packages

Trixie has `docker.io` (daemon, 26.1.5), `docker-cli` and `docker-buildx` (0.13.1) as separate
packages. `docker.io` only *recommends* `docker-cli`, and `docker-cli` only recommends
`docker-buildx`, so with `--no-install-recommends` all must be named.

Devcontainer, installed by hand, the Dockerfile line from step 1 minus Podman, plus the client:

```sh
sudo apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils \
  docker-cli docker-buildx docker-registry
dpkg -l systemd   # still finds nothing
```

The guest installs `docker.io docker-cli docker-buildx` from the network on first boot; this
pulls in `containerd` 1.7.24 and `runc` 1.1.15. Recommends are off there too.

### Image and seed

Same recipe as S1 with its own state dir, reusing the cached image and the existing ssh key:

```sh
mkdir -p .local/vm/build/seed && cd .local/vm/build
qemu-img create -q -f qcow2 -F qcow2 \
  -b "$(realpath ../../cache/debian-13-genericcloud-amd64-20261001-2618.qcow2)" disk.qcow2 20G
cat > seed/user-data <<EOT
#cloud-config
ssh_authorized_keys:
  - $(cat ../id_ed25519.pub)
apt:
  conf: |
    APT::Install-Recommends "false";
package_update: true
packages: [docker.io, docker-cli, docker-buildx]
write_files:
  - path: /etc/docker/daemon.json
    content: |
      {"insecure-registries": ["10.0.2.2:5000"]}
runcmd:
  - [usermod, -aG, docker, debian]
EOT
printf 'instance-id: spike-s2-build-1\nlocal-hostname: build\n' > seed/meta-data
genisoimage -quiet -output seed.iso -volid cidata -joliet -rock seed/
rm -r seed
```

For the TCP transport below, the daemon also needs a systemd drop-in. The spike added it by
hand; the recipe should put it in `write_files`. `hosts` in `daemon.json` doesn't work, as it
conflicts with the unit's `-H fd://`. The spike's drop-in dropped `$DOCKER_OPTS`, keep it.

```ini
# /etc/systemd/system/docker.service.d/tcp.conf
[Service]
ExecStart=
ExecStart=/usr/sbin/dockerd -H fd:// -H tcp://0.0.0.0:2375 \
  --containerd=/run/containerd/containerd.sock
```

### Boot

```sh
qemu-system-x86_64 -name lrs-k8s-build -accel tcg,thread=multi -cpu max -smp 4 -m 3G \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -drive file=seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2223-:22,hostfwd=tcp:127.0.0.1:2375-:2375 \
  -device virtio-net-pci,netdev=n0 -display none -serial file:serial.log \
  -daemonize -pidfile qemu.pid
```

### Transport: devcontainer client to the guest daemon

ssh goes through a `Host` entry, so plain `ssh lrs-build` and `DOCKER_HOST=ssh://lrs-build`
both work. It lives in `.local/vm/ssh_config`; `~/.ssh/config` only gets an
`Include /workspaces/lrs-k8s-one/.local/vm/ssh_config` line, which `setup` can add idempotently.

```
Host lrs-build
  HostName 127.0.0.1
  Port 2223
  User debian
  IdentityFile /workspaces/lrs-k8s-one/.local/vm/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile /workspaces/lrs-k8s-one/.local/vm/build/known_hosts
  StrictHostKeyChecking accept-new
  BatchMode yes
  ConnectTimeout 5
```

Each variant ran a cached rebuild, a rebuild after a context change and a push. Plain API calls
(`docker version`) take ~1 s in all of them.

| `DOCKER_HOST` | cached | context change | notes |
|---|---|---|---|
| `ssh://lrs-build` | 12-13 s | 14 s | `http2: ... error reading preface` noise on every build |
| same, with `ControlMaster auto` and `ControlPersist 10m` | 4-5 s | 5 s | same noise |
| `unix://` via `ssh -f -N -L <sock>:/var/run/docker.sock` | 3-4 s | 2 s | extra process |
| `tcp://127.0.0.1:2375` via QEMU `hostfwd` | 3-4 s | 2 s | no extra process |

Plain `ssh://` opens a new ssh connection per Docker connection, and BuildKit uses several per
build; sshd under TCG makes each handshake slow. The `http2` lines come from the CLI's
`dial-stdio` helper and are harmless, but noisy.

Preferred: **TCP via `hostfwd`**. QEMU owns the forward, so it lives and dies with the VM, and
recipes have no ssh process to track. The API is unauthenticated, i.e. root on the build VM
for any process in the devcontainer. Like the plain-HTTP registry, that's acceptable since it's
bound to loopback only and the devcontainer is a single-user dev environment. Fallback: the ssh
socket forward.

### Build, run and push

`.local/s2/ctx/Containerfile`: `debian:trixie-slim`, a `RUN` with `apt-get install curl`, and a
`RUN` with `useradd -u 1234` plus `chown` to that UID. Later a `COPY` of a local file was added
to check that context changes stream through.

```sh
export DOCKER_HOST=tcp://127.0.0.1:2375
docker build -f Containerfile -t 10.0.2.2:5000/s2:1 .
docker run --rm 10.0.2.2:5000/s2:1       # files owned by 1234:1234, curl present
docker push 10.0.2.2:5000/s2:1
curl -s http://127.0.0.1:5000/v2/s2/tags/list
```

The spike registry ran as `docker-registry serve config.yml` with filesystem storage under
`.local/s2/registry/` and `http.addr: 127.0.0.1:5000`. From the build VM, `10.0.2.2:5000`
reaches it, so the push already covers half of S3's pull path.

- builds use BuildKit (via `docker-buildx`), no fallback to the legacy builder
- the build context streams from the devcontainer, no `scp` or shared folder
- **gotcha**: Docker 26 only looks for `Dockerfile`, so a `Containerfile` needs
  `-f Containerfile`; simplest is to name the hello image's file `Dockerfile`
- the image tag uses `10.0.2.2:5000`, as the push runs from inside the build VM; `localhost`
  there would be the VM itself. The cluster's mirror config maps `localhost:5000` to the same
  registry, so manifests can still use `localhost:5000/<name>`

### Measurements

16 host vCPUs, build VM with 4 vCPUs and 3 GB:

- first boot with Docker install from the network: cloud-init done after 155 s
- warm boot: Docker API reachable after 68 s; clean shutdown 5 s
- cold build of the test image: 80 s, of which 19 s pulling `trixie-slim` and 45 s for the
  `apt-get` step; push 29 s for a fresh image, 1 s for an updated one
- the build cache survives a VM restart
- idle: ~3% of one host core, QEMU RSS ~1.2 GB, ~300 MB used in the guest
- disk: overlay 912 MB after the spike, guest root fs 1.4 GB used of 20 GB

### Left in the workspace

`.local/vm/build/` (disk with Docker installed, seed, `known_hosts`, serial log),
`.local/vm/ssh_config`, `.local/s2/` (build context, registry config and data). The ssh
`Host` entry still has the `ControlMaster` lines from the comparison, the `Include` is in
`~/.ssh/config`. The installed devcontainer packages are gone with the next rebuild unless
step 1 adds them.

## Part 3: Buildah and Podman in the devcontainer

### Sketch

Read-only probes (no installs, no config changes) showed why Part 1 failed and that the
kernel side works:

- setuid `newuidmap` fails because a `uid_map` write needs `CAP_SYS_ADMIN` over the target
  namespace, which only its owner (UID 1000) has for free; euid 0 here lacks `sys_admin`
- writing the full 3-line map as UID 1000 with just `CAP_SETUID` / `CAP_SETGID` works, and
  inside, `setresuid` to 1234 or 65534 and `chown 1234:1234` work, also after `chroot`
- a fresh `/proc` mount is denied (Podman masks `/proc/kcore` and friends with locked mounts),
  but recursive binds of `/proc`, `/sys`, `/dev` work, as do `tmpfs`, `chroot`, `pivot_root`
- no AppArmor confinement (`crun (unconfined)`), no seccomp, kernel 6.12

Idea: Buildah with `--isolation chroot` needs no container runtime, no fresh `/proc` and no
network setup, so only the ID mapping is left:

1. `uidmap` with file capabilities instead of setuid root, so `newuidmap` writes as UID 1000
2. `/etc/subuid` and `/etc/subgid` within the container's 0..65536, around UID 1000
3. overlay storage under `.local/podman/` on the ext4 workspace, `vfs` as fallback
4. push straight to the registry on `127.0.0.1:5000`

Fallback if the mapping fails: single-UID mode with `ignore_chown_errors`, which loses
non-root ownership silently. Otherwise the build VM from Part 2.

### Setup

Installed by hand; none of it is in the Dockerfile yet:

```sh
sudo apt-get install -y --no-install-recommends buildah uidmap netavark   # no systemd pulled in
```

`netavark` is needed even though builds use the host network: Buildah 1.39.3 initializes its
network backend at startup, Debian's build only supports `netavark` (not CNI), and without it
every build fails with `could not find "netavark"`.

ID ranges, originals saved as `*.orig`:

```sh
printf 'vscode:1:999\nvscode:1001:64536\n' | sudo tee /etc/subuid /etc/subgid
```

With these ranges but the helpers still setuid root, `buildah unshare` warns
`newuidmap: write to uid_map failed: Operation not permitted` and **falls back to the single
mapping** `0 1000 1`, so a missing fix only shows as a warning. Then:

```sh
sudo chmod u-s /usr/bin/newuidmap /usr/bin/newgidmap
sudo setcap cap_setuid=ep /usr/bin/newuidmap
sudo setcap cap_setgid=ep /usr/bin/newgidmap
buildah unshare cat /proc/self/uid_map   # 0 1000 1 / 1 1 999 / 1000 1001 64536, same for gid
```

What this changes, and why less rights work better here:

- `chmod u-s` drops the setuid bit, so the helpers no longer run as root (euid 0) with every
  capability in the bounding set. Here that set lacks `sys_admin`, which matters below.
- `setcap ...=ep` gives each helper just the one capability it needs, `cap_setuid` or
  `cap_setgid`, effective on exec, while it keeps running as `vscode` (UID 1000). That's a
  much narrower scope than full root.
- The kernel only lets a process write `uid_map` / `gid_map` if it has `CAP_SYS_ADMIN` over
  the new user namespace, plus `CAP_SETUID` / `CAP_SETGID` in the parent for a multi-range
  map. The namespace's owner, `vscode`, holds `CAP_SYS_ADMIN` over it implicitly. Root isn't
  the owner and would need `sys_admin` explicitly, which it doesn't have.
- So, as root, the setuid helper fails for lack of `sys_admin`. As `vscode` with only
  `cap_setuid` / `cap_setgid`, the same write succeeds. Dropping root is what makes it work.

User config, which `setup` would write:

```toml
# ~/.config/containers/storage.conf
[storage]
driver = "overlay"
graphroot = "/workspaces/lrs-k8s-one/.local/podman/storage"
runroot = "/tmp/containers-1000"   # XDG_RUNTIME_DIR is unset

# ~/.config/containers/containers.conf
[containers]
netns = "host"
[engine]
cgroup_manager = "cgroupfs"        # no systemd

# ~/.config/containers/registries.conf
[[registry]]
location = "localhost:5000"
insecure = true
```

### Build and push

```sh
buildah bud --layers --isolation chroot -f Containerfile -t localhost:5000/s2:b1 .
buildah push --tls-verify=false localhost:5000/s2:b1
```

The tag is `localhost:5000`, as the push now runs in the devcontainer, which matches the
manifests' `localhost:5000/<name>` directly.

- the full map works: inside the build, `useradd -u 1234` and `chown 1234:1234` stick
- the layer tarball in the registry has `data/` and `data/f` as `1234/1234`, and `etc/shadow`
  keeps group `shadow` (`0/42`), so base image ownership survives too
- storage is native overlay on the ext4 workspace (`Native Overlay Diff: true`), no
  `fuse-overlayfs` or `vfs` needed
- chroot isolation needs no extra setting beyond `--isolation chroot`; its recursive binds of
  `/proc`, `/sys` and `/dev` work where a fresh `/proc` mount doesn't
- `buildah bud` reads `Containerfile` or `Dockerfile` by default; `-f` was given anyway
- without `--layers`, Buildah doesn't cache intermediate layers, so every build re-runs all steps

### Measurements

Same test image as Part 2, same 16 host vCPUs:

| | Buildah, devcontainer | Docker, build VM |
|---|---|---|
| cold build (incl. base image pull) | 11 s | 80 s |
| rebuild, nothing changed (`--layers`) | 0 s | 3-4 s |
| rebuild after a context change | 1 s | 2 s |
| push, fresh / updated image | 1 s / 0 s | 29 s / 1 s |
| idle cost | none | QEMU RSS ~1.2 GB, 68 s warm boot |

Storage after the spike: 222 MB in `.local/podman/`.

### Gotchas

- **Storage holds files owned by mapped IDs**, e.g. `_apt`'s dirs, so plain `du`, `rm` and
  file search tools hit `Permission denied` in `.local/podman/`. Cleanup goes through
  `buildah unshare rm -rf ...`, or `buildah rm --all` and `buildah rmi --all`.
- the `setcap`, the setuid removal and the ID ranges are root-level changes to the image, so
  they don't survive a rebuild when applied by hand. They go into the Dockerfile, or into
  `setup` with `sudo -n`, which `postCreateCommand` reruns after every rebuild; the plan
  picks `setup`. If they're missing, the symptom is the single-mapping warning
  above, not an error, so the final rebuild must check `buildah unshare cat /proc/self/uid_map`
- **Background processes from `RUN` outlive the build.** Chroot isolation runs steps in the
  devcontainer's PID namespace, so nothing kills leftovers when a step ends; they're
  reparented to the devcontainer's PID 1. `--pid private` is silently ignored in chroot mode.
  Probed with `RUN (setsid sleep 333 &)`. Keep daemons out of `RUN` steps (e.g. Gradle's
  `--no-daemon`), or build with `oci` isolation, which cleans them up, see Podman below
- `buildah unshare <cmd> | head` can log `signal: broken pipe`, harmless

### Podman

Same setup plus `podman` (pulls in `conmon crun libyajl2`, no systemd). Podman shares
Buildah's storage and the same config files, and `podman info` reports `crun`, `cgroupfs`,
`netavark`, overlay and 3 ID map lines.

**Builds:** `podman build --layers --isolation chroot` works like `buildah bud`, 7 s for the
test image without cache.

Later finding: with the B config below, plain `podman build` works with its default `oci`
isolation too. crun then runs each `RUN` step, with the host network and the bound `/proc`.
Probed with `--no-cache`:

- each step gets a private PID namespace (`$$` is 1), and a `setsid sleep &` left behind by a
  step is gone after the build, unlike with chroot isolation
- `apt-get update` and `apt-get install curl` in a step work, 5 s for the whole build
- `useradd -u 1234` plus `chown` stick (`1234:1234`), `/etc/shadow` stays `0:42`
- `podman unshare cat /proc/self/uid_map` shows the same 3 lines as `buildah unshare`
- without the `/proc` bind (a `CONTAINERS_CONF` with only `netns` and `cgroup_manager`), the
  `RUN` step fails with crun's `mount proc to proc: Operation not permitted`. The bind only
  lets crun start; the cleanup comes from the PID namespace: when a step's PID 1 exits, the
  kernel kills the rest

So `podman build` needs no extra flags, it caches layers by default, and its arguments match
`docker build`'s. That lets recipes switch between `podman` and `docker` by command name.

**Running containers:** a plain `podman run` fails with
`crun: mount proc to proc: Operation not permitted`, the fresh `/proc` mount again. There are
2 ways around it, both bind-mount the devcontainer's `/proc` instead:

- **A, `--pid=host`:** no PID namespace of its own, so Podman bind-mounts `/proc` by itself
- **B, a private PID namespace plus `-v /proc:/proc:rbind`:** a user mount replaces Podman's
  default `/proc` mount, so crun binds instead of mounting fresh. It must be `rbind`, a
  recursive bind that also carries the submounts: Podman masked parts of the devcontainer's
  `/proc` (`/proc/kcore`, `/proc/keys`, read-only `/proc/sys`, ...) with locked mounts, and
  the kernel denies anything that would uncover them. A plain bind would drop those masks,
  so it's denied like a fresh mount, while `rbind` keeps them

B is the default, via `containers.conf`:

```toml
# ~/.config/containers/containers.conf
[containers]
netns = "host"
# a fresh /proc mount is denied, so bind the devcontainer's; keeps a private PID namespace
volumes = ["/proc:/proc:rbind"]
[engine]
cgroup_manager = "cgroupfs"
```

| Probe | Result |
|---|---|
| `podman run --rm <img>` | works, `/data/f` is `1234:1234`, `sh` is PID 1 (B) |
| `--user 1234`, writing to its own `/data` | works |
| `--userns=keep-id -v $PWD:/w`, creating a file | works, file owned by `vscode` on the host |
| `-v $PWD:/w` with the default userns | works, workspace files show as root inside |
| `-d` busybox `httpd` on `127.0.0.1:8099` | works, `curl` from the devcontainer gets 200 |
| SIGINT to a foreground `podman run` | works, signal forwarded, container removed |
| `podman build` / `buildah bud` with the B config | work, 7 s / 6 s without cache |
| `--security-opt unmask=ALL` without either | still the `/proc` error |
| `--pid=host --network=none` | fails, `/proc/sys/net/ipv4/ping_group_range` is read-only |
| `--memory 64m --pids-limit 50` | silently ignored: no own cgroup, `memory.max` stays `max` |

**Stopping, A vs B**, tested with `sh -c 'sleep & sh -c sleep & sleep'`, a main process that
doesn't `exec` and has children and grandchildren:

| | A, `--pid=host` | B, private PID namespace |
|---|---|---|
| `podman stop` / `rm -f` | **hangs in `Stopping`**: `given PID did not die` | works |
| children after stop | survive, adopted by `conmon` | all gone |
| `/proc` | consistent | outer view, see below |

Why A hangs: with a shared PID namespace, Podman signals with `crun kill --all <id> <sig>`,
which targets every process in the container's cgroup. The container has no cgroup of its own
(`cgroup-path` is empty in crun's status, `/sys/fs/cgroup` is read-only in the devcontainer),
so nothing is signalled. Signalling the main process directly
(`kill "$(podman inspect -f '{{.State.Pid}}' <name>)"`) ends it, but its children remain.

With B, Podman signals PID 1 as usual, and when PID 1 exits, the kernel kills everything left
in the namespace. As anywhere, a PID 1 without a SIGTERM handler ignores it, so `stop` waits
for its timeout and then sends SIGKILL (exit 137); with a handler it exits at once.

B's catch: PIDs come from the private namespace, but `/proc` from the devcontainer's. So
`$$` is 1 and a background job gets PID 9, while `/proc` lists the ~35 devcontainer processes
under their outer PIDs, and `/proc/1` is the devcontainer's init. `/proc/self` still works,
and `kill <pid>` uses the inner PIDs correctly. What breaks is looking up `/proc/<pid>` for a
PID the container got itself: `ps` and `pgrep` show the wrong processes, `/proc/$$/...` reads
the wrong one, and runtimes inspecting child processes by PID (e.g. Java's
`ProcessHandle.info()`) get wrong or no data. Use `--pid=host` per run for tools that need
this, at the cost of A's `stop` problem.

The real fix is a fresh `/proc`, which likely needs Podman's masks lifted for the
devcontainer itself (`--security-opt unmask=...` in `runArgs`). That's a devcontainer config
change and untested; whether it counts as an extra privilege is open.

Other consequences: with the host network namespace, ports bind straight on the
devcontainer's loopback (so `-p` is meaningless and port clashes are possible), and there are
no resource limits. Fine for build tools and a quick local spin of an image; Kubernetes in the
VM remains the place for realistic runs.

### Left in the running container and workspace

Packages `buildah uidmap netavark podman` (and their deps), `/etc/subuid` and `/etc/subgid`
rewritten, `newuidmap` / `newgidmap` without setuid and with file capabilities, and the three
files in `~/.config/containers/`. In the workspace: `.local/podman/` and test images.

### Verdict

Buildah with chroot isolation works in the devcontainer, with full UID/GID mapping and no
extra privileges or devices. It's 5-30x faster than the build VM, and needs no second VM.
`podman build` works the same way, and with the B config also with its default `oci`
isolation, which cleans up leftover processes per step. `podman run` works with the host
network namespace and a bind-mounted `/proc`; with a private PID namespace, `stop` cleans up
the whole tree, but `/proc` shows outer PIDs. There are no resource limits.
The build VM from Part 2 stays as a second builder, for when Podman falls short.

## Plan updates

Both directions are applied to [README.md](./README.md): Podman (Part 3) is the default for
builds, with `oci` isolation, and for local runs. The build VM (Part 2) is a second builder,
started on demand. The plan uses neither the ssh `Include` nor the `ssh://` transport;
`vm-ssh` and the TCP forward cover it.
