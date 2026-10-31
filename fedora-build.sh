#!/usr/bin/env bash
set -Eeuo pipefail

# iwlwifi-lar-patched build script for Fedora Linux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="${SCRIPT_DIR}/0001-iwlwifi-add-lar_disable.patch"
CACHE_DIR="${SCRIPT_DIR}/.cache"
BUILD_DIR="${SCRIPT_DIR}/build"

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

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -k, --kver <version>   Specify target kernel version (e.g. 7.2.5-200.fc44.x86_64)
  -a, --all              Build for all kernel versions with installed kernel-devel
  -h, --help             Show this help message

Default:
  Builds for the currently running kernel ($(uname -r))
EOF
}

TARGET_KERNELS=()
BUILD_ALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--kver)
            [[ -n "${2:-}" ]] || die "Missing kernel version for $1"
            TARGET_KERNELS+=("$2")
            shift 2
            ;;
        -a|--all)
            BUILD_ALL=true
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

if [[ "${BUILD_ALL}" == true ]]; then
    if [[ -d /usr/src/kernels ]]; then
        for kd in /usr/src/kernels/*; do
            if [[ -d "${kd}" ]]; then
                TARGET_KERNELS+=("$(basename "${kd}")")
            fi
        done
    fi
    [[ ${#TARGET_KERNELS[@]} -gt 0 ]] || die "No installed kernel headers found in /usr/src/kernels"
fi

if [[ ${#TARGET_KERNELS[@]} -eq 0 ]]; then
    CURRENT_KVER="$(uname -r)"
    TARGET_KERNELS+=("${CURRENT_KVER}")
    
    # Check if there are other newer kernels installed
    if [[ -d /usr/src/kernels ]]; then
        OTHER_KERNELS=()
        for kd in /usr/src/kernels/*; do
            k="$(basename "${kd}")"
            if [[ "${k}" != "${CURRENT_KVER}" && -d "${kd}" ]]; then
                OTHER_KERNELS+=("${k}")
            fi
        done
        if [[ ${#OTHER_KERNELS[@]} -gt 0 ]]; then
            info "Note: Other kernel-devel versions found: ${OTHER_KERNELS[*]}"
            info "Tip: Use '$0 --all' to build for all installed kernels."
        fi
    fi
fi

# Ensure patch file exists
[[ -f "${PATCH_FILE}" ]] || die "Patch file not found: ${PATCH_FILE}"

mkdir -p "${CACHE_DIR}" "${BUILD_DIR}"

get_base_ver() {
    local kver="$1"
    # Matches X.Y.Z or X.Y before any '-' or '.fc'
    echo "${kver}" | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/'
}

download_and_extract_iwlwifi() {
    local base_ver="$1"
    local major_ver
    major_ver="$(echo "${base_ver}" | cut -d. -f1)"
    local target_src_dir="${CACHE_DIR}/iwlwifi-src-${base_ver}"

    if [[ -d "${target_src_dir}" && -f "${target_src_dir}/iwl-drv.c" ]]; then
        info "Source for base kernel ${base_ver} is already cached at ${target_src_dir}"
        return 0
    fi

    local tarball="${CACHE_DIR}/linux-${base_ver}.tar.xz"
    local url="https://cdn.kernel.org/pub/linux/kernel/v${major_ver}.x/linux-${base_ver}.tar.xz"

    info "Downloading and extracting iwlwifi source for kernel ${base_ver}..."
    mkdir -p "${target_src_dir}"

    if [[ ! -f "${tarball}" ]]; then
        info "Streaming from: ${url}"
        if ! curl -f -L --progress-bar "${url}" | tar -xJ -C "${target_src_dir}" --strip-components=6 --wildcards "linux-${base_ver}/drivers/net/wireless/intel/iwlwifi/*"; then
            rm -rf "${target_src_dir}"
            die "Failed to download and extract iwlwifi source for kernel ${base_ver}"
        fi
    fi

    [[ -f "${target_src_dir}/iwl-drv.c" ]] || die "Extraction failed: iwl-drv.c not found in ${target_src_dir}"
    info "Source extracted successfully to ${target_src_dir}"
}

build_for_kernel() {
    local kver="$1"
    local builddir="/lib/modules/${kver}/build"
    local base_ver
    base_ver="$(get_base_ver "${kver}")"

    info "=========================================="
    info "Building for Fedora kernel: ${kver} (Base: ${base_ver})"
    info "=========================================="

    if [[ ! -d "${builddir}" ]]; then
        die "Kernel build directory not found: ${builddir}\nPlease install kernel-devel for this kernel: sudo dnf install kernel-devel-${kver}"
    fi

    download_and_extract_iwlwifi "${base_ver}"

    local kver_build_dir="${BUILD_DIR}/${kver}"
    local src_work_dir="${kver_build_dir}/src"

    rm -rf "${kver_build_dir}"
    mkdir -p "${src_work_dir}"

    info "Copying clean source to build directory..."
    cp -r "${CACHE_DIR}/iwlwifi-src-${base_ver}"/* "${src_work_dir}/"

    info "Applying LAR patch: $(basename "${PATCH_FILE}")..."
    cd "${src_work_dir}"
    patch -Np6 -i "${PATCH_FILE}" || die "Failed to apply patch to kernel ${kver} (${base_ver})"

    # Strip $(srctree)/ from Makefiles to allow building in-place
    [[ -f dvm/Makefile ]] && sed -i 's|\$(srctree)/||g' dvm/Makefile
    [[ -f mvm/Makefile ]] && sed -i 's|\$(srctree)/||g' mvm/Makefile
    [[ -f mld/Makefile ]] && sed -i 's|\$(srctree)/||g' mld/Makefile

    info "Compiling iwlwifi kernel modules..."
    export KBUILD_BUILD_USER='builder'
    export KBUILD_BUILD_HOST='fedora'
    export KBUILD_BUILD_VERSION='1'

    make -C "${builddir}" \
        M="${src_work_dir}" \
        KBUILD_BUILD_USER="${KBUILD_BUILD_USER}" \
        KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST}" \
        KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION}" \
        modules -j"$(nproc)"

    local out_modules_dir="${kver_build_dir}/modules"
    mkdir -p "${out_modules_dir}"

    info "Collecting compiled modules..."
    for mod in iwlwifi.ko mvm/iwlmvm.ko dvm/iwldvm.ko mld/iwlmld.ko; do
        if [[ -f "${src_work_dir}/${mod}" ]]; then
            local modname
            modname="$(basename "${mod}")"
            cp "${src_work_dir}/${mod}" "${out_modules_dir}/${modname}"
            strip --strip-debug "${out_modules_dir}/${modname}" || true
            info "  - Built: ${modname}"
        fi
    done

    [[ -f "${out_modules_dir}/iwlwifi.ko" ]] || die "Build failed: iwlwifi.ko not found!"

    # Save target kernel version
    echo "${kver}" > "${kver_build_dir}/kernel-version"
    info "Build for ${kver} completed successfully!"
    info "Output modules in: ${out_modules_dir}"
}

for k in "${TARGET_KERNELS[@]}"; do
    build_for_kernel "${k}"
done

echo ""
info "All builds finished successfully!"
info "Next step: Run 'sudo ./fedora-install.sh' to install the modules."
