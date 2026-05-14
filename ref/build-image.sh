#!/usr/bin/env bash
set -euo pipefail

# build-image.sh — build seed-ubuntu:<sha256-of-Dockerfile> if missing.
# Idempotent. No sudo. No prompts.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib.sh
. "$REPO_ROOT/ref/lib.sh"

RUNTIME="$(detect_runtime)" || exit 1
IMAGE_TAG="$(image_tag)"

if "$RUNTIME" image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
  echo "$IMAGE_TAG already present; nothing to do."
  exit 0
fi

echo "Building $IMAGE_TAG..."
"$RUNTIME" build --tag "$IMAGE_TAG" ref/
echo "Built $IMAGE_TAG."
