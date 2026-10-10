#!/usr/bin/env bash
# sync.sh - back up / restore a ROS environment to / from an external drive.
#
#   ./sync.sh export [ros1|ros2]   write everything to a drive (default ros1)
#   ./sync.sh import [ros1|ros2]   restore from a drive
#
# One export = three parts in <drive>/ros-containers/ (each with a .sha256):
#   ros1.tar.zst                images: ros1:latest, ros1:base, mongo:6.0
#   ros1-mongo.archive.gz       MongoDB database dump (mongodump)
# (for ros2: ros2.tar.zst and ros2-mongo.archive.gz, next to the ros1 files)
#   ros-containers-repo.tar.gz  this repo incl. git history
# plus a copy of sync.sh, so a fresh PC can run: bash <drive>/ros-containers/sync.sh import
#
# Lists the external drives, recommends the best one, mounts it if needed
# (no sudo). Only the latest export is kept on the drive. Import asks before
# replacing anything and skips parts that aren't on the drive.
# Run on the host as your user (not inside the container).
set -euo pipefail

TARGET_REPO=/opt/ros-containers           # where the repo lives on every PC
DRIVE_DIR=ros-containers
REPO_FILE=ros-containers-repo.tar.gz

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mfail\033[0m  %s\n' "$*" >&2; exit 1; }
human() { numfmt --to=iec --suffix=B "$1"; }
confirm() { local a; read -r -p "$1 [y/N] " a; [[ "${a}" =~ ^[Yy]$ ]]; }
confirm_yes() { local a; read -r -p "$1 [Y/n] " a; [[ ! "${a}" =~ ^[Nn]$ ]]; }
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

usage() { sed -n '2,18s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }

# --- arguments and checks ----------------------------------------------------
action="${1:-}"
name="${2:-ros1}"
case "${action}" in
    export|import) ;;
    -h|--help|"") usage; exit 0 ;;
    *) usage; exit 2 ;;
esac

# The repo is the folder this script is in, or /opt/ros-containers when the
# script is run from the drive copy (e.g. on a fresh PC).
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [ -d "${SCRIPT_DIR}/${name}" ]; then REPO="${SCRIPT_DIR}"; else REPO="${TARGET_REPO}"; fi
MONGO_CONTAINER="${name}-mongo"

[ -z "${CONTAINER_NAME:-}" ] || die "run this on the host, not inside the container"
[ "${EUID}" -ne 0 ] || die "run as your user, not root (sudo is used when needed)"
docker info >/dev/null 2>&1 || die "cannot talk to Docker (running? in the docker group?)"
for tool in zstd udisksctl lsblk numfmt; do
    command -v "${tool}" >/dev/null || die "'${tool}' is missing (sudo dnf install ${tool})"
done
if [ "${action}" = export ]; then
    [ -d "${REPO}/${name}" ] || die "unknown container '${name}' (no ${REPO}/${name} folder)"
fi

# --- drive discovery -----------------------------------------------------------
# field KEY LINE: value of KEY="..." in one line of `lsblk -P` output
field() {
    local re="$1=\"([^\"]*)\""
    if [[ "$2" =~ ${re} ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
}

# usb_speed DISK -> "<Mb/s>|<label>"  (walks sysfs up to the USB device)
usb_speed() {
    local p s
    p="$(readlink -f "/sys/block/$1")"
    while [ -n "${p}" ] && [ "${p}" != / ]; do
        if [ -f "${p}/speed" ] && [ -f "${p}/idVendor" ]; then
            s="$(cat "${p}/speed")"
            case "${s}" in
                1.5|12) echo "12|USB 1 (very slow)" ;;
                480)    echo "480|USB 2 (slow port!)" ;;
                5000)   echo "5000|USB 3 5Gb/s" ;;
                10000)  echo "10000|USB 3 10Gb/s" ;;
                20000)  echo "20000|USB 3 20Gb/s" ;;
                *)      echo "${s%%.*}|USB ${s}Mb/s" ;;
            esac
            return
        fi
        p="$(dirname "${p}")"
    done
    echo "0|-"
}

# fs_rating FSTYPE -> "<rank>|<note>"  (lower rank = better; 9 = unusable)
fs_rating() {
    case "$1" in
        ext4|xfs|btrfs|f2fs) echo "1|best (Linux)" ;;
        exfat)               echo "2|good (Linux+Windows)" ;;
        ntfs|ntfs3)          echo "2|good (Linux+Windows)" ;;
        vfat)                echo "9|unusable: FAT32 4GB file limit" ;;
        crypto_LUKS)         echo "9|encrypted: unlock in Dolphin first" ;;
        *)                   echo "3|untested filesystem" ;;
    esac
}

