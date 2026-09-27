#!/usr/bin/env bash
# Install ros1 on this host (run as your user; uses sudo where needed).
#
#   ./install.sh              check prerequisites, create shared folders,
#                             link ros1.service and the `1` command
#   ./install.sh --enable     same, and start ros1 at boot
#   ./install.sh --uninstall  stop (commits), disable and unlink everything;
#                             images and this folder are kept
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "${DIR}"
UNIT=ros1.service
BIN=/usr/local/bin/1

ok()   { echo "  ok    $*"; }
warn() { echo "  WARN  $*"; }
fail() { echo "  FAIL  $*"; exit 1; }

[ "${EUID}" -ne 0 ] || fail "run as your normal user, not root (sudo is used when needed)"

enable=false
uninstall=false
for arg in "$@"; do
    case "${arg}" in
        --enable)    enable=true ;;
        --uninstall) uninstall=true ;;
        -h|--help)   sed -n '2,8s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)           fail "unknown option: ${arg} (see ./install.sh --help)" ;;
    esac
done
if "${enable}" && "${uninstall}"; then
    fail "--enable and --uninstall cannot be used together"
fi

if "${uninstall}"; then
    sudo systemctl disable --now "${UNIT}" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${UNIT}" "${BIN}"
    sudo systemctl daemon-reload
    echo "ros1 uninstalled. Images ros1:base/ros1:latest and ${DIR} were kept."
    exit 0
fi

echo "Checking prerequisites"
[ "${DIR}" = /opt/ros-containers/ros1 ] \
    || fail "this repo must live at /opt/ros-containers (ros1.service expects it); it is at ${DIR%/ros1}"
command -v docker >/dev/null || fail "docker is not installed"
docker compose version >/dev/null 2>&1 || fail "docker compose plugin is not installed"
ok "docker $(docker version -f '{{.Client.Version}}' 2>/dev/null) / compose $(docker compose version --short)"
if systemctl is-enabled docker.service >/dev/null 2>&1; then
    ok "docker.service enabled"
else
    warn "docker.service is not enabled: sudo systemctl enable --now docker"
fi
if id -nG | tr ' ' '\n' | grep -qx docker; then
    ok "$(id -un) is in the docker group"
else
    warn "$(id -un) is not in the docker group (the \`1\` command needs it):"
    warn "  sudo usermod -aG docker $(id -un)   then log out and back in"
fi

env_user="$(sed -n 's/^ROS1_USER=//p' .env)"
env_uid="$(sed -n 's/^ROS1_UID=//p' .env)"
env_gid="$(sed -n 's/^ROS1_GID=//p' .env)"
if [ "${env_user}:${env_uid}:${env_gid}" = "$(id -un):$(id -u):$(id -g)" ]; then
    ok ".env user matches ${env_user} (${env_uid}:${env_gid})"
else
    fail ".env has ${env_user}:${env_uid}:${env_gid} but you are $(id -un):$(id -u):$(id -g); fix .env"
fi

if sed -n 's/^COMPOSE_FILE=//p' .env | grep -q nvidia; then
    if compgen -G "/etc/cdi/*nvidia*" >/dev/null || compgen -G "/var/run/cdi/*nvidia*" >/dev/null; then
        ok "NVIDIA CDI spec found"
    else
        warn "compose.nvidia.yaml is enabled but no NVIDIA CDI spec exists:"
        warn "  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
        warn "  (or remove :compose.nvidia.yaml from COMPOSE_FILE in .env)"
    fi
fi

echo "Shared folders"
# Every bind source under /home/<user> in the compose config must exist.
compose_config="$(docker compose config)" \
    || fail "docker compose config failed (error above); fix compose.yaml or .env"
mapfile -t shared < <(awk -v h="/home/${env_user}/" \
    '$1=="source:" && index($2,h)==1 {print $2}' <<<"${compose_config}")
[ "${#shared[@]}" -gt 0 ] \
    || fail "no shared folders under /home/${env_user}/ found in compose.yaml"
for src in "${shared[@]}"; do
    if [ -d "${src}" ]; then
        ok "${src}"
    else
        mkdir -p "${src}"
        ok "${src} (created)"
    fi
done

echo "Images of companion services"
# ros1.service never pulls (it must also start offline), so download any
# third-party images from the compose files (e.g. mongo) now.
for img in $(docker compose config --images 2>/dev/null | sort -u); do
    case "${img}" in ros1:*) continue ;; esac
    if docker image inspect "${img}" >/dev/null 2>&1; then
        ok "${img}"
    else
        docker pull -q "${img}" >/dev/null || fail "could not download ${img}"
        ok "${img} (downloaded)"
    fi
done

echo "Installing"
chmod +x commit.sh enter.sh build.sh entrypoint.sh
# SELinux: files moved in from ~/Downloads keep a "home" label that systemd
# is not allowed to read. Reset the whole repo to the normal /opt labels.
if command -v restorecon >/dev/null; then
    sudo restorecon -R "${DIR%/ros1}"
    ok "SELinux labels reset on ${DIR%/ros1}"
fi
sudo systemctl link "${DIR}/${UNIT}" >/dev/null
sudo systemctl daemon-reload
ok "${UNIT} linked into /etc/systemd/system"
sudo ln -sfn "${DIR}/enter.sh" "${BIN}"
ok "${BIN} -> ${DIR}/enter.sh"
if "${enable}"; then
    sudo systemctl enable "${UNIT}" >/dev/null
    ok "${UNIT} enabled at boot"
fi

echo
if docker image inspect ros1:latest >/dev/null 2>&1; then
    echo "Done. Start with: sudo systemctl start ros1   then run: 1"
else
    echo "Done. Next: ./build.sh   then: sudo systemctl start ros1   then: 1"
fi
