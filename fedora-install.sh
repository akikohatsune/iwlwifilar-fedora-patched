#!/usr/bin/env bash
set -Eeuo pipefail

# iwlwifilar-fedora-patched install script for Fedora Linux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
MODPROBE_CONF="${SCRIPT_DIR}/iwlwifi-lar.conf"

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
  -k, --kver <version>   Specify target kernel version
  -a, --all              Install for all built kernel versions in build/
  -h, --help             Show this help message

Default:
  Installs for the currently running kernel ($(uname -r))
EOF
}

TARGET_KERNELS=()
INSTALL_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--kver)
            [[ -n "${2:-}" ]] || die "Missing kernel version for $1"
            TARGET_KERNELS+=("$2")
            shift 2
            ;;
        -a|--all)
            INSTALL_ALL=true
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

if [[ ${#TARGET_KERNELS[@]} -eq 0 ]]; then
    # By default, install for all built kernels found in build/, or fallback to uname -r
    for kd in "${BUILD_DIR}"/*; do
        if [[ -d "${kd}/modules" ]]; then
            TARGET_KERNELS+=("$(basename "${kd}")")
        fi
    done
    if [[ ${#TARGET_KERNELS[@]} -eq 0 ]]; then
        CURRENT_KVER="$(uname -r)"
        TARGET_KERNELS+=("${CURRENT_KVER}")
    fi
fi

check_secure_boot() {
    if command -v mokutil >/dev/null 2>&1; then
        if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
            return 0
        fi
    fi
    return 1
}

find_or_create_signing_keys() {
    PRIV_KEY=""
    PUB_KEY=""

    # 1. Custom / manual keys
    if [[ -n "${CUSTOM_PRIV_KEY:-}" && -n "${CUSTOM_PUB_KEY:-}" && -f "${CUSTOM_PRIV_KEY}" && -f "${CUSTOM_PUB_KEY}" ]]; then
        PRIV_KEY="${CUSTOM_PRIV_KEY}"
        PUB_KEY="${CUSTOM_PUB_KEY}"
        return 0
    fi

    # 2. akmods default keys
    if [[ -f /etc/pki/akmods/private/private_key.priv && -f /etc/pki/akmods/certs/public_key.der ]]; then
        PRIV_KEY="/etc/pki/akmods/private/private_key.priv"
        PUB_KEY="/etc/pki/akmods/certs/public_key.der"
        return 0
    fi

    # 3. /etc/pki/MOK keys
    if [[ -f /etc/pki/MOK/MOK.priv && -f /etc/pki/MOK/MOK.der ]]; then
        PRIV_KEY="/etc/pki/MOK/MOK.priv"
        PUB_KEY="/etc/pki/MOK/MOK.der"
        return 0
    fi

    # 4. Try generating with kmodgenca if available
    if command -v kmodgenca >/dev/null 2>&1; then
        info "Secure Boot is enabled, but no signing key was found."
        info "Generating MOK key pair with kmodgenca..."
        kmodgenca -a || warn "kmodgenca failed"
        if [[ -f /etc/pki/akmods/private/private_key.priv && -f /etc/pki/akmods/certs/public_key.der ]]; then
            PRIV_KEY="/etc/pki/akmods/private/private_key.priv"
            PUB_KEY="/etc/pki/akmods/certs/public_key.der"
            return 0
        fi
    fi

    return 1
}

sign_module() {
    local kver="$1"
    local modfile="$2"
    local sign_file="/lib/modules/${kver}/build/scripts/sign-file"

    [[ -x "${sign_file}" ]] || sign_file="$(find "/usr/src/kernels/${kver}/scripts" -name sign-file -executable 2>/dev/null | head -n 1)"

    if [[ -z "${sign_file}" || ! -x "${sign_file}" ]]; then
        warn "scripts/sign-file not found for ${kver}; skipping module signing."
        return 0
    fi

    info "  Signing $(basename "${modfile}") with MOK key..."
    "${sign_file}" sha256 "${PRIV_KEY}" "${PUB_KEY}" "${modfile}"
}

NEED_MOK_ENROLL_REMINDER=false

install_for_kernel() {
    local kver="$1"
    local mod_src_dir="${BUILD_DIR}/${kver}/modules"
    local mod_dst_dir="/usr/lib/modules/${kver}/updates/iwlwifilar-fedora-patched"

    # Remove any old directory from previous naming
    rm -rf "/usr/lib/modules/${kver}/updates/iwlwifi-lar-patched"

    info "=========================================="
    info "Installing for Fedora kernel: ${kver}"
    info "=========================================="

    if [[ ! -d "${mod_src_dir}" || ! -f "${mod_src_dir}/iwlwifi.ko" ]]; then
        die "Built modules for ${kver} not found in ${mod_src_dir}.\nPlease run './fedora-build.sh -k ${kver}' first."
    fi

    local is_sb=false
    if check_secure_boot; then
        is_sb=true
        info "Secure Boot is ENABLED on this machine."
        if find_or_create_signing_keys; then
            info "Using signing key: ${PUB_KEY}"
            # Check if this public cert is enrolled in MOK
            if command -v mokutil >/dev/null 2>&1; then
                if mokutil --test-key "${PUB_KEY}" 2>&1 | grep -qi "already enrolled"; then
                    info "MOK key is already enrolled in UEFI."
                else
                    info "MOK key enrollment test did not confirm existing key."
                    local import_out
                    import_out="$(mokutil --import "${PUB_KEY}" 2>&1 || true)"
                    if echo "${import_out}" | grep -qi "already enrolled"; then
                        info "MOK key is already enrolled in UEFI (skipped import)."
                    else
                        echo "${import_out}"
                        NEED_MOK_ENROLL_REMINDER=true
                    fi
                fi
            fi
        else
            warn "No MOK key found or could not generate one!"
            warn "Kernel may block loading un-signed iwlwifi module under Secure Boot."
        fi
    fi

    # Create destination directory
    mkdir -p "${mod_dst_dir}"

    # Sign (if applicable) and compress modules
    for mod in "${mod_src_dir}"/*.ko; do
        [[ -f "${mod}" ]] || continue
        local modname
        modname="$(basename "${mod}")"
        local stage_mod="/tmp/${modname}"

        cp "${mod}" "${stage_mod}"
        if [[ "${is_sb}" == true && -n "${PRIV_KEY:-}" ]]; then
            sign_module "${kver}" "${stage_mod}"
        fi

        info "  Compressing ${modname} -> ${modname}.xz (xz --check=crc32)..."
        xz -f --check=crc32 "${stage_mod}"

        info "  Installing ${modname}.xz to ${mod_dst_dir}/"
        install -m644 "${stage_mod}.xz" "${mod_dst_dir}/${modname}.xz"
        rm -f "${stage_mod}.xz"
    done

    # Install modprobe config
    info "Installing modprobe configuration to /etc/modprobe.d/iwlwifi-lar.conf..."
    install -Dm644 "${MODPROBE_CONF}" /etc/modprobe.d/iwlwifi-lar.conf

    # Install modules-load config to ensure driver is auto-loaded on boot
    info "Installing modules-load configuration to /etc/modules-load.d/iwlwifi-lar.conf..."
    cat > /etc/modules-load.d/iwlwifi-lar.conf <<EOF
iwlwifi
iwlmvm
EOF

    # Clean up any legacy dracut omit_drivers config that prevents boot-time loading
    rm -f /etc/dracut.conf.d/iwlwifi-lar.conf

    # Run depmod
    info "Updating module dependencies (depmod -a ${kver})..."
    depmod -a "${kver}"

    # Rebuild initramfs with dracut
    if command -v dracut >/dev/null 2>&1; then
        info "Rebuilding initramfs with dracut for ${kver}..."
        dracut --force --kver "${kver}" || warn "dracut failed, please run manually."
    elif [[ -x /usr/bin/kernel-install && -f "/usr/lib/modules/${kver}/vmlinuz" ]]; then
        info "Refreshing kernel-install artifacts for ${kver}..."
        kernel-install add "${kver}" "/usr/lib/modules/${kver}/vmlinuz" || warn "kernel-install failed."
    fi

    info "Installation for ${kver} finished successfully!"
}

for k in "${TARGET_KERNELS[@]}"; do
    install_for_kernel "${k}"
done

echo ""
info "================================================================"
info " iwlwifilar-fedora-patched is installed successfully on Fedora!"
info "================================================================"

if [[ "${NEED_MOK_ENROLL_REMINDER}" == true ]]; then
    echo ""
    echo " [!] IMPORTANT NOTICE FOR SECURE BOOT:"
    echo "     A MOK key import has been requested."
    echo "     When you reboot, the blue 'Shim / MOK Management' screen will appear:"
    echo "       1. Select 'Enroll MOK'"
    echo "       2. Select 'Continue' -> 'Yes'"
    echo "       3. Enter the password you created during this installation"
    echo "       4. Select 'Reboot'"
    echo ""
fi

echo "Recommended next steps:"
echo "  1. Reboot your system: sudo reboot"
echo "  2. After reboot, check if lar_disable is active:"
echo "       cat /sys/module/iwlwifi/parameters/lar_disable"
echo "       (Should return: Y or 1)"
echo "  3. Set your desired Wi-Fi regulatory domain manually:"
echo "       sudo iw reg set US"
echo "       iw reg get"
echo ""

