#!/usr/bin/env bash
# Shared helpers sourced by ref/*.sh. Not executable on its own.
# Callers must set REPO_ROOT (`$(cd "$(dirname "$0")/.." && pwd)`) before sourcing.

NAME_PREFIX="seed-ubuntu"

# Print sha256 of a file. Uses sha256sum on Linux; falls back to
# shasum -a 256 on macOS (Darwin lacks sha256sum by default).
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Single source of truth for which (OS, arch) pairs are supported. Prints the
# runtime binary name (docker | container) on stdout; emits a message to stderr
# and returns non-zero on anything else. Reads UNAME_S / UNAME_M from env if
# set (used by verify.sh to test abort paths); falls back to `uname` otherwise.
detect_runtime() {
  local s="${UNAME_S:-$(uname -s)}"
  local m="${UNAME_M:-$(uname -m)}"
  case "$s/$m" in
    Linux/x86_64|Linux/aarch64) echo "docker" ;;
    Darwin/arm64) echo "container" ;;
    Darwin/x86_64) echo "Intel Mac not supported; seed-ubuntu-container requires Apple Silicon." >&2; return 1 ;;
    *) echo "unsupported host: $s/$m" >&2; return 1 ;;
  esac
}

# Print the content-addressed image tag for ref/Dockerfile.
# Requires REPO_ROOT in scope.
image_tag() {
  echo "seed-ubuntu:$(sha256_file "$REPO_ROOT/ref/Dockerfile")"
}

# Public host-container name for a user-chosen sandbox name. Single source of
# truth so sandbox.sh's create/exec/down/list and verify.sh's assertions can't
# drift.
full_name() {
  echo "${NAME_PREFIX}-$1"
}
