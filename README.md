# Apple Recovery App for Linux (idevicerestore-setup)

[![CI](https://github.com/huseyinTozluyurt/AppleRecoveryAppIntegrationLinux/actions/workflows/ci.yml/badge.svg)](https://github.com/huseyinTozluyurt/AppleRecoveryAppIntegrationLinux/actions/workflows/ci.yml)

A setup and diagnostic tool that prepares any Linux machine to restore iPhones,
iPads and iPods with [idevicerestore](https://github.com/libimobiledevice/idevicerestore),
and explains what went wrong when a restore fails, especially:

```
ERROR: Unable to get SHSH blobs for this device
```

It turns the manual Ubuntu procedure (purge old APT packages, install build tools,
build the libimobiledevice stack from source in the right order, restart usbmuxd,
restore) into one command, and adds checks for the problems that usually stop a
fresh machine.

> This tool restores devices you own using firmware Apple is currently signing.
> It does not and cannot bypass firmware signing or Activation Lock.

## Quick start

One line (downloads this repo and runs the installer):

```bash
curl -fsSL https://raw.githubusercontent.com/huseyinTozluyurt/AppleRecoveryAppIntegrationLinux/main/get.sh | bash
```

Or step by step:

```bash
git clone https://github.com/huseyinTozluyurt/AppleRecoveryAppIntegrationLinux.git
cd AppleRecoveryAppIntegrationLinux
sudo ./install.sh            # asks before removing old distro packages
idr-doctor                   # check everything with the device plugged in
sudo idr-doctor restore -- -e -l                       # erase + latest signed iOS
sudo idr-doctor restore -- -e ./iPhone12,1_27.2_24B119_Restore.ipsw   # or a downloaded IPSW
idr-doctor clean --ipsw      # delete the IPSW and extracted folders afterwards
```

Prefer a window? Install with `sudo ./install.sh --with-gui` and run `idr-gui`
(or "iDevice Restore Doctor" from the app menu).

## What `install.sh` does

| Step | Details |
|---|---|
| Detect distro | Package manager, init system and CPU architecture (see the table below) |
| Remove conflicts | Offers to purge `libimobiledevice6 libimobiledevice-utils idevicerestore usbmuxd libusbmuxd6 libusbmuxd-dev libirecovery3` (the old versions that cause TSS status 94). Use `--remove-distro-packages` to skip the question |
| Build deps | compiler, autotools, pkg-config, OpenSSL, libcurl, libzip, zlib, libusb, readline, udev/systemd headers |
| Build from source | `libplist → libimobiledevice-glue → libtatsu → libusbmuxd → libimobiledevice → libirecovery → usbmuxd → idevicerestore` into `/usr/local`, with `PKG_CONFIG_PATH` and `ldconfig` handled for you (including lib64 distros) |
| udev + usbmuxd | Installs rules for normal, Recovery and DFU mode to `/etc/udev/rules.d`, creates the `usbmux` user, installs and enables the systemd service |
| Tools | Installs `idr-doctor` and `idr-gui` |

Options: `--yes`, `--prefix DIR`, `--src-dir DIR`, `--jobs N`, `--skip-deps`,
`--skip-build`, `--remove-distro-packages`, `--with-gui`, `--uninstall`.
The full build log is written to `/var/log/idevicerestore-setup.log`.
Re-running the installer updates everything to the latest upstream source.

On desktops, removing `libimobiledevice6` can also remove `gvfs-backends`
(iPhone access in the file manager). Reinstall it later if you need it.

## Supported distributions

| Family | Tested in CI | Also detected (via `ID_LIKE`) |
|---|---|---|
| Debian / Ubuntu (apt) | Ubuntu 22.04 and 24.04, Debian 12 and 13, Linux Mint 22, Kali, Debian 12 on ARM64 | Pop!_OS, elementary, Zorin, Raspberry Pi OS, MX, Deepin, Devuan |
| Red Hat (dnf/yum) | Fedora, Rocky Linux 9, AlmaLinux 8 | RHEL, CentOS Stream, Oracle Linux, Nobara. CRB/PowerTools and EPEL are enabled for you |
| Arch (pacman) | Arch Linux | Manjaro, EndeavourOS, Garuda, CachyOS, Artix (eudev) |
| SUSE (zypper) | openSUSE Tumbleweed, Leap 15.6 | SLES |
| Alpine (apk) | Alpine | postmarketOS. Needs `apk add bash` first |
| Void (xbps) | Void glibc | Void musl |
| Gentoo (emerge) | Gentoo (best effort) | Funtoo |
| Solus (eopkg) | not in CI (best effort) | |

**Init systems.** The installer works with systemd, OpenRC (where it installs `/etc/init.d/usbmuxd`), runit (`/etc/sv/usbmuxd`), and sysvinit. Without systemd, udev starts usbmuxd when a device is plugged in.

**CPU.** Everything is built from source, so ARM64 boards such as the Raspberry Pi 4/5 work as well as x86_64.

**Not supported by the installer.** On these systems it stops and explains what to do instead:
- NixOS: use `services.usbmuxd.enable` and the nixpkgs packages.
- Fedora Silverblue and other image-based systems: use `rpm-ostree install` or a distrobox.
- SteamOS: `/usr` is read-only.

Any other distro can still use the installer: install the build dependencies yourself, then run `sudo ./install.sh --skip-deps`.

## What `idr-doctor` checks

| Area | Checks |
|---|---|
| Toolchain | idevicerestore present, which copy runs, duplicates on PATH, linked against libtatsu, unresolved libraries, all library versions |
| usbmuxd / udev | daemon running, socket present, udev rules installed |
| Device | Apple device on USB, its mode (Normal / Recovery / DFU), USB speed, model, iOS version, ECID, pairing problems |
| Network | proxy settings and the `sudo` proxy trap, `/etc/hosts` redirects of `gs.apple.com`, DNS for all three TSS hostnames, TCP reachability, a live request to Apple's TSS server, clock skew, access to Apple's firmware list |
| Signing | which iOS versions Apple signs right now for the device (via api.ipsw.me), and whether your IPSW is one of them and is meant for your model |

Other commands: `idr-doctor network`, `device`, `signed iPhone12,1`,
`ipsw FILE`, `explain LOG`, `restore -- ARGS`, `clean`.
`idr-doctor restore` saves every run to `~/idevicerestore-logs/` and explains a failure automatically.

## Why "Unable to get SHSH blobs for this device" happens

Before writing firmware, idevicerestore sends the device's ECID and the firmware's
hashes to Apple's TSS server (`gs.apple.com`). Apple returns a signed ticket (the
"SHSH blob") only for firmware it is still signing, for that exact device. The
error means no ticket came back. In practice the causes are:

1. **The firmware is no longer signed.** Apple stops signing older iOS versions
   soon after a new release. TSS answers status 94 ("This device isn't eligible
   for the requested build"). Fix: `sudo idevicerestore -e -l` to use the latest
   signed version. Downgrading to an unsigned version is not possible.
2. **Outdated distro build.** APT's idevicerestore and libimobiledevice are years
   old and predate libtatsu, so they build requests Apple rejects for newer
   devices (also status 94, or 100/126). Fix: `sudo ./install.sh --remove-distro-packages`.
3. **No network path to Apple.** Firewalls, VPNs, DNS ad-blockers, captive portals,
   or a proxy that `sudo` drops. Fix: allow `gs.apple.com`, or use `sudo -E`.
4. **`/etc/hosts` redirect.** Old jailbreak/SHSH tools pointed `gs.apple.com` at
   third-party servers. Fix: remove the line.
5. **Wrong IPSW for the model.** Fix: download the IPSW for the exact model
   identifier `idr-doctor` shows (e.g. `iPhone12,1`).

After a restore, a device that had Find My enabled asks for the owner's Apple ID
(Activation Lock). That is expected and is not something this tool touches.

## Updating

```bash
cd AppleRecoveryAppIntegrationLinux && git pull && sudo ./install.sh --update
```

This also rebuilds the libimobiledevice stack from the latest upstream source,
which is what new iPhone models and iOS releases usually need.

## Contributing

Issues and pull requests are welcome. If a restore fails, please attach the
output of `idr-doctor` and the log from `~/idevicerestore-logs/`
(remove your ECID and serial number first). The CI builds the full stack on
Ubuntu 22.04/24.04, Debian 12, Fedora, Arch and openSUSE every week.

## Uninstall

```bash
sudo ./install.sh --uninstall
```

## License

MIT for the scripts in this repository. The libimobiledevice projects it builds
are licensed separately (LGPL-2.1 / GPL-3.0); see their repositories.
