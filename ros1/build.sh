#!/usr/bin/env bash
# Build ros1:base from the Dockerfile (settings from .env).
#
#   ./build.sh              build ros1:base; create ros1:latest if it doesn't exist
#   ./build.sh --reset      also reset ros1:latest to the fresh ros1:base
#                           (DISCARDS everything committed in ros1:latest)
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

container_exists() { docker container inspect ros1 >/dev/null 2>&1; }
image_exists()     { docker image inspect "$1" >/dev/null 2>&1; }

if "${reset}" && container_exists; then
    echo "The ros1 container exists. Stop it first: sudo systemctl stop ros1" >&2
    exit 1
fi

docker compose --profile build build "${build_args[@]}" ros1-base

if "${reset}"; then
    read -r -p "Reset ros1:latest to ros1:base? Everything committed in ros1:latest is lost. [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]] || { echo "ros1:latest kept."; exit 0; }
    docker tag ros1:base ros1:latest
    echo "ros1:latest reset to ros1:base."
elif ! image_exists ros1:latest; then
    docker tag ros1:base ros1:latest
    echo "Created ros1:latest from ros1:base."
else
    echo "ros1:base rebuilt. ros1:latest (your committed image) is unchanged;"
    echo "use --reset to start over from the new base."
fi
