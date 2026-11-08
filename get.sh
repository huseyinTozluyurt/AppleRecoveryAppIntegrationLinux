#!/usr/bin/env bash
# One-line installer:
#   curl -fsSL https://raw.githubusercontent.com/huseyinTozluyurt/idevicerestore-setup/main/get.sh | bash
# Extra arguments are passed to install.sh, e.g.  ... | bash -s -- --with-gui
set -euo pipefail
REPO="huseyinTozluyurt/idevicerestore-setup"
BRANCH="${IDR_BRANCH:-main}"
command -v curl >/dev/null || { echo "Please install curl first." >&2; exit 1; }
command -v tar  >/dev/null || { echo "Please install tar first." >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "==> Downloading $REPO ($BRANCH)"
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar xz -C "$tmp"
cd "$tmp"/idevicerestore-setup-*
SUDO=(); [[ $EUID -eq 0 ]] || SUDO=(sudo)
# When piped into bash, stdin is the script itself; read answers from the terminal instead.
if { : </dev/tty; } 2>/dev/null; then
  "${SUDO[@]}" bash ./install.sh "$@" </dev/tty
else
  "${SUDO[@]}" bash ./install.sh -y "$@"
fi
