#!/usr/bin/env bash
# Manage a QEMU VM under TCG: create its disk and seed, boot it and wait until it's ready, shut
# it down cleanly, ssh into it, reset it, and copy the cluster's kubeconfig out.
# usage: vm.sh <vm> image <local dir> <base image> [<name in iso>=<file>...]
#        vm.sh <vm> up|down|reset|kubeconfig <local dir>
#        vm.sh <vm> ssh <local dir> [<command> [<arg>...]]
# Sizing comes from VM_CPUS, VM_MEM and VM_DISK; if empty, the VM's default applies.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env/lib.sh
source "$here/lib.sh"

vm=$1 action=$2 local=$3
shift 3
[[ -d $local ]] || die "no such dir $local"

dir=$local/vm/$vm
key=$local/vm/id_ed25519
exe=/usr/bin/qemu-system-x86_64
disk=$dir/disk.qcow2
pid_file=$dir/qemu.pid
qmp=$dir/qmp.sock
serial=$dir/serial.log
qemu_log=$dir/qemu.log
known_hosts=$dir/known_hosts
# what the VM was created from, to detect changed pins or bootstrap settings
settings=$dir/settings
# set after the first successful vm-up, which allows a shorter timeout from then on
provisioned=$dir/provisioned

# all vCPUs if fewer than 4, else at least 4 and up to half; startup is CPU bound
default_cpus() {
    local n
    n=$(nproc)
    if ((n < 4)); then
        echo "$n"
    elif ((n < 8)); then
        echo 4
    else
        echo $((n / 2))
    fi
}

# Per VM: ssh port, other forwards as <host port>:<guest port>, sizing, readiness phases (each
# with ready_<phase> and status_<phase> functions) and timeouts for first and later boots.
case $vm in
    cluster)
        ssh_port=2222
        # API server and traefik; 8080, as a non-root process can't bind ports below 1024
        forwards=(6443:6443 8080:80)
        cpus=${VM_CPUS:-$(default_cpus)} mem=${VM_MEM:-6G} disk_size=${VM_DISK:-30G}
        phases=(boot cloud-init node addons ingress)
        # first boot with the k3s install took 6-7 min, a warm boot ~3 min, both with 8 vCPUs;
        # fewer vCPUs are slower
        first_timeout=900 warm_timeout=360
        ;;
    *) die "unknown vm '$vm', expected cluster" ;;
esac

# the recipe call for this VM, for messages
recipe() {
    if [[ $vm == cluster ]]; then
        echo "just $1"
    else
        echo "just vm=$vm $1"
    fi
}

# the disk path tells this VM's QEMU from other instances
pid() { live_pid "$pid_file" "$exe" "$disk"; }

require_running() {
    [[ $(pid) ]] || die "the $vm VM isn't running, start it with $(recipe vm-up)"
}

ssh_opts=(-i "$key" -p "$ssh_port" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5
    -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)

# ssh joins its arguments with spaces into a command line for the remote shell, which splits
# it again, so single-quote each argument to make it arrive unchanged; works in any POSIX shell
remote_cmd() {
    local arg quoted=()
    for arg; do
        quoted+=("'${arg//\'/\'\\\'\'}'")
    done
    printf '%s' "${quoted[*]}"
}

# run a command in the guest, bounded, as an unresponsive guest can stall ssh
guest() { timeout 60 ssh "${ssh_opts[@]}" debian@127.0.0.1 "$(remote_cmd "$@")"; }

kctl() { guest sudo -n k3s kubectl "$@"; }

