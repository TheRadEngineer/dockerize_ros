#!/usr/bin/env bash
# Lifecycle hooks for ros1.service: commit the container into ros1:latest.
#
#   commit.sh prestart    before start: commit + remove a leftover container
#                         (e.g. after a power cut), so start is always fresh
#   commit.sh wait        after start: wait until the container is running
#   commit.sh checkpoint  systemctl reload: commit without stopping
#   commit.sh stop        systemctl stop/restart/shutdown: stop, commit,
#                         remove, and flatten the image if it has too many layers
#   commit.sh squash      flatten ros1:latest into a single layer now
#
# Commits only happen when `docker diff` shows changes. ros1:base is never
# touched, so it stays available as a clean fallback (./build.sh --reset).
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "${DIR}"                       # docker compose reads compose files + .env here
NAME=ros1
IMAGE=ros1:latest

env_value() {  # env_value KEY DEFAULT  -> value from .env
    local v
    v="$(sed -n "s/^$1=//p" "${DIR}/.env" 2>/dev/null | tail -n1)"
    echo "${v:-$2}"
}
SQUASH_THRESHOLD="$(env_value ROS1_SQUASH_THRESHOLD 90)"

log() { echo "[${NAME}] $*"; }

exists()  { docker container inspect "${NAME}" >/dev/null 2>&1; }
running() { [ "$(docker container inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null)" = true ]; }
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

# Did anything real change in the container?
# Ignored: the linker cache and bare "directory changed" entries of system
# folders. The NVIDIA toolkit and ldconfig touch these on every start, which
# would otherwise cause a pointless commit (and a new layer) on every stop.
# Any real change still shows up as its own file entry.
NOISE='^C (/etc|/etc/ld\.so\.cache|/var|/var/cache|/var/cache/ldconfig|/var/cache/ldconfig/aux-cache|/usr|/usr/lib|/usr/lib/x86_64-linux-gnu|/usr/bin|/usr/share|/usr/share/glvnd|/usr/share/glvnd/egl_vendor\.d|/usr/share/vulkan|/usr/share/vulkan/icd\.d|/usr/share/egl|/usr/share/egl/egl_external_platform\.d|/etc/vulkan|/etc/vulkan/icd\.d|/lib|/lib/firmware)$'
changed() {
    local diff
    diff="$(docker diff "${NAME}" 2>/dev/null || true)"
    diff="$(grep -Ev "${NOISE}" <<<"${diff}" || true)"
    [ -n "${diff}" ]
}

# NVIDIA driver files are injected into the container at start (they are the
# host's, so they always match the host driver). Two clean-ups keep old driver
# versions from being baked into ros1:latest and breaking it after a driver
# update:
#   before stop:  remove the links that point at injected driver files
#   after start:  remove leftovers of an older driver, rebuild library links
NVIDIA_DIRS='/usr/lib/x86_64-linux-gnu /usr/lib64 /usr/bin /usr/share/glvnd /usr/share/vulkan /usr/share/egl /etc/vulkan /lib/firmware/nvidia'
NVIDIA_FIND='\( -iname "*nvidia*" -o -name "libcuda*" -o -name "libnvcuvid*" -o -name "libnvoptix*" \)'

nvidia_prestop() {
    docker exec -u 0 "${NAME}" bash -c '
        for d in '"${NVIDIA_DIRS}"'; do
            [ -d "$d" ] || continue
            find "$d" -maxdepth 3 -type l '"${NVIDIA_FIND}"' -print0 2>/dev/null |
            while IFS= read -r -d "" link; do
                target="$(readlink -f "$link")" || continue
                [ -e "$target" ] || continue
                # target on another filesystem = injected by the toolkit
                if [ "$(stat -c %d "$target")" != "$(stat -c %d "$(dirname "$link")")" ]; then
                    rm -f "$link"
                fi
            done
        done' >/dev/null 2>&1 || true
}

nvidia_poststart() {
    docker exec -u 0 "${NAME}" bash -c '
        for d in '"${NVIDIA_DIRS}"'; do
            [ -d "$d" ] || continue
            # empty files = placeholders of an older driver that is not injected anymore
            find "$d" -maxdepth 3 -type f -empty '"${NVIDIA_FIND}"' -delete 2>/dev/null
            # broken links to an older driver
            find "$d" -maxdepth 3 -xtype l '"${NVIDIA_FIND}"' -delete 2>/dev/null
        done
        ldconfig' >/dev/null 2>&1 || true
}

commit() {  # commit REASON
    if ! changed; then
        log "no changes, nothing to commit"
        return 0
    fi
    local old started_from
    old="$(image_id "${IMAGE}")"
    started_from="$(docker container inspect -f '{{.Image}}' "${NAME}")"
    log "committing ${NAME} -> ${IMAGE} ($1)"
    # A checkpoint runs while you work: don't freeze the container for the
    # (possibly minutes-long) commit. A stopped container needs no pause.
    docker commit --pause=false --message "auto-commit: $1 $(date -Is)" "${NAME}" "${IMAGE}" >/dev/null
    log "committed ($(layers) layers)"
    # A commit always contains everything changed since the container started,
    # so the previous ros1:latest (an earlier checkpoint) is now superseded.
    # Delete it, unless the running container was started from it or it is
    # ros1:base; otherwise every reload would leave a multi-GB orphan behind.
    if [ -n "${old}" ] && [ "${old}" != "${started_from}" ] \
       && [ "${old}" != "$(image_id ros1:base)" ]; then
        docker image rm "${old}" >/dev/null 2>&1 || true
    fi
}

