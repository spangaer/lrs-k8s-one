# Spike log for S1 (ticket 1), including version pinning

Scratchpad with the main commands from the spike, as input for the implementation. These are
cleaned-up versions of what was run, not finished recipes. Paths are relative to the workspace
root unless a step `cd`s. Other spikes get their own `spike-s<n>.md`.

## Version pinning

```sh
# k3s channels, pick `stable`
curl -fsSL https://update.k3s.io/v1-release/channels | python3 -c 'import json,sys
for c in json.load(sys.stdin)["data"]: print(c["name"], c.get("latest"))'

# k3s checksums, note the url-encoded `+`
curl -fsSL https://github.com/k3s-io/k3s/releases/download/v1.36.5%2Bk3s1/sha256sum-amd64.txt \
  | grep -E ' (k3s|k3s-airgap-images-amd64\.tar\.zst)$'

# commit behind the release tag, used to pin install.sh
curl -fsSL https://api.github.com/repos/k3s-io/k3s/git/ref/tags/v1.36.5%2Bk3s1
curl -fsSL https://raw.githubusercontent.com/k3s-io/k3s/<commit>/install.sh | sha256sum

# kubectl, matching minor
curl -fsSL https://dl.k8s.io/release/stable-1.36.txt
curl -fsSL https://dl.k8s.io/release/v1.36.5/bin/linux/amd64/kubectl.sha256

# Debian cloud image: newest dated dir, then SHA512SUMS
curl -fsSL https://cloud.debian.org/images/cloud/trixie/ \
  | grep -oE 'href="[0-9]{8}-[0-9]+/' | tail -1
curl -fsSL https://cloud.debian.org/images/cloud/trixie/20261001-2618/SHA512SUMS \
  | grep genericcloud-amd64.qcow2
```

Gotcha: the Debian directory listing sometimes stalls, so use `-m <timeout>` and retry.

## Packages

```sh
sudo apt-get install -y --no-install-recommends qemu-system-x86 qemu-utils cloud-image-utils
dpkg -l systemd   # must find nothing
```

## Cache

Download to `<name>.part`, then rename, so an interrupted download never looks complete. File
names carry the version or revision.

```sh
mkdir -p .local/cache && cd .local/cache
dl() { [ -f "$2" ] || { curl -fSL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"; }; }
dl "$debian_image_url" debian-13-genericcloud-amd64-20261001-2618.qcow2
dl "$k3s_url/k3s" k3s-v1.36.5+k3s1
dl "$k3s_url/k3s-airgap-images-amd64.tar.zst" k3s-airgap-images-amd64-v1.36.5+k3s1.tar.zst
dl "$k3s_install_url" k3s-install-<rev>.sh
dl "$kubectl_url" kubectl-v1.36.5
echo "<sha512>  debian-13-genericcloud-amd64-20261001-2618.qcow2" | sha512sum -c
echo "<sha256>  k3s-v1.36.5+k3s1" | sha256sum -c   # same for the others
```

Sizes: image 341 MB, airgap images 194 MB, k3s 79 MB, kubectl 60 MB.

## S1: VM image and seed

```sh
mkdir -p .local/vm/seed && cd .local/vm
[ -f id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C lrs-k8s-vm -f id_ed25519
# the backing file must be an absolute path
qemu-img create -q -f qcow2 -F qcow2 \
  -b "$(realpath ../cache/debian-13-genericcloud-amd64-20261001-2618.qcow2)" disk.qcow2 30G

# no `users:` block, so the image's default user `debian` gets the key
cat > seed/user-data <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat id_ed25519.pub)
EOF
printf 'instance-id: spike-s1-1\nlocal-hostname: k3s\n' > seed/meta-data
cp ../cache/k3s-v1.36.5+k3s1 seed/k3s
cp ../cache/k3s-airgap-images-amd64-v1.36.5+k3s1.tar.zst seed/k3s-airgap-images-amd64.tar.zst
cp ../cache/k3s-install-*.sh seed/install.sh
genisoimage -quiet -output seed.iso -volid cidata -joliet -rock seed/
rm -r seed
```

The S1 run used a custom `k3s` user. An explicit `users:` list replaces the default user, so
`debian` didn't exist. We switched to `debian` to avoid confusion with the k3s service. A
throwaway boot with the user-data above confirmed it: `debian` gets the key and passwordless
sudo through `/etc/sudoers.d/90-cloud-init-users`, so `sudo -n` works. The S1 overlay with the
`k3s` user has since been removed; the cache and the ssh key were kept.

