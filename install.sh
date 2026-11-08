#!/usr/bin/env bash
# idevicerestore-setup installer
#
# Installs and configures everything idevicerestore needs on a Linux machine:
#   - build dependencies from the distro's package manager
#   - libplist, libimobiledevice-glue, libtatsu, libusbmuxd, libimobiledevice,
#     libirecovery, usbmuxd and idevicerestore built from current upstream source
#   - udev rules for normal, Recovery and DFU mode devices
#   - the usbmuxd system user and systemd service
#   - the idr-doctor diagnostic CLI (and optional idr-gui)
#
# Supported package managers / families (derivatives are detected via ID_LIKE):
#   apt     Debian, Ubuntu, Linux Mint, Pop!_OS, elementary, Zorin, Kali,
#           Raspberry Pi OS, Deepin, MX Linux
#   dnf/yum Fedora, RHEL, Rocky, AlmaLinux, CentOS Stream, Oracle Linux, Nobara
#   pacman  Arch, Manjaro, EndeavourOS, Garuda, CachyOS
#   zypper  openSUSE Tumbleweed / Leap, SLES
#   apk     Alpine, postmarketOS
#   xbps    Void Linux (glibc and musl)
#   emerge  Gentoo, Funtoo
#   eopkg   Solus
# Init systems: systemd, OpenRC, runit, or none (usbmuxd is then started by udev).
# CPU: any architecture the distro supports (x86_64, aarch64/Raspberry Pi, armv7, ...).
#
# Why build from source? Distro packages of idevicerestore are usually years
# old. An old build does not know the newest devices and firmware formats and
# commonly fails with "ERROR: Unable to get SHSH blobs for this device".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="/usr/local"
SRC_DIR="/usr/local/src/idevicerestore-setup"
JOBS="$(nproc 2>/dev/null || echo 2)"
ASSUME_YES=0
SKIP_DEPS=0
SKIP_BUILD=0
REMOVE_DISTRO=0
WITH_GUI=0
UNINSTALL=0
LOG_FILE="/var/log/idevicerestore-setup.log"

# Build order matters: each project depends on the ones before it.
REPOS=(
  libplist
  libimobiledevice-glue
  libtatsu
  libusbmuxd
  libimobiledevice
  libirecovery
  usbmuxd
  idevicerestore
)
GIT_BASE="https://github.com/libimobiledevice"

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_blu=$'\e[34m'; c_off=$'\e[0m'
[[ -t 1 ]] || { c_red=; c_grn=; c_yel=; c_blu=; c_off=; }
info() { echo "${c_blu}==>${c_off} $*"; }
ok()   { echo "${c_grn} ok${c_off} $*"; }
warn() { echo "${c_yel}warn${c_off} $*" >&2; }
die()  { printf "%b\n" "${c_red}error${c_off} $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: sudo ./install.sh [options]

Options:
  -y, --yes               Do not ask for confirmation
  --prefix DIR            Install prefix (default: $PREFIX)
  --src-dir DIR           Where sources are cloned/built (default: $SRC_DIR)
  --jobs N                Parallel make jobs (default: $JOBS)
  --skip-deps             Do not install distro build dependencies
  --skip-build            Only (re)install udev rules, service and tools
  --remove-distro-packages
                          Remove old distro packages (idevicerestore, usbmuxd,
                          libimobiledevice-utils, libirecovery-utils) that can
                          shadow or conflict with the fresh build
  --with-gui              Also install the Tk dependency for idr-gui
  --update                Pull the latest upstream sources and rebuild (same as a re-run)
  --uninstall             Remove what this script installed
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    --prefix) PREFIX="$2"; shift ;;
    --src-dir) SRC_DIR="$2"; shift ;;
    --jobs) JOBS="$2"; shift ;;
    --skip-deps) SKIP_DEPS=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --remove-distro-packages) REMOVE_DISTRO=1 ;;
    --with-gui) WITH_GUI=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --update) ASSUME_YES=1; SKIP_DEPS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Please run as root: sudo $0 $*"

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  read -r -p "$1 [y/N] " a
  [[ "$a" =~ ^[Yy]$ ]]
}


