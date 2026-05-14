#!/usr/bin/env bash
set -euo pipefail

# verify.sh — deterministic equivalent of SEED.md ## Verify prompts.
# Run from $REPO_ROOT. Exit 0 = all three prompts pass.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Detect runtime (matches sandbox.sh logic).
case "$(uname -s)" in
  Linux)  RUNTIME="docker" ;;
  Darwin) RUNTIME="container" ;;
  *) echo "FAIL: unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

# Image tag = sha256 of Dockerfile content.
IMAGE_SHA="$(sha256sum ref/Dockerfile | awk '{print $1}')"
IMAGE_TAG="seed-ubuntu:${IMAGE_SHA}"

# 1. Runtime is healthy.
echo "[1/3] Runtime is healthy ($RUNTIME)..."
case "$RUNTIME" in
  docker)
    docker version --format '{{.Server.Version}}' >/dev/null \
      || { echo "FAIL: docker not responsive" >&2; exit 1; }
    ;;
  container)
    container --version >/dev/null \
      || { echo "FAIL: apple container CLI not responsive" >&2; exit 1; }
    ;;
esac
echo "  ok"

# 2. Base image is present.
echo "[2/3] Base image $IMAGE_TAG is present..."
case "$RUNTIME" in
  docker)
    docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 \
      || { echo "FAIL: image $IMAGE_TAG not found; run ref/build-image.sh" >&2; exit 1; }
    ;;
  container)
    container image inspect "$IMAGE_TAG" >/dev/null 2>&1 \
      || { echo "FAIL: image $IMAGE_TAG not found; run ref/build-image.sh" >&2; exit 1; }
    ;;
esac
echo "  ok"

# 3. End-to-end round-trip. Spin up, exec echo hello, down, confirm no residue.
SANDBOX_NAME="verify-$$-$RANDOM"
FULL_NAME="seed-ubuntu-${SANDBOX_NAME}"

cleanup() {
  bash ref/sandbox.sh down "$SANDBOX_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[3/3] End-to-end round-trip ($SANDBOX_NAME)..."

bash ref/sandbox.sh up "$SANDBOX_NAME" >/dev/null \
  || { echo "FAIL: sandbox.sh up failed" >&2; exit 1; }

OUT="$(bash ref/sandbox.sh exec "$SANDBOX_NAME" -- echo hello)"
if [ "$OUT" != "hello" ]; then
  echo "FAIL: expected 'hello', got '$OUT'" >&2
  exit 1
fi

bash ref/sandbox.sh down "$SANDBOX_NAME" >/dev/null \
  || { echo "FAIL: sandbox.sh down failed" >&2; exit 1; }

# Confirm no residue.
if bash ref/sandbox.sh list | grep -q "$FULL_NAME"; then
  echo "FAIL: sandbox $FULL_NAME still present after down" >&2
  exit 1
fi

trap - EXIT
echo "  ok"
echo "All checks passed."
