#!/usr/bin/env bash
# Shared helpers sourced by ref/*.sh. Not executable on its own.

# Print sha256 of a file. Uses sha256sum on Linux; falls back to
# shasum -a 256 on macOS (Darwin lacks sha256sum by default).
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