# ---------------------------------------------------------------- distro ----
detect_distro() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  local ids=" ${ID:-} ${ID_LIKE:-} "
  DISTRO_NAME="${PRETTY_NAME:-${ID:-unknown}}"
  DISTRO_ID="${ID:-}"
  VERSION_MAJOR="${VERSION_ID:-}"; VERSION_MAJOR="${VERSION_MAJOR%%.*}"

  check_immutable "$ids"

  if   [[ "$ids" =~ \ (debian|ubuntu|raspbian|linuxmint|pop|kali)\  ]] && command -v apt-get >/dev/null; then PM=apt
  elif [[ "$ids" =~ \ (fedora|rhel|centos|rocky|almalinux|ol|nobara|amzn)\  ]]; then
    if command -v dnf >/dev/null; then PM=dnf; elif command -v yum >/dev/null; then PM=yum; else PM=""; fi
  elif [[ "$ids" =~ \ (arch|manjaro|endeavouros|garuda|cachyos)\  ]] && command -v pacman >/dev/null; then PM=pacman
  elif [[ "$ids" =~ \ (suse|opensuse|opensuse-tumbleweed|opensuse-leap|sles)\  ]] && command -v zypper >/dev/null; then PM=zypper
  elif [[ "$ids" =~ \ (alpine|postmarketos)\  ]] && command -v apk >/dev/null; then PM=apk
  elif [[ "$ids" =~ \ void\  ]] && command -v xbps-install >/dev/null; then PM=xbps
  elif [[ "$ids" =~ \ (gentoo|funtoo)\  ]] && command -v emerge >/dev/null; then PM=emerge
  elif [[ "$ids" =~ \ solus\  ]] && command -v eopkg >/dev/null; then PM=eopkg
  else PM=""
  fi
  # Fall back to whatever package manager exists.
  if [[ -z "$PM" ]]; then
    for c in apt-get:apt dnf:dnf yum:yum pacman:pacman zypper:zypper apk:apk xbps-install:xbps emerge:emerge eopkg:eopkg; do
      if command -v "${c%%:*}" >/dev/null; then PM="${c##*:}"; break; fi
    done
  fi
  if [[ -z "$PM" ]]; then
    if [[ $SKIP_DEPS -eq 1 ]]; then PM=none; else
    die "Unsupported distribution: $DISTRO_NAME.
Install these build dependencies yourself (names vary by distro): a C compiler, make, git,
autoconf, automake, libtool, pkg-config, OpenSSL, libcurl, libzip, zlib, libusb-1.0,
readline and udev development headers. Then re-run: sudo ./install.sh --skip-deps"
    fi
  fi
  INIT=none
  if [[ -d /run/systemd/system ]]; then INIT=systemd
  elif command -v openrc-run >/dev/null || [[ -x /sbin/openrc-run ]]; then INIT=openrc
  elif [[ -d /etc/runit ]] || command -v runsvdir >/dev/null; then INIT=runit
  fi
}

check_immutable() {
  local ids="$1"
  if [[ "$ids" =~ \ nixos\  ]]; then
    die "NixOS is not supported by this installer (it does not use /usr/local or ld.so.conf).
Use the packaged versions instead, for example in configuration.nix:
  services.usbmuxd.enable = true;
  environment.systemPackages = with pkgs; [ idevicerestore libimobiledevice libirecovery ];
then run idr-doctor from this folder: python3 bin/idr-doctor"
  fi
  if command -v rpm-ostree >/dev/null && [[ -e /run/ostree-booted ]]; then
    die "This is an image-based system (Fedora Silverblue/Kinoite/Bazzite/uBlue) where /usr is read-only.
Options:
  1) Layer the packaged tools: rpm-ostree install idevicerestore usbmuxd   (then reboot)
  2) Or run this installer inside a toolbox/distrobox container that has USB access,
     and keep usbmuxd running on the host."
  fi
  if [[ "$ids" =~ \ steamos\  ]] && [[ ! -w /usr ]]; then
    die "SteamOS has a read-only /usr. Disable it first with 'sudo steamos-readonly disable'
