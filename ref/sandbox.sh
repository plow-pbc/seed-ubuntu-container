#!/usr/bin/env bash
set -euo pipefail

# sandbox.sh — uniform ephemeral-sandbox interface (docker | apple container).
# Usage:
#   sandbox.sh up   <name> [--recreate] [--mount HOST:CONTAINER]
#   sandbox.sh exec <name> -- <cmd> [args...]
#   sandbox.sh down <name>
#   sandbox.sh list

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
. "$REPO_ROOT/ref/lib.sh"

RUNTIME="$(detect_runtime)" || exit 1

cmd_up() {
  local name="$1"; shift
  local recreate=0
  local mount_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --recreate) recreate=1; shift ;;
      --mount)
        # Fail loud on typos. Docker -v silently creates absent host paths
        # (owned by root), which is a footgun.
        local host="${2%%:*}"
        [ -e "$host" ] || { echo "sandbox.sh up: --mount host path missing: $host" >&2; exit 2; }
        mount_args+=(-v "$2"); shift 2 ;;
      *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
  done

  local fn; fn="$(full_name "$name")"
  local tag; tag="$(image_tag)"

  # Build if missing (idempotent).
  bash "$REPO_ROOT/ref/build-image.sh" >/dev/null

  # Handle name collision. Use `if` to avoid set -e tripping on the
  # non-zero `inspect` exit when the container is absent.
  if "$RUNTIME" inspect "$fn" >/dev/null 2>&1; then
    if [ "$recreate" = 1 ]; then
      cmd_down "$name"
    else
      echo "sandbox $fn already exists (use --recreate to replace)" >&2
      exit 1
    fi
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
  # Idempotent only for the absent case. `inspect` can't distinguish absent
  # from daemon-error (both exit non-zero), so use a list-and-filter query
  # that fails loudly on daemon errors but returns empty on absent.
  local listing
  case "$RUNTIME" in
    docker)    listing="$(docker ps -a --filter "name=^${fn}$" --format '{{.Names}}')" ;;
    container) listing="$(container list --all --format '{{.Names}}')" ;;
  esac
  if printf '%s\n' "$listing" | grep -Fxq "$fn"; then
    "$RUNTIME" rm -f "$fn" >/dev/null
  fi
}

cmd_list() {
  case "$RUNTIME" in
    docker)
      docker ps -a --filter "name=^${NAME_PREFIX}-" --format '{{.Names}}'
      ;;
    container)
      # Capture-then-filter: a container-list failure propagates via set -e,
      # but the grep no-match is softened (empty list is not an error).
      local listing
      listing="$(container list --all --format '{{.Names}}')"
      printf '%s\n' "$listing" | grep "^${NAME_PREFIX}-" || true
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
