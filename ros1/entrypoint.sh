#!/usr/bin/env bash
# Container entrypoint (runs as root, PID 1 is docker's init).
#
#  1. Links host services from /run/host (the host's /run, read-only) into the
#     container's private /run: system D-Bus, udev, avahi, docker socket.
#  2. Makes $CONTAINER_USER a member of every group that owns a host device
#     node, so all hardware in /dev is usable without sudo. /dev is the host's,
#     so its group IDs are Fedora's, not Ubuntu's; unknown IDs get a "host<gid>"
#     group. The change lands in /etc/group and is kept by the next commit.
#  3. Hands over to CMD (sleep infinity).
set -euo pipefail

user="${CONTAINER_USER:?CONTAINER_USER not set}"

# --- 1. host services ------------------------------------------------------
mkdir -p /run/lock
chmod 1777 /run/lock
# Linked even if the host service isn't up yet: the link starts working as
# soon as the service appears (e.g. avahi starting after ros1 at boot).
for name in dbus udev avahi-daemon docker.sock; do
    ln -sfn "/run/host/${name}" "/run/${name}"
done

# --- 2. device groups ------------------------------------------------------
primary_gid="$(id -g "${user}")"
mapfile -t gids < <(
    {
        find /dev -maxdepth 3 \( -type c -o -type b \) -printf '%G\n' 2>/dev/null
        [ -S /run/host/docker.sock ] && stat -c '%g' /run/host/docker.sock
    } | sort -un
)

for gid in "${gids[@]}"; do
    if [ "${gid}" -eq 0 ] || [ "${gid}" -eq "${primary_gid}" ]; then
        continue
    fi
    group="$(getent group "${gid}" | cut -d: -f1 || true)"
    if [ -z "${group}" ]; then
        group="host${gid}"
        # A name clash (host GIDs changed, e.g. after reinstalling Fedora) must
        # not stop the container from starting: warn and skip this group.
        if ! groupadd -g "${gid}" "${group}" 2>/dev/null; then
            echo "entrypoint: warning: could not create group ${group} (GID ${gid}), skipped" >&2
            continue
        fi
    fi
    if ! id -nG "${user}" | tr ' ' '\n' | grep -qx "${group}"; then
        usermod -aG "${group}" "${user}" \
            || echo "entrypoint: warning: could not add ${user} to ${group}" >&2
    fi
done

# --- 3. run CMD ------------------------------------------------------------
exec "$@"