(changes are lost on updates), or use distrobox."
  fi
}

run_ldconfig() { command -v ldconfig >/dev/null && ldconfig 2>/dev/null; return 0; }

enable_rhel_repos() {
  # libzip-devel, libusb1-devel and readline-devel live in CRB (EL9+) / PowerTools (EL8).
  [[ "$DISTRO_ID" == "fedora" || "$DISTRO_ID" == "nobara" || "$DISTRO_ID" == "amzn" ]] && return 0
  info "Enabling CRB/PowerTools and EPEL for $DISTRO_NAME"
  $PM install -y dnf-plugins-core epel-release >/dev/null 2>&1 || true
  if command -v crb >/dev/null; then crb enable >/dev/null 2>&1 || true; fi
  dnf config-manager --set-enabled crb >/dev/null 2>&1 \
    || dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
    || dnf config-manager --set-enabled ol"${VERSION_MAJOR}"_codeready_builder >/dev/null 2>&1 \
    || subscription-manager repos --enable "codeready-builder-for-rhel-${VERSION_MAJOR}-$(uname -m)-rpms" >/dev/null 2>&1 \
    || warn "Could not enable the CRB repository; some -devel packages may be missing"
}

install_deps() {
  info "Installing build dependencies with $PM"
  case "$PM" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      local pkgs=(build-essential git autoconf automake libtool libtool-bin pkg-config
                  libssl-dev libcurl4-openssl-dev libzip-dev zlib1g-dev libusb-1.0-0-dev
                  libreadline-dev udev usbutils python3 ca-certificates curl)
      # systemd-dev ships the pkg-config file for unit dirs on newer releases.
      apt-cache show systemd-dev >/dev/null 2>&1 && pkgs+=(systemd-dev)
      apt-cache show libudev-dev >/dev/null 2>&1 && pkgs+=(libudev-dev)
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(python3-tk)
      apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    dnf|yum)
      enable_rhel_repos
      local pkgs=(gcc gcc-c++ make git autoconf automake libtool pkgconfig
                  openssl-devel libcurl-devel libzip-devel zlib-devel libusb1-devel
                  readline-devel systemd-devel usbutils python3 ca-certificates shadow-utils
                  findutils diffutils which)
      # Minimal images ship curl-minimal, which conflicts with the full curl package.
      rpm -q curl-minimal >/dev/null 2>&1 || pkgs+=(curl)
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(python3-tkinter)
      $PM install -y "${pkgs[@]}"
      ;;
    pacman)
      local pkgs=(base-devel git autoconf automake libtool pkgconf openssl curl libzip
                  zlib libusb readline usbutils python ca-certificates)
      # Artix and other systemd-free Arch derivatives ship udev separately.
      if [[ "$INIT" == "openrc" || "$INIT" == "runit" ]]; then
        pkgs+=(eudev)
      else
        pkgs+=(systemd)
      fi
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(tk)
      pacman -Syu --needed --noconfirm "${pkgs[@]}"
      ;;
    zypper)
      local pkgs=(gcc gcc-c++ make git autoconf automake libtool pkg-config
                  libopenssl-devel libcurl-devel libzip-devel zlib-devel libusb-1_0-devel
                  readline-devel systemd-devel usbutils python3 ca-certificates curl shadow
                  which findutils gawk tar gzip)
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(python3-tk)
      zypper --non-interactive --gpg-auto-import-keys refresh
      # --force-resolution lets zypper pick a matching -devel/library pair instead of stopping.
      zypper --non-interactive install --no-recommends --force-resolution "${pkgs[@]}"
      ;;
    apk)
      local pkgs=(build-base git autoconf automake libtool pkgconf linux-headers
                  openssl-dev curl-dev libzip-dev zlib-dev libusb-dev readline-dev
                  eudev eudev-dev usbutils python3 ca-certificates curl shadow bash)
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(py3-tkinter)
      apk add --no-cache "${pkgs[@]}"
      ;;
    xbps)
      xbps-install -Syu xbps >/dev/null 2>&1 || true
      local pkgs=(base-devel git autoconf automake libtool pkg-config
                  openssl-devel libcurl-devel libzip-devel zlib-devel libusb-devel
                  readline-devel eudev-libudev-devel usbutils python3 ca-certificates curl shadow)
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(python3-tkinter)
      xbps-install -Sy "${pkgs[@]}"
      ;;
    emerge)
      local pkgs=(dev-vcs/git dev-build/autoconf dev-build/automake dev-build/libtool
                  dev-util/pkgconf dev-libs/openssl net-misc/curl dev-libs/libzip sys-libs/zlib
                  dev-libs/libusb sys-libs/readline virtual/udev sys-apps/usbutils dev-lang/python)
      emerge --noreplace --quiet-build=y "${pkgs[@]}" \
        || die "emerge failed. On older Gentoo profiles autotools live in sys-devel/*; install them and re-run with --skip-deps."
      ;;
    eopkg)
      eopkg install -y -c system.devel
      local pkgs=(git autoconf automake libtool pkgconf openssl-devel curl-devel libzip-devel
                  zlib-devel libusb-devel readline-devel systemd-devel usbutils python3)
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(python3-tkinter)
      eopkg install -y "${pkgs[@]}"
      ;;
    none) ;;
  esac
  ok "dependencies installed"
}

