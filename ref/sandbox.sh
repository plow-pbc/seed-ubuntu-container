#!/usr/bin/env bash
set -euo pipefail

# sandbox.sh — uniform ephemeral-sandbox interface (docker | apple container).

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
        # Fail loud on the footguns of bare `docker -v`:
        #  - 'path' (no colon) creates an anonymous volume, not a bind mount
        #  - relative host paths are treated as named volumes, not bind mounts
        #  - absent host paths are silently auto-created (owned by root)
        #  - non-absolute container paths are silently rejected by docker
        case "$2" in *:*) ;; *) echo "sandbox.sh up: --mount must be HOST:CONTAINER, got: $2" >&2; exit 2 ;; esac
        local host="${2%%:*}"
        local container_path="${2#*:}"
        [ "${host:0:1}" = "/" ] || { echo "sandbox.sh up: --mount host path must be absolute: $host" >&2; exit 2; }
        [ -e "$host" ] || { echo "sandbox.sh up: --mount host path missing: $host" >&2; exit 2; }
        [ "${container_path:0:1}" = "/" ] || { echo "sandbox.sh up: --mount container path must be absolute: $container_path" >&2; exit 2; }
        mount_args+=(-v "$2"); shift 2 ;;
      *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
  done

  local fn; fn="$(full_name "$name")"
  local tag; tag="$(image_tag)"

  # Build if missing (idempotent).
  bash "$REPO_ROOT/ref/build-image.sh" >/dev/null

  # Handle name collision via cmd_list — single source of truth for "which
  # seed-ubuntu containers exist." Naturally filtered to containers (not
  # images/volumes/networks). Capture to a variable first so a cmd_list
  # failure (daemon error) trips set -e at the assignment instead of being
  # silently swallowed by the if's conditional context.
  local listing
  listing="$(cmd_list)"
  if printf '%s\n' "$listing" | grep -Fxq "$fn"; then
    if [ "$recreate" = 1 ]; then
      cmd_down "$name"
    else
      echo "sandbox $fn already exists (use --recreate to replace)" >&2
      exit 1
    fi
  fi

  "$RUNTIME" run -d --name "$fn" ${mount_args[@]+"${mount_args[@]}"} "$tag" >/dev/null
  echo "$fn"
}

cmd_exec() {
  local name="$1"; shift
  # Forward -i/-t/-it to the underlying runtime's `exec` so consumers can drive
  # interactive prompts (e.g. `op account add`'s stdin reads in seed-1password).
  # Explicit allowlist — matches `cmd_up`'s stance of named flags, not bare passthrough.
  local exec_flags=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      -i|-t|-it) exec_flags+=("$1"); shift ;;
      *) echo "sandbox.sh exec: unknown flag '$1' (allowed: -i, -t, -it)" >&2; exit 2 ;;
    esac
  done
  if [ "${1:-}" != "--" ]; then
    echo "usage: sandbox.sh exec <name> [-i|-t|-it] -- <cmd> [args...]" >&2
    exit 2
  fi
  shift  # consume --

  local fn; fn="$(full_name "$name")"
  exec "$RUNTIME" exec ${exec_flags[@]+"${exec_flags[@]}"} "$fn" "$@"
}

cmd_down() {
  local name="$1"
  local fn; fn="$(full_name "$name")"
  # Idempotent only for the absent case. Capture cmd_list to a variable first
  # — wrapping it in `if cmd_list | ...; then` would suppress set -e on
  # daemon failures.
  local listing
  listing="$(cmd_list)"
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
      # Apple `container list --quiet` prints container IDs, which for
      # `container run --name X` are X — i.e. the names. Docker-style
      # `--format '{{.Names}}'` is not supported by Apple's CLI (only
      # json/table/yaml).
      # Capture-then-filter: a container-list failure propagates via set -e,
      # but the grep no-match is softened (empty list is not an error).
      local listing
      listing="$(container list --all --quiet)"
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
