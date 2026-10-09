FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie

# keep systemd and friends out, they misbehave in containers
# priority -1 makes apt skip them as recommends and fail loudly on hard dependencies
RUN printf '%s\n' \
      'Package: systemd systemd-sysv init dbus dbus-user-session libpam-systemd' \
      'Pin: release *' \
      'Pin-Priority: -1' \
    > /etc/apt/preferences.d/no-systemd

# ripgrep: used by copilot for code search
# just: simpler more portable make
# tk: Tcl/Tk runtime (wish) for the bundled git gui and gitk
# shellcheck: lint for shell scripts
RUN apt-get update && apt-get install -y cmake time ripgrep just tk shellcheck

# k8s test env tooling
# qemu-*, cloud-image-utils: cluster and build VMs under TCG, seed.iso via genisoimage
# socat: clean VM shutdown through QEMU's control socket
# podman, uidmap, netavark: rootless builds and runs; podman needs netavark even on host network
# docker-registry: local registry the VMs pull from and push to
# docker-cli, docker-buildx: client for the build VM's dockerd
RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils cloud-image-utils socat \
      podman uidmap netavark \
      docker-registry docker-cli docker-buildx
