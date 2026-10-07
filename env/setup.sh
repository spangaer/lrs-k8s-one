#!/usr/bin/env bash
# devcontainer setup: ID mapping, kubectl and containers config
# Safe to rerun: it only changes what differs, so it also repairs what a package upgrade reset.
# Root-level changes are lost on a devcontainer rebuild, so postCreateCommand reruns this.
# usage: setup.sh <local dir> <kubectl file> <kubectl url> <kubectl sha256>
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env/lib.sh
source "$here/lib.sh"

local_dir=$1 kubectl_file=$2 kubectl_url=$3 kubectl_sha256=$4

# write stdin to a file if its content differs, extra args prefix the write, e.g. sudo -n
changed=
put() {
    local dest=$1 mode=$2 tmp
    shift 2
    tmp=$(mktemp)
    cat > "$tmp"
    if ! cmp -s "$tmp" "$dest"; then
        "$@" install -D -m "$mode" "$tmp" "$dest"
        note "updated $dest"
        changed=1
    fi
    rm -f "$tmp"
}

sudo -n true 2>/dev/null \
    || die "root-level changes need passwordless sudo; run 'sudo -v' and retry, or run as a" \
        "user with passwordless sudo"

# --- ID mapping, so rootless Podman gets a full range of IDs, not just its own

user=$(id -un)

# Highest ID inside the devcontainer's user namespace, subordinate ranges must stay within it.
# Each line of an ID map is <first ID inside> <first ID outside> <count>, e.g.
#          0          1       1000
#       1000          0          1
#       1001       1001      64536
# gives 65536, the last ID of the highest range: 1001 + 64536 - 1.
max_id() { awk '{ e = $1 + $3 - 1; if (e > m) m = e } END { print m }' "$1"; }

# Every ID but 0, which stays root's, and our own, which the user namespace maps to us anyway.
# Lines are <name>:<first ID>:<count>, e.g. for ID 1000 and max 65536:
#   vscode:1:999
#   vscode:1001:64536
sub_ids() {
    local id=$1 max=$2
    printf '%s:1:%d\n%s:%d:%d\n' "$user" $((id - 1)) "$user" $((id + 1)) $((max - id))
}

put /etc/subuid 0644 sudo -n < <(sub_ids "$(id -u)" "$(max_id /proc/self/uid_map)")
put /etc/subgid 0644 sudo -n < <(sub_ids "$(id -g)" "$(max_id /proc/self/gid_map)")

# Writing an ID map needs sys_admin over the new user namespace, which its owner, us, holds
# implicitly. Setuid root breaks that: root isn't the owner and lacks sys_admin here. So drop
# setuid, and grant just the cap_setuid / cap_setgid a multi-range map needs on top.
id_map_helper() {
    local bin=/usr/bin/$1 cap=$2
    if [[ $(getcap "$bin") != "$bin $cap=ep" ]]; then
        sudo -n setcap "$cap=ep" "$bin"
        note "set $cap on $bin"
        changed=1
    fi
    if [[ -u $bin ]]; then
        sudo -n chmod u-s "$bin"
        note "dropped setuid from $bin"
        changed=1
    fi
}
id_map_helper newuidmap cap_setuid
id_map_helper newgidmap cap_setgid
id_map_changed=$changed

# --- kubectl, in /usr/local/bin as ~/.local/bin isn't on PATH

"$here/fetch.sh" "$kubectl_url" "$kubectl_sha256" "$kubectl_file"
put /usr/local/bin/kubectl 0755 sudo -n < "$kubectl_file"

# --- containers config, for Podman

conf=~/.config/containers
runroot=/tmp/containers-$(id -u)

put "$conf/storage.conf" 0644 <<EOF
[storage]
driver = "overlay"
# in the workspace, so images survive a rebuild. It holds files owned by mapped IDs, so clean
# up with podman rmi, podman system prune or podman system reset, not rm
graphroot = "$local_dir/podman/storage"
# XDG_RUNTIME_DIR is unset; /tmp starts empty with every new container
runroot = "$runroot"
EOF

put "$conf/containers.conf" 0644 <<'EOF'
[containers]
# a private network needs /dev/net/tun, which the devcontainer lacks; ports bind straight on
# its loopback
netns = "host"
# A fresh /proc mount is denied, as Podman masked parts of the devcontainer's /proc. A
# recursive bind keeps those masks, so it's allowed, and containers keep a private PID
# namespace. Inside, /proc shows the devcontainer's processes, not the container's.
volumes = ["/proc:/proc:rbind"]

[engine]
# no systemd
cgroup_manager = "cgroupfs"
EOF

# a drop-in, as a user registries.conf would disable the system's short name aliases
put "$conf/registries.conf.d/50-localhost.conf" 0644 <<'EOF'
# local registry, plain HTTP on loopback only
[[registry]]
location = "localhost:5000"
insecure = true
EOF

install -d -m 0700 "$runroot"

# --- check

# Restart Podman's pause process, which holds on to the ID mapping it started with. This also
# stops running containers, so only on ID mapping changes; config files are read per command.
if [[ $id_map_changed ]]; then
    podman system migrate
fi

# without the full mapping, Podman fails, or maps a single ID with just a warning and loses chown
if [[ $(podman unshare cat /proc/self/uid_map | wc -l) -lt 3 ]]; then
    die "Podman lacks the full ID mapping. Check /etc/subuid, /etc/subgid and" \
        "'getcap /usr/bin/newuidmap /usr/bin/newgidmap', then rerun setup"
fi
note "done"
