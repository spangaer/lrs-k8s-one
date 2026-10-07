import 'versions.just'

set shell := ["bash", "-euo", "pipefail", "-c"]

local := justfile_directory() / ".local"
cache := local / "cache"

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
