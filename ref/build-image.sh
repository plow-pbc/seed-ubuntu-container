#!/usr/bin/env bash
set -euo pipefail

# build-image.sh — build seed-ubuntu:<sha256-of-Dockerfile> if missing.
# Idempotent. No sudo. No prompts.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib.sh
. "$REPO_ROOT/ref/lib.sh"

case "$(uname -s)" in
  Linux)  RUNTIME="docker" ;;
  Darwin) RUNTIME="container" ;;
  *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

IMAGE_SHA="$(sha256_file ref/Dockerfile)"
IMAGE_TAG="seed-ubuntu:${IMAGE_SHA}"

if "$RUNTIME" image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "$IMAGE_TAG already present; nothing to do."
  exit 0
fi

echo "Building $IMAGE_TAG..."
"$RUNTIME" build --tag "$IMAGE_TAG" ref/
echo "Built $IMAGE_TAG."