D_DEV=() D_FS=() D_LABEL=() D_SIZE=() D_MNT=() D_AVAIL=() D_SPEED=() D_RANK=() D_NOTE=() D_DISK=()

find_drives() {
    local dline pline disk tran hot rm speed sp_num sp_label fs rating
    while IFS= read -r dline; do
        disk="$(field NAME "${dline}")"
        tran="$(field TRAN "${dline}")"
        hot="$(field HOTPLUG "${dline}")"
        rm="$(field RM "${dline}")"
        [ "$(field TYPE "${dline}")" = disk ] || continue
        [ "${tran}" = usb ] || [ "${hot}" = 1 ] || [ "${rm}" = 1 ] || continue
        speed="$(usb_speed "${disk}")"
        sp_num="${speed%%|*}"
        sp_label="${speed#*|}"
        while IFS= read -r pline; do
            fs="$(field FSTYPE "${pline}")"
            [ -n "${fs}" ] || continue
            case "$(field TYPE "${pline}")" in part|disk|crypt) ;; *) continue ;; esac
            rating="$(fs_rating "${fs}")"
            D_DEV+=("$(field PATH "${pline}")")
            D_FS+=("${fs}")
            D_LABEL+=("$(field LABEL "${pline}")")
            D_SIZE+=("$(field SIZE "${pline}")")
            D_MNT+=("$(field MOUNTPOINT "${pline}")")
            D_AVAIL+=("$(field FSAVAIL "${pline}")")
            D_SPEED+=("${sp_num}|${sp_label}")
            D_RANK+=("${rating%%|*}")
            D_NOTE+=("${rating#*|}")
            D_DISK+=("/dev/${disk}")
        done < <(lsblk -nP -o PATH,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINT,FSAVAIL "/dev/${disk}")
    done < <(lsblk -dnP -o NAME,TYPE,TRAN,HOTPLUG,RM)
}