layers() { docker image inspect -f '{{len .RootFS.Layers}}' "${IMAGE}"; }

shutting_down() {
    case "$(systemctl is-system-running 2>/dev/null || true)" in
        stopping) return 0 ;;
        *) return 1 ;;
    esac
}

# Flatten ros1:latest to one layer, keeping its runtime config.
squash() {
    local old tmp
    local -a changes=()
    old="$(image_id "${IMAGE}")"
    [ -n "${old}" ] || { log "no ${IMAGE} to squash"; return 1; }
    if exists; then
        log "container ${NAME} exists; stop the service before squashing"
        return 1
    fi

    # Rebuild the image config (compose.* labels are dropped on purpose).
    while IFS= read -r kv; do
        [ -n "${kv}" ] || continue
        local key="${kv%%=*}" val="${kv#*=}"
        val="${val//\\/\\\\}"; val="${val//\"/\\\"}"
        changes+=(--change "ENV ${key}=\"${val}\"")
    done < <(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${IMAGE}")
    while IFS= read -r kv; do
        [ -n "${kv}" ] || continue
        local key="${kv%%=*}" val="${kv#*=}"
        case "${key}" in com.docker.compose.*) continue ;; esac
        val="${val//\\/\\\\}"; val="${val//\"/\\\"}"
        changes+=(--change "LABEL \"${key}\"=\"${val}\"")
    done < <(docker image inspect -f '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}' "${IMAGE}")
    local ep cmd wd user
    ep="$(docker image inspect -f '{{json .Config.Entrypoint}}' "${IMAGE}")"
    cmd="$(docker image inspect -f '{{json .Config.Cmd}}' "${IMAGE}")"
    wd="$(docker image inspect -f '{{.Config.WorkingDir}}' "${IMAGE}")"
    user="$(docker image inspect -f '{{.Config.User}}' "${IMAGE}")"
    [ "${ep}" != null ] && changes+=(--change "ENTRYPOINT ${ep}")
    [ "${cmd}" != null ] && changes+=(--change "CMD ${cmd}")
    [ -n "${wd}" ] && changes+=(--change "WORKDIR ${wd}")
    [ -n "${user}" ] && changes+=(--change "USER ${user}")

    log "squashing ${IMAGE} ($(layers) layers), this can take a few minutes..."
    tmp="$(docker create "${IMAGE}")"
    trap 'docker rm -f "${tmp}" >/dev/null 2>&1 || true' RETURN
    docker export "${tmp}" \
        | docker import "${changes[@]}" --message "squashed $(date -Is)" - "${IMAGE}" >/dev/null
    docker rm -f "${tmp}" >/dev/null
    # Drop the old layer chain unless something else still uses it.
    docker image rm "${old}" >/dev/null 2>&1 || true
    log "squashed ${IMAGE} to $(layers) layer(s)"
}

case "${1:-}" in
    prestart)
        if exists; then
            log "found a leftover ${NAME} container, saving it first"
            if running; then
                nvidia_prestop
                docker stop -t 10 "${NAME}" >/dev/null
            fi
            commit "recovered leftover container"
            docker rm -f "${NAME}" >/dev/null
        fi
        if [ -z "$(image_id "${IMAGE}")" ]; then
            log "image ${IMAGE} not found: build it with ${DIR}/build.sh"
            exit 1
        fi
        ;;
    wait)
        for _ in $(seq 1 60); do
            if running; then
                nvidia_poststart
                exit 0
            fi
            sleep 1
        done
        log "container did not start within 60s"
        exit 1
        ;;
    checkpoint)
        if running; then
            commit "checkpoint"
        else
            log "not running, nothing to checkpoint"
        fi
        ;;
    stop)
        if exists; then
            if running; then
                nvidia_prestop
                log "stopping container"
                docker stop -t 10 "${NAME}" >/dev/null
            fi
            commit "stop"
            docker rm -f "${NAME}" >/dev/null
        else
            log "no ${NAME} container"
        fi
        # Companion services from the compose files (e.g. MongoDB) stop too.
        # They are not committed: their data lives in Docker volumes.
        docker compose stop >/dev/null 2>&1 || true
        if [ -n "$(image_id "${IMAGE}")" ] && [ "$(layers)" -gt "${SQUASH_THRESHOLD}" ]; then
            if shutting_down; then
                log "$(layers) layers > ${SQUASH_THRESHOLD}; squash postponed (system is shutting down)"
            else
                squash
            fi
        fi
        ;;
    squash)
        squash
        ;;
    *)
        echo "usage: $0 {prestart|wait|checkpoint|stop|squash}" >&2
        exit 2
        ;;
esac
