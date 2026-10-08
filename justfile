import 'versions.just'

set shell := ["bash", "-euo", "pipefail", "-c"]

local := justfile_directory() / ".local"
cache := local / "cache"

# the VM the vm-* recipes act on: cluster or build
vm := "cluster"
vm_dir := local / "vm" / vm
ssh_key := local / "vm/id_ed25519"

k3s_bin := cache / "k3s-" + k3s_version
k3s_images := cache / replace(k3s_images_file, ".tar.zst", "-" + k3s_version + ".tar.zst")
k3s_install := cache / "k3s-install-" + k3s_install_rev + ".sh"

# list recipes
default:
    @just --list

# devcontainer setup: ID mapping, kubectl, containers config; safe to rerun
setup:
    env/setup.sh {{ quote(local) }} {{ quote(cache / "kubectl-" + kubectl_version) }} \
        {{ quote(kubectl_url) }} {{ quote(kubectl_sha256) }}

# start the local registry on 127.0.0.1:5000
registry-up:
    env/registry.sh up {{ quote(local) }}

# stop the local registry
registry-down:
    env/registry.sh down {{ quote(local) }}

# fetch what the VM's seed needs and build its seed.iso; names in the iso match its user-data
_vm-seed:
    #!/usr/bin/env bash
    # a shebang runs the body as one script, as plain recipes run each line in its own shell,
    # which breaks the multi-line case and the array; set shell doesn't apply, hence the set
    set -euo pipefail
    case {{ quote(vm) }} in
        cluster)
            env/fetch.sh {{ quote(k3s_url / "k3s") }} {{ k3s_sha256 }} {{ quote(k3s_bin) }}
            env/fetch.sh {{ quote(k3s_url / k3s_images_file) }} {{ k3s_images_sha256 }} \
                {{ quote(k3s_images) }}
            env/fetch.sh {{ quote(k3s_install_url) }} {{ k3s_install_sha256 }} \
                {{ quote(k3s_install) }}
            files=(
                {{ quote("k3s=" + k3s_bin) }}
                {{ quote(k3s_images_file + "=" + k3s_images) }}
                {{ quote("install.sh=" + k3s_install) }}
            )
            ;;
        *)
            echo "_vm-seed: unknown vm '{{ vm }}', expected cluster" >&2
            exit 1
            ;;
    esac
    env/seed.sh {{ quote(vm_dir) }} {{ quote("env/vm" / vm / "user-data.yaml") }} \
        {{ quote(ssh_key) }} "${files[@]}"
