#!/usr/bin/env bash
# `1` - open a shell (or run a command) in the running ros1 container.
# Installed as /usr/local/bin/1 (symlink to this file).
#
#   1                   interactive shell in the container's home
#   1 <cmd> [args...]   run one command, e.g. `1 rviz`
#   1 --nvidia [cmd]    same, rendering on the NVIDIA GPU (PRIME offload)
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
NAME=ros1
USER_NAME="$(sed -n 's/^ROS1_USER=//p' "${DIR}/.env" | tail -n1)"
USER_NAME="${USER_NAME:-$(id -un)}"

usage() {
    sed -n '2,8s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
}

nvidia=false
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--nvidia) nvidia=true; shift ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; break ;;
        *)           break ;;
    esac
done

if ! docker info >/dev/null 2>&1; then
    echo "1: cannot talk to Docker. Is docker running, and are you in the 'docker' group?" >&2
    exit 1
fi
if [ "$(docker container inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null)" != true ]; then
    echo "1: the ${NAME} container is not running. Start it with: sudo systemctl start ${NAME}" >&2
    exit 1
fi

# Forward the live desktop session so GUI apps, audio and D-Bus work.
args=(-i -u "${USER_NAME}" -w "/home/${USER_NAME}")
[ -t 0 ] && [ -t 1 ] && args+=(-t)
for var in DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_SESSION_TYPE \
           DBUS_SESSION_BUS_ADDRESS TERM COLORTERM \
           XCURSOR_THEME XCURSOR_SIZE QT_SCALE_FACTOR QT_SCREEN_SCALE_FACTORS; do
    [ -n "${!var:-}" ] && args+=(-e "${var}")
done
if "${nvidia}"; then
    args+=(-e __NV_PRIME_RENDER_OFFLOAD=1 -e __GLX_VENDOR_LIBRARY_NAME=nvidia
           -e __VK_LAYER_NV_optimus=NVIDIA_only)
fi

# Login shell: /etc/profile and ~/.profile -> ~/.bashrc (the container's own).
if [ $# -eq 0 ]; then
    exec docker exec "${args[@]}" "${NAME}" bash -l
elif [ -t 0 ]; then
    exec docker exec "${args[@]}" "${NAME}" bash -lic 'exec "$@"' bash "$@"
else
    exec docker exec "${args[@]}" "${NAME}" bash -lc 'exec "$@"' bash "$@"
fi
