#!/usr/bin/env bash
# Build a VM's NoCloud seed.iso: user-data rendered from its template, meta-data, and extra
# files for the guest, e.g. the cached k3s files for an airgapped install. The shared ssh key
# is generated once if missing. meta-data is kept, so the instance ID stays stable across
# rebuilds of the seed; deleting the VM dir, as a reset does, gets a new one.
# usage: seed.sh <vm dir> <template> <ssh key> [<name in iso>=<file>...]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env/lib.sh
source "$here/lib.sh"

dir=$1 template=$2 key=$3
shift 3

[[ -f $template ]] || die "missing template $template"
for pair in "$@"; do
    [[ $pair == ?*=?* ]] || die "expected <name>=<file>, got '$pair'"
    [[ -f ${pair#*=} ]] || die "missing ${pair#*=}"
done

if [[ ! -f $key ]]; then
    mkdir -p "$(dirname "$key")"
    ssh-keygen -q -t ed25519 -N '' -C lrs-k8s-vm -f "$key"
    note "generated ssh key $key"
fi

mkdir -p "$dir"
# bash substitution, so the key needs no escaping as with sed
user_data=$(<"$template")
# shellcheck disable=SC2016 # literal placeholder
printf '%s\n' "${user_data//'${SSH_PUBKEY}'/$(<"$key.pub")}" > "$dir/user-data"
name=$(basename "$dir")
if [[ ! -f $dir/meta-data ]]; then
    cat > "$dir/meta-data" <<EOF
instance-id: $name-$(date +%Y%m%d-%H%M%S)
local-hostname: $name
EOF
fi

stage=$(mktemp -d "$dir/.stage.XXXXXX")
trap 'rm -rf "$stage" "$dir/seed.iso.part"' EXIT
cp "$dir/user-data" "$dir/meta-data" "$stage/"
for pair in "$@"; do
    # hard links are instant, the k3s files are ~270 MB; copy if on another file system
    ln "${pair#*=}" "$stage/${pair%%=*}" 2>/dev/null || cp "${pair#*=}" "$stage/${pair%%=*}"
done
genisoimage -quiet -output "$dir/seed.iso.part" -volid cidata -joliet -rock "$stage"
mv "$dir/seed.iso.part" "$dir/seed.iso"