# the last non-empty line of the serial console, without escape sequences
last_serial() {
    local line
    line=$(tail -c 4000 "$serial" 2>/dev/null | tr -d '\r' \
        | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; /^[[:space:]]*$/d' | tail -n 1 | cut -c 1-80) \
        || true
    echo "${line:-no console output yet}"
}

qemu_alive() {
    [[ $(pid) ]] || die "QEMU exited, see $serial and $qemu_log"
}

ready_boot() { qemu_alive && guest true 2> /dev/null; }
status_boot() { last_serial; }

ready_cloud_init() {
    local out rc=0
    qemu_alive
    out=$(guest cloud-init status 2> /dev/null) || rc=$?
    case $out in
        *"status: done"*)
            # exit code 2: done, but with recoverable errors
            if ((rc == 2)); then
                note "cloud-init finished with recoverable errors:"$'\n'"$(guest cloud-init \
                    status --long 2>&1)"
            fi
            ;;
        *"status: error"*)
            die "cloud-init failed:"$'\n'"$(guest cloud-init status --long 2>&1)"$'\n'"see" \
                "$(recipe "vm-ssh sudo cat /var/log/cloud-init-output.log")"
            ;;
        *) return 1 ;;
    esac
}
status_cloud_init() {
    local state line
    state=$(guest cloud-init status 2> /dev/null | sed -n 's/^status: //p') || true
    line=$(guest sudo -n tail -n 1 /var/log/cloud-init-output.log 2> /dev/null | cut -c 1-60) \
        || true
    echo "${state:-unknown}${line:+, $line}"
}

# on a warm start the node may still show the Ready from before the shutdown, the later phases
# catch that
ready_node() {
    [[ $(kctl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
        2> /dev/null) == True ]]
}
status_node() {
    local out jp='{range .items[*].status.conditions[?(@.type=="Ready")]}'
    jp+='Ready={.status} ({.reason}){end}'
    out=$(kctl get nodes -o jsonpath="$jp" 2> /dev/null) || true
    echo "${out:-node not registered yet}"
}

# The bundled addons' deployments all have their replicas ready. Right after the install no
# pods exist yet, so checking for pods that aren't running would pass too early.
ready_addons() {
    local out r n=0
    out=$(kctl -n kube-system get deploy coredns local-path-provisioner metrics-server traefik \
        -o jsonpath='{range .items[*]}{.status.readyReplicas}/{.spec.replicas} {end}' \
        2> /dev/null) || return 1
    for r in $out; do
        [[ ${r%/*} == "${r#*/}" && ${r#*/} != 0 ]] || return 1
        n=$((n + 1))
    done
    ((n == 4))
}
# pod counts by phase, and the pods that aren't ready, without their generated name suffixes
status_addons() {
    local jp='{range .items[*]}{.metadata.name} {.status.phase}'
    jp+=' {.status.containerStatuses[*].ready}{"\n"}{end}'
    kctl -n kube-system get pods -o jsonpath="$jp" 2> /dev/null | awk '
        # Kubernetes generates name suffixes without vowels, so real words never match.
        BEGIN { h = "[bcdfghjklmnpqrstvwxz24-9]" }
        { count[$2]++ }
        $2 != "Succeeded" && (NF < 3 || / false/) {
            sub("-" h "{5}$", "", $1); sub("-" h "{8,10}$", "", $1)
            waiting = waiting (waiting ? ", " : "") $1
        }
        END {
            for (p in count) s = s (s ? ", " : "") count[p] " " tolower(p)
            print (s ? s : "no pods yet") (waiting ? "; not ready: " waiting : "")
        }'
}

# any HTTP answer means traefik serves; it's a 404 while no ingress matches
ingress_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/ || true
}
ready_ingress() { [[ $(ingress_code) != 000 ]]; }
status_ingress() {
    local code
    code=$(ingress_code)
    if [[ $code == 000 ]]; then echo "no answer yet"; else echo "HTTP $code"; fi
}

# where to look when a phase times out
hint() {
    case $1 in
        boot) echo "see $serial" ;;
        cloud-init) echo "see $(recipe "vm-ssh cloud-init status --long")" ;;
        *) echo "see $(recipe "vm-ssh sudo journalctl -u k3s")" ;;
    esac
}

