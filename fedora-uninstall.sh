#!/usr/bin/env bash
set -Eeuo pipefail

# iwlwifilar-fedora-patched uninstall script for Fedora Linux

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

info() {
    echo "==> $*"
}

if [[ ${EUID} -ne 0 ]]; then
    die "This script must be run as root (e.g. 'sudo $0')"
fi

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -k, --kver <version>   Specify target kernel version to remove
  -a, --all              Remove for all kernel versions
  -h, --help             Show this help message

Default:
  Removes for the currently running kernel ($(uname -r))
EOF
}

TARGET_KERNELS=()
UNINSTALL_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--kver)
            [[ -n "${2:-}" ]] || die "Missing kernel version for $1"
            TARGET_KERNELS+=("$2")
            shift 2
            ;;
        -a|--all)
            UNINSTALL_ALL=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

if [[ "${UNINSTALL_ALL}" == true ]]; then
    for kd in /usr/lib/modules/*; do
        if [[ -d "${kd}/updates/iwlwifilar-fedora-patched" ]]; then
            TARGET_KERNELS+=("$(basename "${kd}")")
        fi
    done
    [[ ${#TARGET_KERNELS[@]} -gt 0 ]] || info "No iwlwifilar-fedora-patched installations found."
fi

if [[ ${#TARGET_KERNELS[@]} -eq 0 ]]; then
    CURRENT_KVER="$(uname -r)"
    TARGET_KERNELS+=("${CURRENT_KVER}")
fi

for kver in "${TARGET_KERNELS[@]}"; do
    for dir_name in iwlwifilar-fedora-patched iwlwifi-lar-patched; do
        mod_dir="/usr/lib/modules/${kver}/updates/${dir_name}"
        if [[ -d "${mod_dir}" ]]; then
            info "Removing patched modules from ${mod_dir}..."
            rm -rf "${mod_dir}"
        fi
    done
    rmdir "/usr/lib/modules/${kver}/updates" 2>/dev/null || true

    info "Updating module dependencies (depmod -a ${kver})..."
    depmod -a "${kver}"

    if command -v dracut >/dev/null 2>&1; then
        info "Rebuilding initramfs with dracut for ${kver}..."
        dracut --force --kver "${kver}" || warn "dracut failed."
    fi
done

# Check if any remaining kernels still have iwlwifilar-fedora-patched
REMAINING_PATCHED=$(find /usr/lib/modules/*/updates/iwlwifilar-fedora-patched -maxdepth 0 2>/dev/null || true)
if [[ -z "${REMAINING_PATCHED}" ]]; then
    info "Removing configuration files..."
    rm -f /etc/modprobe.d/iwlwifi-lar.conf
    rm -f /etc/dracut.conf.d/iwlwifi-lar.conf
    rm -f /etc/modules-load.d/iwlwifi-lar.conf
fi

echo ""
info "iwlwifilar-fedora-patched has been removed. Original in-tree kernel drivers are restored."
info "Reboot is recommended: sudo reboot"

