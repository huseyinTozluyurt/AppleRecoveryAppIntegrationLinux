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
# Supported: Debian/Ubuntu/Mint/Pop!_OS, Fedora/RHEL/Rocky/Alma, Arch/Manjaro,
#            openSUSE Leap/Tumbleweed.
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

have_systemd() { [[ -d /run/systemd/system ]]; }

# ---------------------------------------------------------------- distro ----
detect_distro() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  local ids="${ID:-} ${ID_LIKE:-}"
  if   command -v apt-get >/dev/null && [[ "$ids" =~ (debian|ubuntu) ]]; then PM=apt
  elif command -v dnf     >/dev/null; then PM=dnf
  elif command -v pacman  >/dev/null; then PM=pacman
  elif command -v zypper  >/dev/null; then PM=zypper
  elif command -v apt-get >/dev/null; then PM=apt
  else die "Unsupported distribution: ${PRETTY_NAME:-unknown}. Install the build deps manually and re-run with --skip-deps."
  fi
  DISTRO_NAME="${PRETTY_NAME:-$ID}"
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
    dnf)
      local pkgs=(gcc gcc-c++ make git autoconf automake libtool pkgconf-pkg-config
                  openssl-devel libcurl-devel libzip-devel zlib-devel libusb1-devel
                  readline-devel systemd-devel usbutils python3 ca-certificates curl)
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(python3-tkinter)
      dnf install -y "${pkgs[@]}"
      ;;
    pacman)
      local pkgs=(base-devel git autoconf automake libtool pkgconf openssl curl libzip
                  zlib libusb readline systemd usbutils python ca-certificates)
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(tk)
      pacman -Sy --needed --noconfirm "${pkgs[@]}"
      ;;
    zypper)
      local pkgs=(gcc gcc-c++ make git autoconf automake libtool pkg-config
                  libopenssl-devel libcurl-devel libzip-devel zlib-devel libusb-1_0-devel
                  readline-devel systemd-devel usbutils python3 ca-certificates curl)
      [[ $WITH_GUI -eq 1 ]] && pkgs+=(python3-tk)
      zypper --non-interactive install --no-recommends "${pkgs[@]}"
      ;;
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
    pacman) for p in idevicerestore usbmuxd libimobiledevice libirecovery; do
           pacman -Q "$p" >/dev/null 2>&1 && echo "$p"; done ;;
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
    dnf)    dnf remove -y idevicerestore usbmuxd libimobiledevice-utils libirecovery-utils 2>/dev/null || true ;;
    pacman) pacman -Rdd --noconfirm idevicerestore usbmuxd libimobiledevice libirecovery 2>/dev/null || true ;;
    zypper) zypper --non-interactive remove idevicerestore usbmuxd libimobiledevice-tools 2>/dev/null || true ;;
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
    printf '%s\n' $(libdirs) > /etc/ld.so.conf.d/idevicerestore-setup.conf
    ldconfig
  fi
}

ensure_usbmux_user() {
  getent group plugdev >/dev/null || groupadd -r plugdev
  if ! getent passwd usbmux >/dev/null; then
    useradd -r -g plugdev -d /var/lib/usbmux -s /usr/sbin/nologin -c "usbmux daemon" usbmux 2>/dev/null \
      || useradd -r -g plugdev -d /var/lib/usbmux -s /sbin/nologin usbmux
    ok "created system user 'usbmux'"
  fi
  mkdir -p /var/lib/lockdown
  chmod 0755 /var/lib/lockdown
}

build_one() {
  local name="$1" dir="$SRC_DIR/$1"
  info "Building $name"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --depth 1 origin HEAD && git -C "$dir" reset --hard FETCH_HEAD
    git -C "$dir" clean -fdx -q
  else
    git clone --depth 1 "$GIT_BASE/$name.git" "$dir"
  fi
  local extra=()
  case "$name" in
    libplist|libimobiledevice) extra+=(--without-cython) ;;
    libirecovery) extra+=(--with-udevrulesdir=/etc/udev/rules.d) ;;
    usbmuxd)
      extra+=(--with-udevrulesdir=/etc/udev/rules.d)
      if have_systemd || pkg-config --exists systemd 2>/dev/null; then
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
  ldconfig
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
  if have_systemd; then
    systemctl daemon-reload
    # The service is started on demand by udev when a device is plugged in.
    systemctl enable usbmuxd.service >/dev/null 2>&1 || true
    systemctl restart usbmuxd.service 2>/dev/null || true
    ok "usbmuxd service configured"
  else
    warn "systemd not running: start usbmuxd manually with 'sudo usbmuxd -f -v' before restoring"
  fi
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
  ldconfig
  have_systemd && systemctl daemon-reload || true
  ok "done. Sources are still in $SRC_DIR (delete manually if you like)"
}

# ------------------------------------------------------------------ main ----
main() {
  detect_distro
  if [[ $UNINSTALL -eq 1 ]]; then uninstall; exit 0; fi

  cat <<EOF
idevicerestore-setup
  Distribution : $DISTRO_NAME ($PM)
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

main
