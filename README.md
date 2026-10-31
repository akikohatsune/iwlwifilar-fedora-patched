# iwlwifilar-fedora-patched for Fedora

Patched Intel **iwlwifi** driver modules with **LAR (Location Aware Regulatory) disabled** for Fedora Linux.

This package allows manual control of your Wi-Fi regulatory domain (`iw reg set`), unlocking additional Wi-Fi channels (2.4GHz channels 12-14, 5GHz, 6GHz) and higher transmission power (up to 30 dBm).

---

## Features

- Disables Intel LAR restrictions via `lar_disable=1` parameter.
- Automatically downloads and extracts matching kernel driver sources from `kernel.org`.
- Full **Fedora Secure Boot** support (automatic module signing with MOK / `akmods`).
- Kernel-compatible CRC32 XZ module compression.
- Automatically loads on boot via `/etc/modules-load.d/`.

---

## Disclaimer

- Bypassing regulatory domain restrictions may violate local radio regulations in your country.
- Use at your own risk.

---

## Prerequisites

Install the required build tools and kernel headers on Fedora:

```bash
sudo dnf install -y kernel-devel kernel-headers gcc make patch xz bc kmod
```

---

## Build and Install

### 1. Build

Build for your currently running kernel:

```bash
make
```

*(Optional: Run `make build-all` to build for all installed kernels).*

### 2. Install

Install the modules:

```bash
sudo make install
```

#### Secure Boot Notice:
If Secure Boot is enabled on your machine:
1. The install script will automatically sign the modules with a MOK key.
2. If this is your first time, you will be prompted to set a temporary password for `mokutil`.
3. Reboot your system:
   ```bash
   sudo reboot
   ```
4. On the blue **Shim / MOKManager** screen after reboot:
   - Select **Enroll MOK** -> **Continue** -> **Yes**
   - Enter your password
   - Select **Reboot**

---

## Verification

After booting into your system:

1. Check if LAR is disabled:
   ```bash
   cat /sys/module/iwlwifi/parameters/lar_disable
   ```
   *(Should return `Y`)*

2. Set your desired regulatory domain:
   ```bash
   sudo iw reg set US
   ```

3. Verify:
   ```bash
   iw reg get
   ```

---

## Automatic Rebuild on Kernel Updates (Optional)

To automatically rebuild and install this driver whenever Fedora updates your kernel via `dnf`:

```bash
sudo ln -sf "$(pwd)/scripts/kernel-install-hook.sh" /etc/kernel/install.d/40-iwlwifi-lar.install
```

---

## Uninstall

To remove the patched driver and restore Fedora's default in-tree driver:

```bash
sudo make uninstall
```

Then reboot.

---

## License

GPL-2.0
