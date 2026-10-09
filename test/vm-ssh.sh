#!/usr/bin/env bash
# regression test: `just vm-ssh` passes arguments to the guest unchanged, keeps stdin, exit
# codes and the login shell for no arguments; needs the VM running, which the recipe ensures.
# Plain ssh fails this, as it joins its arguments for the remote shell to split again, e.g.
# an `it's` breaks it.
# usage: vm-ssh.sh <vm>
set -euo pipefail

cd "$(dirname "$0")/.."
vm=$1 failed=0

vm_ssh() { just vm="$vm" vm-ssh "$@"; }

check() {
    local name=$1 want=$2 got=$3
    if [[ $got == "$want" ]]; then
        echo "ok: $name"
    else
        echo "FAIL: $name"$'\n'"  want: ${want@Q}"$'\n'"  got:  ${got@Q}"
        failed=1
    fi
}

# printf repeats its format per argument, so this shows both count and values
# shellcheck disable=SC2016 # literal $ and backticks are the point
args=("a b" "" "  lead and trail  " "it's" '"dq"' '$HOME' '*' '; echo pwned' '`id`' '$(id)'
    'a\b' '|' '&&' '#x' $'two\nlines' $'tab\there' -n --help '~' '!x')
check "arguments" "$(printf '[%s]\n' "${args[@]}")" "$(vm_ssh printf '[%s]\n' "${args[@]}")"
check "no extra arguments" "[]" "$(vm_ssh printf '[%s]' '')"
check "stdin" 2 "$(printf 'x\ny\n' | vm_ssh wc -l)"
check "exit code" 3 "$(vm_ssh sh -c 'exit 3' > /dev/null 2>&1 || echo $?)"
# shellcheck disable=SC2016 # expanded by the guest's shell
check "login shell, for no arguments" 42 \
    "$(echo 'echo $((6 * 7))' | vm_ssh 2> /dev/null | tail -n 1)"

exit "$failed"
