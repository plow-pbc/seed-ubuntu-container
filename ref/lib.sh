#!/usr/bin/env bash
# Shared helpers sourced by ref/*.sh. Not executable on its own.
# Callers must set REPO_ROOT (`$(cd "$(dirname "$0")/.." && pwd)`) before sourcing.

# Print sha256 of a file. Uses sha256sum on Linux; falls back to
# shasum -a 256 on macOS (Darwin lacks sha256sum by default).
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Detect the container runtime for the current host. Prints the binary name
# on stdout; emits a message to stderr and returns non-zero on unsupported.
detect_runtime() {
  case "$(uname -s)" in
    Linux)  echo "docker" ;;
    Darwin) echo "container" ;;
    *) echo "unsupported host: $(uname -s)" >&2; return 1 ;;
  esac
}

# Print the content-addressed image tag for ref/Dockerfile.
# Requires REPO_ROOT in scope.
image_tag() {
  echo "seed-ubuntu:$(sha256_file "$REPO_ROOT/ref/Dockerfile")"
}
