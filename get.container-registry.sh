#!/bin/sh
# get.container-registry.sh - Install container-registry.sh (pull/push images without Docker)
# Usage: curl https://get.container-registry.sh | sh -s
#    or: wget -qO- https://get.container-registry.sh | sh -s
#
# Installs to $HOME/.local/bin by default. Override: INSTALL_DIR=/path SCRIPT_URL=url

set -e

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
# Canonical script URL (when hosted at container-registry.sh); override with SCRIPT_URL env
SCRIPT_URL="${SCRIPT_URL:-https://container-registry.sh/container-registry.sh}"

echo "container-registry.sh installer"
echo ""

mkdir -p "$INSTALL_DIR"
if ! [ -d "$INSTALL_DIR" ]; then
  echo "Error: could not create directory: $INSTALL_DIR" >&2
  exit 1
fi

echo "Downloading container-registry.sh..."
if command -v curl >/dev/null 2>&1; then
  curl -sSLf "$SCRIPT_URL" -o "${INSTALL_DIR}/container-registry.sh"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "${INSTALL_DIR}/container-registry.sh" "$SCRIPT_URL"
else
  echo "Error: need curl or wget to download" >&2
  exit 1
fi

chmod +x "${INSTALL_DIR}/container-registry.sh"
echo "Installed to: ${INSTALL_DIR}/container-registry.sh"

if [ -x "${INSTALL_DIR}/container-registry.sh" ]; then
  echo ""
  echo "Run with: ${INSTALL_DIR}/container-registry.sh pull alpine:3.19"
  echo "Or add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
