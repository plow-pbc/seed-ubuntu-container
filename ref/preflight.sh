#!/usr/bin/env bash
set -euo pipefail

# preflight.sh — collect ALL interactive asks at the frontend.
# Detect host, plan the install, confirm once, then run non-interactively.
# Exits non-zero with a clear message if anything is wrong or if re-login
# is required after group changes.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_ROOT/ref/lib.sh"

UNAME_S="${UNAME_S:-$(uname -s)}"
UNAME_M="${UNAME_M:-$(uname -m)}"

abort() {
  echo "preflight: $*" >&2
  exit 1
}

# 1. Host detection — single source of truth in lib.sh's detect_runtime.
runtime="$(detect_runtime)" || exit 1

# 2. Detect runtime state (whether it's installed; group membership).
install_runtime=0
install_group=0
case "$UNAME_S" in
  Linux)
    if ! command -v docker >/dev/null 2>&1; then install_runtime=1; fi
    if ! id -nG | grep -qw docker; then install_group=1; fi
    ;;
  Darwin)
    if ! command -v container >/dev/null 2>&1; then install_runtime=1; fi
    ;;
esac

# 3. Print plan + confirm. Show the exact commands the user is about to consent to.
echo "Preflight plan:"
echo "  host:          $UNAME_S/$UNAME_M"
echo "  runtime:       $runtime"
if [ "$install_runtime" = 1 ]; then
  echo "  install:       $runtime"
  case "$runtime" in
    docker)
      echo "  command:       curl -fsSL https://get.docker.com | sudo sh"
      echo "  command:       sudo systemctl enable --now docker"
      ;;
    container)
      echo "  command:       brew install --cask container"
      echo "  command:       container system start"
      ;;
  esac
else
  echo "  install:       (already present)"
fi
if [ "$install_group" = 1 ]; then
  echo "  group:         add $USER to docker group (re-login required)"
  echo "  command:       sudo usermod -aG docker $USER"
  echo "  WARNING:       docker-group membership is host-root-equivalent"
fi
echo

read -r -p "Proceed? [y/N] " ans
case "$ans" in
  y|Y|yes|YES) ;;
  *) abort "aborted by user." ;;
esac

# 4. Install non-interactively.
if [ "$install_runtime" = 1 ]; then
  case "$runtime" in
    docker)
      curl -fsSL https://get.docker.com | sudo sh
      sudo systemctl enable --now docker
      ;;
    container)
      command -v brew >/dev/null 2>&1 \
        || abort "Homebrew required to install apple container CLI. Install brew first."
      brew install --cask container
      container system start
      ;;
  esac
fi

if [ "$install_group" = 1 ]; then
  sudo usermod -aG docker "$USER"
  abort "Added $USER to docker group. Log out and back in, then re-run preflight."
fi

echo "preflight: ok"