APT_CONFLICTS=(libimobiledevice6 libimobiledevice-utils idevicerestore usbmuxd
               libusbmuxd-dev libusbmuxd6 libirecovery3 libirecovery-utils)

installed_conflicts() {
  case "$PM" in
    apt) for p in "${APT_CONFLICTS[@]}"; do
           dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" && echo "$p"
         done ;;
    dnf|zypper) for p in idevicerestore usbmuxd libimobiledevice-utils libirecovery-utils; do
           rpm -q "$p" >/dev/null 2>&1 && echo "$p"; done ;;
    yum) for p in idevicerestore usbmuxd libimobiledevice-utils; do
           rpm -q "$p" >/dev/null 2>&1 && echo "$p"; done ;;
    pacman) for p in idevicerestore usbmuxd libimobiledevice libirecovery; do
           pacman -Q "$p" >/dev/null 2>&1 && echo "$p"; done ;;
    apk) for p in idevicerestore usbmuxd libimobiledevice-progs libirecovery-progs; do
           apk info -e "$p" >/dev/null 2>&1 && echo "$p"; done ;;
    xbps) for p in idevicerestore usbmuxd libimobiledevice; do
           xbps-query "$p" >/dev/null 2>&1 && echo "$p"; done ;;
    emerge) for p in app-pda/idevicerestore app-pda/usbmuxd; do
           [[ -d /var/db/pkg/${p%/*} ]] && compgen -G "/var/db/pkg/$p-[0-9]*" >/dev/null && echo "$p"; done ;;
  esac
  return 0
}

maybe_remove_distro_packages() {
  local pkgs
  mapfile -t pkgs < <(installed_conflicts)
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  warn "Old distro packages installed: ${pkgs[*]}"
  warn "These outdated versions are the usual cause of TSS status 94 /"
  warn "'Unable to get SHSH blobs' and can shadow the fresh build."
  if [[ $REMOVE_DISTRO -eq 1 ]] || { [[ $ASSUME_YES -eq 0 ]] && confirm "Remove them now (recommended)?"; }; then
    REMOVE_DISTRO=1
  else
    warn "Keeping them. Re-run with --remove-distro-packages if restores fail."
  fi
}

remove_distro_packages() {
  info "Removing old distro packages that conflict with the fresh build"
  case "$PM" in
    apt)
      local pkgs; mapfile -t pkgs < <(installed_conflicts)
      if [[ ${#pkgs[@]} -gt 0 ]]; then
        # Note: on desktops this may also remove gvfs-backends (iPhone file access
        # in the file manager). The fresh libimobiledevice build replaces it for
        # command-line use; reinstall gvfs-backends later if you need it.
        apt-get remove --purge -y "${pkgs[@]}" || true
        apt-get autoremove -y || true
      fi ;;
    *)
      local pkgs; mapfile -t pkgs < <(installed_conflicts)
      [[ ${#pkgs[@]} -eq 0 ]] && return 0
      case "$PM" in
        dnf|yum) $PM remove -y "${pkgs[@]}" || true ;;
        pacman)  pacman -Rdd --noconfirm "${pkgs[@]}" || true ;;
        zypper)  zypper --non-interactive remove "${pkgs[@]}" || true ;;
        apk)     apk del "${pkgs[@]}" || true ;;
        xbps)    xbps-remove -Fy "${pkgs[@]}" || true ;;
        emerge)  emerge --unmerge "${pkgs[@]}" || true ;;
      esac ;;
  esac
}

warn_distro_conflicts() {
  local found=()
  for b in /usr/bin/idevicerestore /usr/sbin/usbmuxd /usr/bin/irecovery; do
    [[ -x "$b" && "$PREFIX" != "/usr" ]] && found+=("$b")
  done
  if [[ ${#found[@]} -gt 0 ]]; then
    warn "Old distro binaries found: ${found[*]}"
    warn "The new build in $PREFIX takes precedence on PATH, but you can remove"
    warn "the old ones with: sudo ./install.sh --skip-build --remove-distro-packages"
  fi
}

# ----------------------------------------------------------------- build ----
libdirs() {
  # Fedora/openSUSE install to lib64 under some prefixes.
  echo "$PREFIX/lib" "$PREFIX/lib64"
}

setup_env() {
  local pc=""
  for d in $(libdirs); do pc+="$d/pkgconfig:"; done
  export PKG_CONFIG_PATH="${pc}$PREFIX/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export PATH="$PREFIX/bin:$PREFIX/sbin:$PATH"
  # Make sure the dynamic loader finds libraries in the prefix (not default on Fedora/openSUSE).
  if [[ "$PREFIX" != "/usr" ]]; then
    if [[ -d /etc/ld.so.conf.d ]]; then
      printf '%s\n' "$PREFIX/lib" "$PREFIX/lib64" > /etc/ld.so.conf.d/idevicerestore-setup.conf
    elif [[ -e /lib/ld-musl-"$(uname -m)".so.1 ]]; then
      # musl (Alpine, Void musl): /usr/local/lib is searched by default; add others.
      local path_file; path_file="/etc/ld-musl-$(uname -m).path"
      if [[ "$PREFIX" != "/usr/local" ]] && ! grep -qs "$PREFIX/lib" "$path_file"; then
        { [[ -s "$path_file" ]] || printf '%s\n' /lib /usr/local/lib /usr/lib; printf '%s\n' "$PREFIX/lib"; } >>"$path_file"
      fi
    fi
    run_ldconfig
  fi
}

ensure_usbmux_user() {
  local nologin=/usr/sbin/nologin
  [[ -x $nologin ]] || nologin=/sbin/nologin
  [[ -x $nologin ]] || nologin=/bin/false
  getent group plugdev >/dev/null || groupadd -r plugdev 2>/dev/null || addgroup -S plugdev
  if ! getent passwd usbmux >/dev/null; then
    useradd -r -g plugdev -d /var/lib/usbmux -s "$nologin" -c "usbmux daemon" usbmux 2>/dev/null \
      || adduser -S -D -H -G plugdev -h /var/lib/usbmux -s "$nologin" usbmux
    ok "created system user 'usbmux'"
  fi
  mkdir -p /var/lib/lockdown
  chmod 0755 /var/lib/lockdown
}

build_one() {
  local name="$1" dir="$SRC_DIR/$1"
  info "Building $name"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch -q --depth 1 origin HEAD && git -C "$dir" reset -q --hard FETCH_HEAD
    git -C "$dir" clean -fdx -q
  else
    git clone -q --depth 1 "$GIT_BASE/$name.git" "$dir"
  fi
  local extra=()
  case "$name" in
    libplist|libimobiledevice) extra+=(--without-cython) ;;
    libirecovery) extra+=(--with-udevrulesdir=/etc/udev/rules.d) ;;
    usbmuxd)
      extra+=(--with-udevrulesdir=/etc/udev/rules.d)
      # Without systemd, the udev rule starts usbmuxd directly (sysvinit, OpenRC, runit).
      if [[ "$INIT" == "systemd" ]]; then
        extra+=(--with-systemd --with-systemdsystemunitdir=/etc/systemd/system)
      else
        extra+=(--without-systemd)
      fi
      ;;
  esac
  (
    cd "$dir"
    ./autogen.sh --prefix="$PREFIX" "${extra[@]}"
    make -j"$JOBS"
    make install
  ) >>"$LOG_FILE" 2>&1 || die "Building $name failed. Last lines of $LOG_FILE:\n$(tail -n 30 "$LOG_FILE")"
  run_ldconfig
  ok "$name $(git -C "$dir" log -1 --format='%h %cs')"
}

build_all() {
  mkdir -p "$SRC_DIR"
  : >"$LOG_FILE"
  info "Full build log: $LOG_FILE"
  for r in "${REPOS[@]}"; do build_one "$r"; done
}

# ------------------------------------------------------------ configure ----
configure_system() {
  ensure_usbmux_user
  if command -v udevadm >/dev/null; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=usb 2>/dev/null || true
    ok "udev rules reloaded"
  else
    warn "udevadm not found; udev rules will apply after reboot"
  fi
  local has_udev=0
  command -v udevadm >/dev/null && has_udev=1
  case "$INIT" in
    systemd)
      systemctl daemon-reload
      # The service is started on demand by udev when a device is plugged in.
      systemctl enable usbmuxd.service >/dev/null 2>&1 || true
      systemctl restart usbmuxd.service 2>/dev/null || true
      ok "usbmuxd systemd service configured"
      ;;
    openrc)
      install -Dm755 "$SCRIPT_DIR/share/init/usbmuxd.openrc" /etc/init.d/usbmuxd
      sed -i "s|@SBINDIR@|$PREFIX/sbin|" /etc/init.d/usbmuxd
      [[ $has_udev -eq 1 ]] || rc-update add udev sysinit >/dev/null 2>&1 || true
      rc-update add usbmuxd default >/dev/null 2>&1 || true
      rc-service usbmuxd restart >/dev/null 2>&1 || true
      ok "usbmuxd OpenRC service installed and enabled (rc-service usbmuxd status)"
      ;;
    runit)
      local sv=/etc/sv/usbmuxd
      install -Dm755 "$SCRIPT_DIR/share/init/usbmuxd.runit" "$sv/run"
      sed -i "s|@SBINDIR@|$PREFIX/sbin|" "$sv/run"
      local svdir=/var/service; [[ -d /etc/runit/runsvdir/default ]] && svdir=/etc/runit/runsvdir/default
      [[ -d $svdir ]] && ln -sfn "$sv" "$svdir/usbmuxd"
      ok "usbmuxd runit service installed (sv status usbmuxd)"
      ;;
    none)
      if [[ $has_udev -eq 1 ]]; then
        ok "usbmuxd will be started by udev when a device is plugged in"
      else
        warn "No init system or udev detected (container?). Start usbmuxd manually before restoring:"
        warn "  sudo $PREFIX/sbin/usbmuxd -f -v"
      fi
      ;;
  esac
}

install_tools() {
  local share="$PREFIX/share/idevicerestore-setup"
  install -Dm755 "$SCRIPT_DIR/bin/idr-doctor" "$PREFIX/bin/idr-doctor"
  install -Dm755 "$SCRIPT_DIR/bin/idr-gui" "$PREFIX/bin/idr-gui"
  # Keep a copy of the installer so the GUI's "Install / repair" works later.
  install -Dm755 "$SCRIPT_DIR/install.sh" "$share/install.sh"
  install -Dm755 "$SCRIPT_DIR/bin/idr-doctor" "$share/bin/idr-doctor"
  install -Dm755 "$SCRIPT_DIR/bin/idr-gui" "$share/bin/idr-gui"
  install -Dm644 "$SCRIPT_DIR/share/idr-gui.desktop" "$share/share/idr-gui.desktop"
  install -Dm644 "$SCRIPT_DIR/share/init/usbmuxd.openrc" "$share/share/init/usbmuxd.openrc"
  install -Dm644 "$SCRIPT_DIR/share/init/usbmuxd.runit" "$share/share/init/usbmuxd.runit"
  if [[ -d /usr/share/applications ]]; then
    install -Dm644 "$SCRIPT_DIR/share/idr-gui.desktop" /usr/share/applications/idr-gui.desktop
  fi
  ok "installed idr-doctor and idr-gui to $PREFIX/bin"
}

uninstall() {
  info "Uninstalling"
  for r in "${REPOS[@]}"; do
    if [[ -f "$SRC_DIR/$r/Makefile" ]]; then
      make -C "$SRC_DIR/$r" uninstall >/dev/null 2>&1 && ok "removed $r" || warn "could not uninstall $r"
    fi
  done
  rm -rf "$PREFIX/share/idevicerestore-setup"
  rm -f "$PREFIX/bin/idr-doctor" "$PREFIX/bin/idr-gui" /usr/share/applications/idr-gui.desktop \
        /etc/ld.so.conf.d/idevicerestore-setup.conf
  rm -f /etc/init.d/usbmuxd /etc/sv/usbmuxd/run /var/service/usbmuxd /etc/runit/runsvdir/default/usbmuxd
  run_ldconfig
  [[ "$INIT" == "systemd" ]] && systemctl daemon-reload || true
  ok "done. Sources are still in $SRC_DIR (delete manually if you like)"
}

# ------------------------------------------------------------------ main ----
main() {
  detect_distro
  if [[ $UNINSTALL -eq 1 ]]; then uninstall; exit 0; fi

  cat <<EOF
idevicerestore-setup
  Distribution : $DISTRO_NAME ($PM, init: $INIT, $(uname -m))
  Prefix       : $PREFIX
  Sources      : $SRC_DIR
  Steps        : $([[ $SKIP_DEPS -eq 0 ]] && echo "deps, ")$([[ $SKIP_BUILD -eq 0 ]] && echo "build ${#REPOS[@]} projects, ")udev + usbmuxd, idr-doctor
EOF
  confirm "Continue?" || exit 1

  maybe_remove_distro_packages
  [[ $REMOVE_DISTRO -eq 1 ]] && remove_distro_packages
  [[ $SKIP_DEPS -eq 0 ]] && install_deps
  setup_env
  [[ $SKIP_BUILD -eq 0 ]] && build_all
  configure_system
  install_tools
  warn_distro_conflicts

  echo
  ok "Setup complete. idevicerestore: $("$PREFIX/bin/idevicerestore" --version 2>/dev/null | head -n1 || echo 'not found')"
  cat <<EOF

Next steps:
  1. Plug in the device and run:      idr-doctor
  2. Restore to the latest signed iOS (erases the device):
                                      sudo idr-doctor restore -- -e -l
  3. If anything fails, run:          idr-doctor explain /path/to/idevicerestore.log
EOF
}

[[ "${IDR_SOURCE_ONLY:-0}" == 1 ]] || main
