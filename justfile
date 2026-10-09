import 'versions.just'

set shell := ["bash", "-euo", "pipefail", "-c"]

local := justfile_directory() / ".local"
cache := local / "cache"

# the VM the vm-* recipes act on: cluster or build, e.g. just vm=build vm-up
vm := "cluster"

# VM sizing, e.g. just vm_mem=8G vm-up; empty for the VM's default, see env/vm.sh
vm_cpus := ""
vm_mem := ""
vm_disk := ""
export VM_CPUS := vm_cpus
export VM_MEM := vm_mem
export VM_DISK := vm_disk

debian_image := cache / debian_image_file
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

# fetch downloads, create the VM's disk and seed; an existing VM is kept, see vm-reset
vm-image:
    #!/usr/bin/env bash
    # a shebang runs the body as one script, as plain recipes run each line in its own shell,
    # which breaks the multi-line case and the array; set shell doesn't apply, hence the set
    set -euo pipefail
    # files for the seed, named as the VM's user-data expects them
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
            echo "vm-image: unknown vm '{{ vm }}', expected cluster" >&2
            exit 1
            ;;
    esac
    env/fetch.sh {{ quote(debian_image_url) }} {{ debian_image_sha512 }} \
        {{ quote(debian_image) }}
    env/vm.sh {{ quote(vm) }} image {{ quote(local) }} {{ quote(debian_image) }} "${files[@]}"

# boot the VM unless it runs, and wait until it's ready
vm-up: vm-image
    env/vm.sh {{ quote(vm) }} up {{ quote(local) }}

# shut the VM down cleanly
vm-down:
    env/vm.sh {{ quote(vm) }} down {{ quote(local) }}

# ssh into the VM, or run a command there with its arguments unchanged
[positional-arguments]
vm-ssh *args:
    @env/vm.sh {{ quote(vm) }} ssh {{ quote(local) }} "$@"

# stop the VM and drop its disk and seed, for a fresh one; the caches stay
vm-reset:
    env/vm.sh {{ quote(vm) }} reset {{ quote(local) }}

# copy the cluster's admin kubeconfig to .local/vm/cluster/kubeconfig
kubeconfig:
    env/vm.sh cluster kubeconfig {{ quote(local) }}

# check that vm-ssh passes arguments unchanged
test-vm-ssh: vm-up
    test/vm-ssh.sh {{ quote(vm) }}