# the settings the VM is created from; the k3s and image versions are in the file names
stamp() {
    local pair pub=missing
    [[ ! -f $key.pub ]] || pub=$(cut -d ' ' -f 2 "$key.pub")
    printf 'base image: %s\n' "$(basename "$base")"
    printf 'disk size: %s\n' "$disk_size"
    printf 'user-data template: sha256 %s\n' "$(sha256sum < "$template" | cut -d ' ' -f 1)"
    printf 'ssh key: %s\n' "$pub"
    # without "in", for loops over "$@", the name=file seed pairs
    for pair; do
        printf 'seed file: %s from %s\n' "${pair%%=*}" "$(basename "${pair#*=}")"
    done
}

image() {
    local base=$1 template=$here/vm/$vm/user-data.yaml want
    shift
    [[ -f $base ]] || die "missing base image $base"
    if [[ -f $disk ]]; then
        want=$(stamp "$@")
        if [[ ! -f $settings || $(<"$settings") != "$want" ]]; then
            die "the $vm VM was created with other settings, run $(recipe vm-reset) to" \
                "recreate it:"$'\n'"$(diff <(cat "$settings" 2> /dev/null) <(echo "$want") \
                | sed -nE 's/^< /  was: /p; s/^> /  now: /p')"
        fi
        # The settings match, so the seed's inputs are unchanged and a lost seed can be
        # rebuilt. A new disk or vm-reset always deletes the seed, so it's never stale.
        if [[ ! -f $dir/seed.iso ]]; then
            "$here/seed.sh" "$dir" "$template" "$key" "$@"
            note "rebuilt the $vm VM's seed"
        fi
        note "the $vm VM exists, settings unchanged"
        return
    fi
    [[ -z $(pid) ]] || die "QEMU runs without its disk $disk; stop it with $(recipe vm-down)"
    # a new disk is a new VM, so it gets a new instance ID and host keys
    rm -f "$dir/meta-data" "$dir/seed.iso" "$known_hosts" "$provisioned"
    "$here/seed.sh" "$dir" "$template" "$key" "$@"
    stamp "$@" > "$settings"
    # the backing file must be an absolute path
    qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$base")" "$disk.part" "$disk_size"
    mv "$disk.part" "$disk"
    note "created the $vm VM: $disk_size disk, backed by $(basename "$base")"
}

start_qemu() {
    local fwd f
    # QEMU uses commas to separate options
    [[ $dir != *,* ]] || die "QEMU can't take paths with a comma: $dir"
    fwd=hostfwd=tcp:127.0.0.1:$ssh_port-:22
    for f in "${forwards[@]}"; do
        fwd+=,hostfwd=tcp:127.0.0.1:${f%%:*}-:${f#*:}
    done
    rm -f "$pid_file" "$qmp"
    note "starting the $vm VM, $cpus vCPUs, $mem RAM"
    # -daemonize returns once QEMU is set up, so errors like a taken port show here
    "$exe" -name "lrs-k8s-$vm" -accel tcg,thread=multi -cpu max -smp "$cpus" -m "$mem" \
        -drive "file=$disk,if=virtio,format=qcow2" \
        -drive "file=$dir/seed.iso,if=virtio,format=raw,readonly=on" \
        -netdev "user,id=n0,$fwd" -device virtio-net-pci,netdev=n0 \
        -display none -serial "file:$serial" -qmp "unix:$qmp,server=on,wait=off" \
        -daemonize -pidfile "$pid_file" 2> "$qemu_log" \
        || die "QEMU failed to start, see $qemu_log:"$'\n'"$(tail -n 5 "$qemu_log")"
    [[ $(pid) ]] || die "QEMU started, but $pid_file doesn't name it, see $qemu_log"
}

up() {
    local p phase fn timeout=$warm_timeout
    [[ -f $disk ]] || die "the $vm VM has no disk, create it with $(recipe vm-image)"
    p=$(pid)
    if [[ $p ]]; then
        note "the $vm VM is already running, pid $p"
    else
        start_qemu
    fi
    [[ -f $provisioned ]] || timeout=$first_timeout
    # each check runs ssh, and some k3s kubectl, which are slow under TCG, so poll less often
    wait_start=$SECONDS wait_interval=5
    for phase in "${phases[@]}"; do
        fn=${phase//-/_}
        wait_for "$timeout" "$phase" "status_$fn" "ready_$fn" \
            || die "$phase not ready after $(fmt_secs "$timeout"): $("status_$fn"); $(hint \
                "$phase")"
        printf '[%s] %s: ready\n' "$(fmt_secs $((SECONDS - wait_start)))" "$phase"
    done
    touch "$provisioned"
    [[ $vm != cluster ]] || kubeconfig
    note "the $vm VM is ready, ssh with $(recipe vm-ssh)"
}

stopped() { [[ -z $(pid) ]]; }

# ACPI power button, a clean shutdown that needs neither ssh nor sudo in the guest
power_button() {
    printf '%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"system_powerdown"}' \
        | socat -t 2 - "UNIX-CONNECT:$qmp" > /dev/null 2>&1
}

# A press in early boot, before systemd-logind listens, is lost, so repeat it. Once the
# shutdown runs, more presses do nothing.
shut_down() {
    stopped && return
    if ((SECONDS >= next_press)); then
        power_button || true
        next_press=$((SECONDS + 10))
    fi
    return 1
}

down() {
    local p
    p=$(pid)
    if [[ -z $p ]]; then
        rm -f "$pid_file" "$qmp"
        note "the $vm VM isn't running"
        return
    fi
    power_button || die "can't reach QEMU's control socket $qmp; to stop it hard: kill $p"
    next_press=$((SECONDS + 10))
    wait_interval=1 wait_for 120 shutdown last_serial shut_down \
        || die "the $vm VM didn't shut down within 2 min, see $serial; to stop it hard: kill $p"
    rm -f "$pid_file" "$qmp"
    note "the $vm VM is stopped"
}

ssh_into() {
    local tty=()
    require_running
    (($#)) || exec ssh "${ssh_opts[@]}" debian@127.0.0.1
    # A terminal for interactive commands like top, but not when output is captured: -t 0
    # tests whether stdin is a terminal, -t 1 whether stdout is.
    [[ ! -t 0 || ! -t 1 ]] || tty=(-t)
    exec ssh "${ssh_opts[@]}" "${tty[@]}" debian@127.0.0.1 "$(remote_cmd "$@")"
}

# keeps the cache, the shared ssh key, and the registry's and Podman's storage
reset() {
    down
    rm -rf "$dir"
    note "removed the $vm VM, $(recipe vm-up) creates a fresh one"
}

# Copy k3s.yaml out of the guest, atomically and with mode 0600, as it holds admin
# credentials; the API is reached through the 6443 forward. Like known_hosts, it belongs to
# this VM instance, so it's kept in its dir and vm-reset removes it.
kubeconfig() {
    local out=$dir/kubeconfig tmp
    [[ $vm == cluster ]] || die "only the cluster VM runs k3s"
    require_running
    tmp=$(mktemp "$out.XXXXXX")
    if ! guest sudo -n cat /etc/rancher/k3s/k3s.yaml \
        | sed -E 's#^( *server: ).*#\1https://127.0.0.1:6443#' > "$tmp" \
        || ! grep -q 'server: https://127.0.0.1:6443' "$tmp"; then
        rm -f "$tmp"
        die "can't read the kubeconfig from /etc/rancher/k3s/k3s.yaml in the guest"
    fi
    mv "$tmp" "$out"
    note "wrote $out"
}

case $action in
    image | up | down | reset | kubeconfig) "$action" "$@" ;;
    ssh) ssh_into "$@" ;;
    *) die "unknown action '$action'" ;;
esac
