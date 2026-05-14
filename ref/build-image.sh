#!/usr/bin/env bash
set -euo pipefail

# build-image.sh — build seed-ubuntu:<sha256-of-Dockerfile> if missing.
# Idempotent. No sudo. No prompts.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

case "$(uname -s)" in
  Linux)  RUNTIME="docker" ;;
  Darwin) RUNTIME="container" ;;
  *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

IMAGE_SHA="$(sha256sum ref/Dockerfile | awk '{print $1}')"
IMAGE_TAG="seed-ubuntu:${IMAGE_SHA}"

# Skip if already built.
case "$RUNTIME" in
  docker)
    if docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
      echo "$IMAGE_TAG already present; nothing to do."
      exit 0
    fi
    ;;
  container)
    if container image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
      echo "$IMAGE_TAG already present; nothing to do."
      exit 0
    fi
    ;;
esac

echo "Building $IMAGE_TAG..."
case "$RUNTIME" in
  docker)    docker    build --tag "$IMAGE_TAG" ref/ ;;
  container) container build --tag "$IMAGE_TAG" ref/ ;;
esac
echo "Built $IMAGE_TAG."
