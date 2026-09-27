#!/usr/bin/env bash
# sync.sh - move a ROS container image to or from an external drive.
#
#   ./sync.sh export [ros1]   save ros1:latest (+ ros1:base) to a drive
#   ./sync.sh import [ros1]   load an exported image from a drive
#
# Lists the external drives, recommends the best one, mounts it if needed
# (no sudo, like Dolphin does), and writes/reads
#   <drive>/ros-containers/<name>.tar.zst   (+ .sha256 checksum)
# Only the latest export is kept on the drive, matching the "latest only"
# image policy. Run on the host as your user (not inside the container).
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DRIVE_DIR=ros-containers

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31mfail\033[0m  %s\n' "$*" >&2; exit 1; }
human() { numfmt --to=iec --suffix=B "$1"; }
confirm() { local a; read -r -p "$1 [y/N] " a; [[ "${a}" =~ ^[Yy]$ ]]; }
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null || true; }

usage() { sed -n '2,12s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }

# --- arguments and checks ----------------------------------------------------
action="${1:-}"
name="${2:-ros1}"
case "${action}" in
    export|import) ;;
    -h|--help|"") usage; exit 0 ;;
    *) usage; exit 2 ;;
esac
[ -d "${REPO}/${name}" ] || die "unknown container '${name}' (no ${REPO}/${name} folder)"
[ -z "${CONTAINER_NAME:-}" ] || die "run this on the host, not inside the container"
[ "${EUID}" -ne 0 ] || die "run as your user, not root (sudo is used when needed)"
docker info >/dev/null 2>&1 || die "cannot talk to Docker (running? in the docker group?)"
for tool in zstd udisksctl lsblk numfmt; do
    command -v "${tool}" >/dev/null || die "'${tool}' is missing (sudo dnf install ${tool})"
done

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

# --- export --------------------------------------------------------------------
do_export() {
    [ -n "$(image_id "${name}:latest")" ] || die "image ${name}:latest not found"

    choose_drive
    mount_drive
    local dir="${MNT}/${DRIVE_DIR}"
    if ! mkdir -p "${dir}" 2>/dev/null; then
        sudo mkdir -p "${dir}"
        sudo chown "$(id -u):$(id -g)" "${dir}"
    fi
    touch "${dir}/.write-test" 2>/dev/null \
        || die "cannot write to ${dir} (read-only? NTFS drives mount read-only if Windows didn't shut down cleanly)"
    rm -f "${dir}/.write-test"

    if systemctl is-active --quiet "${name}"; then
        info "Saving the running ${name} container first"
        sudo systemctl reload "${name}"
    fi

    local tags=("${name}:latest")
    [ -n "$(image_id "${name}:base")" ] && tags+=("${name}:base")
    # Companion images (e.g. mongo:6.0), so a restore also works offline.
    # Their data (Docker volumes) is not included; back databases up separately.
    local img
    for img in $(cd "${REPO}/${name}" && docker compose config --images 2>/dev/null | sort -u); do
        case "${img}" in "${name}":*) continue ;; esac
        [ -n "$(image_id "${img}")" ] && tags+=("${img}")
    done

    local size avail
    size="$(docker image inspect -f '{{.Size}}' "${name}:latest")"
    avail="$(df -B1 --output=avail "${dir}" | tail -n1 | tr -d ' ')"
    info "Image size $(human "${size}") (compressed to roughly half); free on drive $(human "${avail}")"
    if [ "${avail}" -lt $((size * 6 / 10)) ]; then
        warn "the drive may not have enough free space"
        confirm "Try anyway?" || exit 1
    fi

    local out="${dir}/${name}.tar.zst"
    local part="${out}.partial"
    trap 'rm -f "${part}" "${part}.sha256"' EXIT
    info "Exporting ${tags[*]} -> ${out}"
    local start hash
    start=$(date +%s)
    hash="$(docker save "${tags[@]}" \
            | zstd -T0 -3 --progress -c \
            | tee "${part}" \
            | sha256sum | cut -d' ' -f1)"
    echo "${hash}  ${name}.tar.zst" > "${part}.sha256"
    sync -f "${part}"
    mv -f "${part}" "${out}"
    mv -f "${part}.sha256" "${out}.sha256"
    trap - EXIT
    ok "exported $(human "$(stat -c %s "${out}")") in $(( $(date +%s) - start ))s"
    ok "checksum written to ${out}.sha256"
    eject_drive
}

# --- import --------------------------------------------------------------------
do_import() {
    choose_drive
    mount_drive

    local files=()
    mapfile -t files < <(find "${MNT}" -maxdepth 3 -type f -name '*.tar.zst' 2>/dev/null | sort)
    [ "${#files[@]}" -gt 0 ] || die "no *.tar.zst image files found on ${MNT}"

    echo
    local i
    for i in "${!files[@]}"; do
        printf '  %-3s %-45s %8s  %s\n' "$((i + 1))" "${files[i]#"${MNT}"/}" \
            "$(human "$(stat -c %s "${files[i]}")")" "$(date -r "${files[i]}" '+%Y-%m-%d %H:%M')"
    done
    echo
    local choice
    read -r -p "Select file [1-${#files[@]}]: " choice
    [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#files[@]}" ] \
        || die "invalid choice"
    local file="${files[choice - 1]}"

    if [ -f "${file}.sha256" ]; then
        info "Verifying checksum (reads the whole file once)"
        local expected actual
        expected="$(cut -d' ' -f1 < "${file}.sha256")"
        actual="$(sha256sum "${file}" | cut -d' ' -f1)"
        [ "${expected}" = "${actual}" ] || die "checksum mismatch: the file is damaged, do not use it"
        ok "checksum matches"
    else
        warn "no checksum file next to it; cannot verify the file"
        confirm "Import anyway?" || exit 1
    fi

    echo
    warn "This replaces ${name}:latest on this PC with the imported image."
    warn "Anything in the current container that isn't in this export will be lost."
    confirm "Continue?" || exit 1

    local was_active=false
    if systemctl is-active --quiet "${name}"; then
        was_active=true
        info "Stopping ${name}"
        sudo systemctl stop "${name}"
    fi

    local old_latest old_base
    old_latest="$(image_id "${name}:latest")"
    old_base="$(image_id "${name}:base")"

    info "Loading image"
    zstd -dc --progress "${file}" | docker load

    # Drop the replaced images (ignored if still in use or unchanged).
    local old
    for old in "${old_latest}" "${old_base}"; do
        if [ -n "${old}" ] && [ "${old}" != "$(image_id "${name}:latest")" ] \
           && [ "${old}" != "$(image_id "${name}:base")" ]; then
            docker image rm "${old}" >/dev/null 2>&1 || true
        fi
    done
    ok "imported $(docker image inspect -f '{{len .RootFS.Layers}}' "${name}:latest") layers into ${name}:latest"

    if "${was_active}" || confirm "Start ${name} now?"; then
        sudo systemctl start "${name}"
        ok "${name} started"
    fi
    eject_drive
}

"do_${action}"
