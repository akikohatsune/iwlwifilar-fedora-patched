#!/usr/bin/env bash
# /etc/kernel/install.d/40-iwlwifi-lar.install
#
# Hook for kernel-install: automatically builds and installs iwlwifi-lar-patched
# whenever a new kernel is installed on Fedora.
#
# To enable:
#   sudo ln -sf /path/to/iwlwifi-lar-patched/scripts/kernel-install-hook.sh /etc/kernel/install.d/40-iwlwifi-lar.install

COMMAND="${1:-}"
KERNEL_VERSION="${2:-}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${COMMAND}" in
    add)
        if [[ -x "${REPO_DIR}/fedora-build.sh" && -x "${REPO_DIR}/fedora-install.sh" ]]; then
            echo "==> [kernel-install] Rebuilding iwlwifi-lar-patched for ${KERNEL_VERSION}..."
            "${REPO_DIR}/fedora-build.sh" -k "${KERNEL_VERSION}"
            "${REPO_DIR}/fedora-install.sh" -k "${KERNEL_VERSION}"
        fi
        ;;
    remove)
        if [[ -x "${REPO_DIR}/fedora-uninstall.sh" ]]; then
            echo "==> [kernel-install] Removing iwlwifi-lar-patched for ${KERNEL_VERSION}..."
            "${REPO_DIR}/fedora-uninstall.sh" -k "${KERNEL_VERSION}"
        fi
        ;;
    *)
        ;;
esac

