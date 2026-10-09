# shared helpers for the env scripts
# shellcheck shell=bash

# prefixes messages; the sourcing script's name unless set before sourcing
: "${prog:=$(basename "$0" .sh)}"

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 1; }
note() { printf '%s: %s\n' "$prog" "$*"; }

# Print the PID from a pid file if it names a live process of ours, else nothing. A stale
# file may name an unrelated process that got the same PID, so check its executable, and a
# marker in its command line, e.g. a config path, to tell it from other instances.
# usage: live_pid <pid file> <executable> <marker>
live_pid() {
    local file=$1 exe=$2 marker=$3 pid cmdline
    [[ -f $file ]] || return 0
    pid=$(<"$file")
    [[ $pid =~ ^[0-9]+$ ]] || return 0
    [[ $(readlink "/proc/$pid/exe" 2>/dev/null) == "$exe" ]] || return 0
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 0
    if [[ $cmdline == *"$marker"* ]]; then
        printf '%s\n' "$pid"
    fi
}

# true while a process exists and isn't a zombie, which kill -0 alone would accept
alive() {
    local state
    state=$(ps -o stat= -p "$1") || return 1
    [[ $state != Z* ]]
}

# e.g. 1m40s
fmt_secs() {
    if (($1 >= 60)); then
        printf '%dm%02ds' $(($1 / 60)) $(($1 % 60))
    else
        printf '%ds' "$1"
    fi
}

# Poll a command until it succeeds, or return 1 after a timeout. Prints a progress line about
# every 20 s, e.g. `[1m40s] cloud-init: running`, its status from a function. The command may
# call die to stop waiting early, e.g. when a process exited. Polls every `wait_interval` s,
# default 1. If `wait_start` is set, e.g. to $SECONDS before a series of waits, elapsed time
# and timeout count from there, so the phases of one startup share a time budget.
# usage: wait_for <timeout s> <phase> <status function> <command...>
wait_for() {
    local timeout=$1 phase=$2 status=$3 start=${wait_start:-$SECONDS} elapsed next
    shift 3
    next=$(((SECONDS - start) / 20 * 20 + 20))
    until "$@"; do
        elapsed=$((SECONDS - start))
        ((elapsed < timeout)) || return 1
        if ((elapsed >= next)); then
            printf '[%s] %s: %s\n' "$(fmt_secs "$elapsed")" "$phase" "$("$status")"
            next=$((elapsed / 20 * 20 + 20))
        fi
        sleep "${wait_interval:-1}"
    done
}
