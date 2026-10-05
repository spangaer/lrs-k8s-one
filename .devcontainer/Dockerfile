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
RUN apt-get update && apt-get install -y cmake time ripgrep just tk