# Show the menu, set SEL to the chosen index.
choose_drive() {
    find_drives
    [ "${#D_DEV[@]}" -gt 0 ] || die "no external drive found; plug one in and try again"

    # Recommend: best filesystem, then fastest port.
    local i best=-1 best_key=""
    for i in "${!D_DEV[@]}"; do
        [ "${D_RANK[i]}" -lt 9 ] || continue
        local key
        key="$(printf '%d%08d' "$((9 - D_RANK[i]))" "${D_SPEED[i]%%|*}")"
        if [ -z "${best_key}" ] || [[ "${key}" > "${best_key}" ]]; then
            best=${i}; best_key=${key}
        fi
    done

    echo
    printf '    %-3s %-12s %-16s %-7s %-7s %-7s %-18s %s\n' \
        "#" DEVICE LABEL SIZE FREE FS PORT NOTE
    for i in "${!D_DEV[@]}"; do
        local mark="  "
        [ "${i}" -eq "${best}" ] && mark="★ "
        printf '  %s%-3s %-12s %-16s %-7s %-7s %-7s %-18s %s\n' "${mark}" "$((i + 1))" \
            "${D_DEV[i]}" "${D_LABEL[i]:--}" "${D_SIZE[i]}" "${D_AVAIL[i]:-?}" \
            "${D_FS[i]}" "${D_SPEED[i]#*|}" "${D_NOTE[i]}"
    done
    echo "  (★ = recommended, FREE shows ? until the drive is mounted)"
    echo

    local choice default=""
    [ "${best}" -ge 0 ] && default=$((best + 1))
    read -r -p "Select drive [1-${#D_DEV[@]}]${default:+ (Enter = ${default})}: " choice
    choice="${choice:-${default}}"
    [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#D_DEV[@]}" ] \
        || die "invalid choice"
    SEL=$((choice - 1))
    [ "${D_RANK[SEL]}" -lt 9 ] || die "${D_DEV[SEL]}: ${D_NOTE[SEL]}"
    if [ "${D_SPEED[SEL]%%|*}" = 480 ]; then
        warn "this drive is on a USB 2 port; a USB 3 port is ~5-10x faster"
    fi
}

# Mount the selected drive if needed; set MNT.
mount_drive() {
    local dev="${D_DEV[SEL]}"
    MNT="${D_MNT[SEL]}"
    if [ -z "${MNT}" ]; then
        info "Mounting ${dev}"
        udisksctl mount -b "${dev}" >/dev/null
        MNT="$(lsblk -no MOUNTPOINT "${dev}" | head -n1)"
        [ -n "${MNT}" ] || die "could not mount ${dev}"
    fi
    ok "${dev} is mounted at ${MNT}"
}

eject_drive() {
    confirm "Safely remove the drive now?" || return 0
    sync
    if udisksctl unmount -b "${D_DEV[SEL]}" >/dev/null \
       && udisksctl power-off -b "${D_DISK[SEL]}" >/dev/null 2>&1; then
        ok "drive can be unplugged"
    else
        warn "could not eject (still in use?); eject it from Dolphin"
    fi
}

# --- helpers for writing and checking parts ------------------------------------
PARTIALS=()
trap 'rm -f "${PARTIALS[@]}"' EXIT

# save_part FILE FUNCTION: write FUNCTION's output to FILE with a .sha256.
# Written as FILE.partial first and renamed at the end, so an interrupted
# export never damages the previous one.
save_part() {
    local out="$1" producer="$2" part hash
    part="${out}.partial"
    PARTIALS+=("${part}" "${part}.sha256")
    hash="$("${producer}" | tee "${part}" | sha256sum | cut -d' ' -f1)"
    echo "${hash}  $(basename "${out}")" > "${part}.sha256"
    sync -f "${part}"
    mv -f "${part}" "${out}"
    mv -f "${part}.sha256" "${out}.sha256"
}

# verify_part FILE: check FILE against FILE.sha256
verify_part() {
    local file="$1" expected actual
    if [ ! -f "${file}.sha256" ]; then
        warn "$(basename "${file}"): no checksum file, cannot verify"
        confirm "Use it anyway?" || exit 1
        return 0
    fi
    expected="$(cut -d' ' -f1 < "${file}.sha256")"
    actual="$(sha256sum "${file}" | cut -d' ' -f1)"
    [ "${expected}" = "${actual}" ] \
        || die "$(basename "${file}"): checksum mismatch, the file is damaged. Nothing was changed."
    ok "$(basename "${file}"): checksum matches"
}

# mongo_up: make sure the MongoDB container runs and answers.
# Returns 1 if there is no such container.
MONGO_STARTED_BY_US=false
MONGO_PORT=27017
# The port mongod listens on: --port from the container's command, else 27017
# (ros1-mongo uses 27017, ros2-mongo 27018).
mongo_port() {
    local cmd port
    cmd="$(docker container inspect -f '{{join .Config.Cmd " "}}' "${MONGO_CONTAINER}" 2>/dev/null || true)"
    port="$(sed -n 's/.*--port[ =]\([0-9][0-9]*\).*/\1/p' <<<"${cmd}")"
    echo "${port:-27017}"
}
mongo_up() {
    docker container inspect "${MONGO_CONTAINER}" >/dev/null 2>&1 || return 1
    MONGO_PORT="$(mongo_port)"
    if [ "$(docker container inspect -f '{{.State.Running}}' "${MONGO_CONTAINER}")" != true ]; then
        docker start "${MONGO_CONTAINER}" >/dev/null
        MONGO_STARTED_BY_US=true
    fi
    local _
    for _ in $(seq 1 30); do
        if docker exec "${MONGO_CONTAINER}" mongosh --quiet --port "${MONGO_PORT}" --eval 'db.runCommand({ping:1}).ok' 2>/dev/null \
            | grep -q 1; then
            return 0
        fi
        sleep 1
    done
    die "MongoDB (${MONGO_CONTAINER}) did not become ready"
}
mongo_restore_state() {
    if "${MONGO_STARTED_BY_US}"; then
        docker stop "${MONGO_CONTAINER}" >/dev/null
        MONGO_STARTED_BY_US=false
    fi
}

produce_images() { docker save "${EXPORT_TAGS[@]}" | zstd -T0 -3 --progress -c; }
produce_mongo()  { docker exec "${MONGO_CONTAINER}" mongodump --port "${MONGO_PORT}" --archive --gzip --quiet; }
produce_repo()   { tar -C "$(dirname "${REPO}")" -czf - "$(basename "${REPO}")"; }

prepare_drive_dir() {
    DIR="${MNT}/${DRIVE_DIR}"
    if ! mkdir -p "${DIR}" 2>/dev/null; then
        sudo mkdir -p "${DIR}"
        sudo chown "$(id -u):$(id -g)" "${DIR}"
    fi
    touch "${DIR}/.write-test" 2>/dev/null \
        || die "cannot write to ${DIR} (read-only? NTFS drives mount read-only if Windows didn't shut down cleanly)"
    rm -f "${DIR}/.write-test"
}

# --- export --------------------------------------------------------------------
do_export() {
    [ -n "$(image_id "${name}:latest")" ] || die "image ${name}:latest not found"

    choose_drive
    mount_drive
    prepare_drive_dir

    if systemctl is-active --quiet "${name}"; then
        info "Saving the running ${name} container first"
        sudo systemctl reload "${name}"
    fi

    # Images: ros1:latest, ros1:base and companion images (e.g. mongo:6.0),
    # so a restore also works offline.
    EXPORT_TAGS=("${name}:latest")
    [ -n "$(image_id "${name}:base")" ] && EXPORT_TAGS+=("${name}:base")
    local img
    for img in $(cd "${REPO}/${name}" && docker compose config --images 2>/dev/null | sort -u); do
        case "${img}" in "${name}":*) continue ;; esac
        [ -n "$(image_id "${img}")" ] && EXPORT_TAGS+=("${img}")
    done

    local size avail
    size="$(docker image inspect -f '{{.Size}}' "${name}:latest")"
    avail="$(df -B1 --output=avail "${DIR}" | tail -n1 | tr -d ' ')"
    info "Image size $(human "${size}") (compressed to roughly half); free on drive $(human "${avail}")"
    if [ "${avail}" -lt $((size * 6 / 10)) ]; then
        warn "the drive may not have enough free space"
        confirm "Try anyway?" || exit 1
    fi

    local start=$SECONDS
    local f_img="${DIR}/${name}.tar.zst"
    local f_db="${DIR}/${MONGO_CONTAINER}.archive.gz"
    local f_repo="${DIR}/${REPO_FILE}"

    info "1/3 Images: ${EXPORT_TAGS[*]}"
    save_part "${f_img}" produce_images
    ok "$(basename "${f_img}")  $(human "$(stat -c %s "${f_img}")")"

    info "2/3 MongoDB database"
    if mongo_up; then
        save_part "${f_db}" produce_mongo
        mongo_restore_state
        ok "$(basename "${f_db}")  $(human "$(stat -c %s "${f_db}")")"
    else
        warn "no ${MONGO_CONTAINER} container on this PC, database skipped"
    fi

    info "3/3 Repo ${REPO} (with git history)"
    save_part "${f_repo}" produce_repo
    cp -f "${REPO}/sync.sh" "${DIR}/sync.sh"
    ok "$(basename "${f_repo}")  $(human "$(stat -c %s "${f_repo}")")  (+ sync.sh)"

    ok "export finished in $(( SECONDS - start ))s -> ${DIR}"
    eject_drive
}

