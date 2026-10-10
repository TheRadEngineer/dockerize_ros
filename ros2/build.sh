#!/usr/bin/env bash
# Build ros2:base from the Dockerfile (settings from .env).
#
#   ./build.sh              build ros2:base; create ros2:latest if it doesn't exist
#   ./build.sh --reset      also reset ros2:latest to the fresh ros2:base
#                           (DISCARDS everything committed in ros2:latest)
#   ./build.sh --no-cache   rebuild without Docker's build cache
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "${DIR}"

reset=false
build_args=()
for arg in "$@"; do
    case "${arg}" in
        --reset)    reset=true ;;
        --no-cache) build_args+=(--no-cache) ;;
        -h|--help)  sed -n '2,8s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)          echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

container_exists() { docker container inspect ros2 >/dev/null 2>&1; }
image_exists()     { docker image inspect "$1" >/dev/null 2>&1; }

if "${reset}" && container_exists; then
    echo "The ros2 container exists. Stop it first: sudo systemctl stop ros2" >&2
    exit 1
fi

docker compose --profile build build "${build_args[@]}" ros2-base

if "${reset}"; then
    read -r -p "Reset ros2:latest to ros2:base? Everything committed in ros2:latest is lost. [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]] || { echo "ros2:latest kept."; exit 0; }
    docker tag ros2:base ros2:latest
    echo "ros2:latest reset to ros2:base."
elif ! image_exists ros2:latest; then
    docker tag ros2:base ros2:latest
    echo "Created ros2:latest from ros2:base."
else
    echo "ros2:base rebuilt. ros2:latest (your committed image) is unchanged;"
    echo "use --reset to start over from the new base."
fi
