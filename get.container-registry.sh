#!/bin/sh
# get.container-registry.sh - Install container-registry.sh (pull/push images without Docker)
# Usage: curl https://get.container-registry.sh | sh -s
#    or: wget -qO- https://get.container-registry.sh | sh -s
#
# Installs to $HOME/.local/bin by default. Override: INSTALL_DIR=/path SCRIPT_URL=url
# Dependencies: curl|wget (for install), then jq, tar; gzip optional. Set INSTALL_DEPS=1 to try installing missing deps.

set -e

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
SCRIPT_URL="${SCRIPT_URL:-https://container-registry.sh/container-registry.sh}"

# Required for container-registry.sh: curl, jq, tar. gzip optional (for .tar.gz).
check_dep() { command -v "$1" >/dev/null 2>&1; }
missing_deps() {
  _m=""
  check_dep curl || _m="${_m} curl"
  check_dep jq   || _m="${_m} jq"
  check_dep tar  || _m="${_m} tar"
  echo "$_m"
}

try_install_deps() {
  _missing=$(missing_deps)
  [ -z "$_missing" ] && return 0
  if check_dep apt-get 2>/dev/null; then
    echo "Installing dependencies (sudo apt-get)..."
    sudo apt-get update -qq && sudo apt-get install -y curl jq tar gzip
  elif check_dep dnf 2>/dev/null; then
    echo "Installing dependencies (sudo dnf)..."
    sudo dnf install -y curl jq tar gzip
  elif check_dep yum 2>/dev/null; then
    echo "Installing dependencies (sudo yum)..."
    sudo yum install -y curl jq tar gzip
  elif check_dep apk 2>/dev/null; then
    echo "Installing dependencies (sudo apk)..."
    sudo apk add --no-cache curl jq tar gzip
  elif check_dep brew 2>/dev/null; then
    echo "Installing dependencies (brew)..."
    brew install curl jq gzip
  else
    echo "Could not detect package manager to install:$_missing" >&2
    return 1
  fi
}

echo "container-registry.sh installer"
echo ""

if [ "$INSTALL_DEPS" = "1" ]; then
  try_install_deps || true
fi

_missing=$(missing_deps)
if [ -n "$_missing" ]; then
  echo "Missing required commands:$_missing" >&2
  echo "Install them, or run with INSTALL_DEPS=1 to try automatic install (apt/dnf/yum/apk/brew)." >&2
  echo "Example (Debian/Ubuntu): sudo apt-get install curl jq tar gzip" >&2
  exit 1
fi

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