The resulting `seed.iso` is 274 MB. The root fs grows to the full 30 GB without extra config.

## S1: boot

```sh
qemu-system-x86_64 -name lrs-k8s -accel tcg,thread=multi -cpu max -smp 6 -m 8G \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -drive file=seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:6443-:6443,\
hostfwd=tcp:127.0.0.1:8080-:80 \
  -device virtio-net-pci,netdev=n0 -display none -serial file:serial.log \
  -daemonize -pidfile qemu.pid
```

The new defaults are `-smp floor(n / 2)` and `-m 6G`, see the plan.

```sh
SSH="ssh -q -i id_ed25519 -p 2222 -o UserKnownHostsFile=known_hosts \
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes debian@127.0.0.1"
until $SSH true 2>/dev/null; do sleep 5; done          # bound this, ~1 min on first boot
$SSH 'cloud-init status --wait >/dev/null; cloud-init status --long'
$SSH 'systemd-analyze; df -h /; timedatectl | grep -E "synchronized|NTP"'
```

## S1: airgapped k3s install

```sh
$SSH 'set -e
sudo mkdir -p /mnt/seed
mountpoint -q /mnt/seed || sudo mount -o ro LABEL=cidata /mnt/seed
sudo install -m 0755 /mnt/seed/k3s /usr/local/bin/k3s
sudo install -D -m 0644 /mnt/seed/k3s-airgap-images-amd64.tar.zst \
  /var/lib/rancher/k3s/agent/images/k3s-airgap-images-amd64.tar.zst
sudo env INSTALL_K3S_SKIP_DOWNLOAD=true K3S_KUBECONFIG_MODE=0600 sh /mnt/seed/install.sh'
```

## S1: readiness

```sh
# node Ready
$SSH 'sudo k3s kubectl get nodes | grep -qw Ready'
# addons, wait for the deployments, as pods don't exist yet right after install
$SSH 'for d in coredns traefik metrics-server; do
  sudo k3s kubectl -n kube-system rollout status deploy/$d --timeout=10s; done'
# through hostfwd
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/         # 404 from traefik
curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:6443/version  # 401 from apiserver
```

Gotchas:
- right after install, `get pods -A` is empty, so "no pod is not Running" passes too early
- on a warm start `get nodes` can still show the stale `Ready` from before the shutdown, so
  check the addons or traefik as well
- `rollout status` fails while the deployment doesn't exist yet, so loop over it

## S1: measuring

```sh
# Host CPU of the QEMU process, averaged over 60 s. Fields 14 and 15 of /proc/<pid>/stat are
# utime and stime: CPU time spent in user and kernel mode, in clock ticks, summed over all
# threads. `getconf CLK_TCK` is 100, so one fully busy core adds 100 ticks per second. Ticks
# per second is thus directly the percentage of one core, e.g. 102 means ~1 core.
# The `read` split assumes field 2 (the command name) has no spaces, true for QEMU.
P=$(cat qemu.pid)
read -r _ _ _ _ _ _ _ _ _ _ _ _ _ u1 s1 _ < /proc/$P/stat; sleep 60
read -r _ _ _ _ _ _ _ _ _ _ _ _ _ u2 s2 _ < /proc/$P/stat
echo "$(( (u2+s2-u1-s1) / 60 ))% of one core"
# host memory (rss, in KiB) and uptime of QEMU
ps -o rss=,etime= -p $P
# guest view: load, CPU/memory per node and pod (via metrics-server), free memory
$SSH 'uptime; sudo k3s kubectl top node; sudo k3s kubectl top pods -A; free -m'
```

## S1: shutdown

```sh
P=$(cat qemu.pid)
$SSH 'sudo systemctl poweroff'
while [ -d /proc/$P ]; do sleep 1; done   # 16 s, bound this and check identity first
rm -f qemu.pid
```

Gotcha: the agent's shell tool rejects `kill -0 $P`, so the spike used `/proc/$P`. Recipes
should validate identity, e.g. `/proc/$P/cmdline` contains `qemu-system-x86_64` and
`-name lrs-k8s`, before trusting the PID file.
