#!/usr/bin/env bash
# start or stop the local registry; safe to repeat
# usage: registry.sh up|down <local dir>
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env/lib.sh
source "$here/lib.sh"

action=$1 dir=$2/registry
exe=/usr/bin/docker-registry
config=$here/registry/config.yml
pid_file=$dir/registry.pid
log=$dir/registry.log
url=http://127.0.0.1:5000/v2/

pid() { live_pid "$pid_file" "$exe" "$config"; }
answers() { curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; }

# During startup, $! briefly is the forked shell or setsid, before they exec the registry,
# so check it's alive by PID, and only require the pid file match once it answers.
ready() {
    if ! alive "$child"; then
        rm -f "$pid_file"
        die "exited during startup, see $log:"$'\n'"$(tail -n 5 "$log")"
    fi
    [[ $(pid) ]] && answers
}

stopped() { [[ -z $(pid) ]]; }

up() {
    local p
    p=$(pid)
    if [[ $p ]]; then
        note "already running, pid $p"
        return
    fi
    # else a foreign registry would answer the readiness check, while ours fails to bind
    if answers; then
        die "something else already serves $url, e.g. a registry started by hand"
    fi
    mkdir -p "$dir/storage"
    # setsid: own session, so it outlives the shell and doesn't get its signals
    REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=$dir/storage \
        setsid "$exe" serve "$config" > "$log" 2>&1 < /dev/null &
    child=$!
    echo "$child" > "$pid_file"
    wait_for 30 "startup" "echo waiting for $url" ready \
        || die "not ready after 30 s, see $log"
    note "up on 127.0.0.1:5000, pid $(pid)"
}

down() {
    local p
    p=$(pid)
    if [[ -z $p ]]; then
        rm -f "$pid_file"
        note "not running"
        return
    fi
    kill -TERM "$p"
    wait_for 30 "shutdown" "echo pid $p still running" stopped \
        || die "pid $p didn't exit within 30 s, see $log"
    rm -f "$pid_file"
    note "stopped"
}

case $action in
    up | down) "$action" ;;
    *) die "unknown action '$action', use up or down" ;;
esac