# --- import --------------------------------------------------------------------
do_import() {
    choose_drive
    mount_drive
    DIR="${MNT}/${DRIVE_DIR}"
    [ -d "${DIR}" ] || die "no ${DRIVE_DIR}/ folder on ${MNT}; nothing exported to this drive yet"

    local f_img="${DIR}/${name}.tar.zst"
    local f_db="${DIR}/${MONGO_CONTAINER}.archive.gz"
    local f_repo="${DIR}/${REPO_FILE}"

    # What's on the drive, and what should be restored?
    echo
    info "Found on the drive:"
    local want_img=false want_db=false want_repo=false f
    for f in "${f_repo}" "${f_img}" "${f_db}"; do
        if [ -f "${f}" ]; then
            printf '    %-32s %8s  %s\n' "$(basename "${f}")" \
                "$(human "$(stat -c %s "${f}")")" "$(date -r "${f}" '+%Y-%m-%d %H:%M')"
        else
            printf '    %-32s %8s\n' "$(basename "${f}")" "missing"
        fi
    done
    echo
    [ -f "${f_repo}" ] && confirm_yes "Restore the repo to ${TARGET_REPO}?" && want_repo=true
    [ -f "${f_img}" ]  && confirm_yes "Restore the images (${name}:latest, ...)?" && want_img=true
    [ -f "${f_db}" ]   && confirm_yes "Restore the MongoDB database?" && want_db=true
    "${want_repo}" || "${want_img}" || "${want_db}" || die "nothing selected"

    # Verify everything before changing anything.
    info "Verifying checksums"
    "${want_repo}" && verify_part "${f_repo}"
    "${want_img}"  && verify_part "${f_img}"
    "${want_db}"   && verify_part "${f_db}"

    echo
    "${want_repo}" && warn "The repo at ${TARGET_REPO} will be replaced (the current one is kept as ${TARGET_REPO}.old-<date>)."
    "${want_img}"  && warn "${name}:latest will be replaced: changes not in this export are lost."
    "${want_db}"   && warn "The MongoDB database will be replaced by the one from the drive."
    confirm "Continue?" || exit 1

    local was_active=false
    if systemctl is-active --quiet "${name}"; then
        was_active=true
        info "Stopping ${name}"
        sudo systemctl stop "${name}"
    fi

    # Other containers (ros1/ros2) bind-mount folders of the repo. Replacing the
    # repo underneath a running one would leave it pointing at the old copy.
    local other stopped_others=()
    if "${want_repo}"; then
        for other in ros1 ros2; do
            [ "${other}" = "${name}" ] && continue
            if systemctl is-active --quiet "${other}" 2>/dev/null; then
                warn "${other} is running and uses this repo."
                confirm "Stop ${other} (saves it) and start it again afterwards?" \
                    || die "not continuing while ${other} is running"
                sudo systemctl stop "${other}"
                stopped_others+=("${other}")
            fi
        done
    fi

    # 1. Repo
    if "${want_repo}"; then
        info "Restoring repo"
        local tmp
        tmp="$(mktemp -d)"
        tar -xzf "${f_repo}" -C "${tmp}"
        [ -d "${tmp}/$(basename "${TARGET_REPO}")" ] || die "unexpected repo archive layout"
        if [ -e "${TARGET_REPO}" ]; then
            local backup
            backup="${TARGET_REPO}.old-$(date +%Y%m%d-%H%M%S)"
            sudo mv "${TARGET_REPO}" "${backup}"
            ok "previous repo kept as ${backup}"
        fi
        sudo mv "${tmp}/$(basename "${TARGET_REPO}")" "${TARGET_REPO}"
        sudo chown -R "$(id -u):$(id -g)" "${TARGET_REPO}"
        rm -rf "${tmp}"
        ok "repo restored to ${TARGET_REPO}"
        REPO="${TARGET_REPO}"
    fi

    # 2. Images
    if "${want_img}"; then
        info "Loading images"
        local old_latest old_base old
        old_latest="$(image_id "${name}:latest")"
        old_base="$(image_id "${name}:base")"
        zstd -dc --progress "${f_img}" | docker load
        for old in "${old_latest}" "${old_base}"; do
            if [ -n "${old}" ] && [ "${old}" != "$(image_id "${name}:latest")" ] \
               && [ "${old}" != "$(image_id "${name}:base")" ]; then
                docker image rm "${old}" >/dev/null 2>&1 || true
            fi
        done
        ok "images loaded"
    fi

    # Hook the (restored) repo into this PC: unit, `1`, folders, SELinux.
    if "${want_repo}" || ! systemctl cat "${name}" >/dev/null 2>&1; then
        [ -x "${REPO}/${name}/install.sh" ] \
            || die "no repo at ${REPO}; run the import again and restore the repo too"
        info "Running install.sh"
        (cd "${REPO}/${name}" && ./install.sh --enable)
    fi

    # 3. Start, then restore the database into the running MongoDB.
    if "${want_db}" || "${was_active}" || confirm "Start ${name} now?"; then
        "${want_db}" && ! "${was_active}" && info "Starting ${name} (needed for the database restore)"
        sudo systemctl start "${name}"
        ok "${name} started"
    fi
    if "${want_db}"; then
        info "Restoring MongoDB database"
        mongo_up || die "no ${MONGO_CONTAINER} container; is compose.mongo.yaml enabled in .env?"
        docker exec -i "${MONGO_CONTAINER}" mongorestore --port "${MONGO_PORT}" --archive --gzip --drop --quiet < "${f_db}"
        ok "database restored"
    fi

    for other in "${stopped_others[@]}"; do
        sudo systemctl start "${other}" && ok "${other} started again"
    done

    ok "import finished"
    eject_drive
}

"do_${action}"
