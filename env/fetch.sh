#!/usr/bin/env bash
# fetch a pinned download into the cache once, and verify its checksum on every call
# usage: fetch.sh <url> <sha256 or sha512> <file>
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=env/lib.sh
source "$here/lib.sh"

url=$1 sum=$2 file=$3

case ${#sum} in
    64) tool=sha256sum ;;
    128) tool=sha512sum ;;
    *) die "checksum for $file is neither sha256 nor sha512" ;;
esac

check() { printf '%s  %s\n' "$sum" "$1" | "$tool" --check --status; }

if [[ -f $file ]]; then
    check "$file" && exit 0
    die "checksum mismatch for cached $file; it's corrupt, or its pin changed without a new" \
        "file name. Remove it to fetch again, but not while a VM disk uses it as backing image"
fi

mkdir -p "$(dirname "$file")"
note "$url"
curl -fL --retry 3 --progress-bar -o "$file.part" "$url"
if ! check "$file.part"; then
    rm -f "$file.part"
    die "checksum mismatch for $url, check its pin in versions.just"
fi
mv "$file.part" "$file"
