#!/usr/bin/env bash
set -euo pipefail

# sandbox.sh — uniform ephemeral-sandbox interface (docker | apple container).
# Usage:
#   sandbox.sh up   <name> [--recreate] [--mount HOST:CONTAINER]
#   sandbox.sh exec <name> -- <cmd> [args...]
#   sandbox.sh down <name>
#   sandbox.sh list

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME_PREFIX="seed-ubuntu"

case "$(uname -s)" in
  Linux)  RUNTIME="docker" ;;
  Darwin) RUNTIME="container" ;;
  *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

image_tag() {
  local sha
  sha="$(sha256sum "$REPO_ROOT/ref/Dockerfile" | awk '{print $1}')"
  echo "seed-ubuntu:${sha}"
}

full_name() {
  echo "${NAME_PREFIX}-$1"
}

cmd_up() {
  local name="$1"; shift
  local recreate=0
  local mount=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --recreate) recreate=1; shift ;;
      --mount)    mount="$2"; shift 2 ;;
      *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
  done

  local fn; fn="$(full_name "$name")"
  local tag; tag="$(image_tag)"

  # Build if missing (idempotent).
  bash "$REPO_ROOT/ref/build-image.sh" >/dev/null

  # Handle name collision. Use `if` to avoid set -e tripping on the
  # non-zero `inspect` exit when the container is absent.
  local exists=0
  if "$RUNTIME" inspect "$fn" >/dev/null 2>&1; then
    exists=1
  fi
  if [ "$exists" = 1 ]; then
    if [ "$recreate" = 1 ]; then
      cmd_down "$name"
    else
      echo "sandbox $fn already exists (use --recreate to replace)" >&2
      exit 1
    fi
  fi

  local mount_args=()
  if [ -n "$mount" ]; then
    mount_args=(-v "$mount")
  fi

  "$RUNTIME" run -d --name "$fn" "${mount_args[@]}" "$tag" >/dev/null
  echo "$fn"
}

cmd_exec() {
  local name="$1"; shift
  if [ "${1:-}" != "--" ]; then
    echo "usage: sandbox.sh exec <name> -- <cmd> [args...]" >&2
    exit 2
  fi
  shift  # consume --

  local fn; fn="$(full_name "$name")"
  exec "$RUNTIME" exec "$fn" "$@"
}

cmd_down() {
  local name="$1"
  local fn; fn="$(full_name "$name")"
  "$RUNTIME" rm -f "$fn" >/dev/null 2>&1 || true
}

cmd_list() {
  case "$RUNTIME" in
    docker)
      docker ps -a --filter "name=^${NAME_PREFIX}-" --format '{{.Names}}'
      ;;
    container)
      container list --all --format '{{.Names}}' | grep "^${NAME_PREFIX}-" || true
      ;;
  esac
}

if [ $# -lt 1 ]; then
  echo "usage: sandbox.sh {up|exec|down|list} [args...]" >&2
  exit 2
fi
sub="$1"; shift
case "$sub" in
  up)   cmd_up   "$@" ;;
  exec) cmd_exec "$@" ;;
  down) cmd_down "$@" ;;
  list) cmd_list "$@" ;;
  *) echo "unknown subcommand: $sub" >&2; exit 2 ;;
esac
