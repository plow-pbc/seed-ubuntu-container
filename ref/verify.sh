#!/usr/bin/env bash
set -euo pipefail

# verify.sh — deterministic equivalent of SEED.md ## Verify prompts.
# Run from $REPO_ROOT. Exit 0 = all three prompts pass.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=lib.sh
. "$REPO_ROOT/ref/lib.sh"

RUNTIME="$(detect_runtime)" || exit 1
IMAGE_TAG="$(image_tag)"

TOTAL=5

# 1. Runtime is healthy.
echo "[1/$TOTAL] Runtime is healthy ($RUNTIME)..."
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
echo "[2/$TOTAL] Base image $IMAGE_TAG is present..."
"$RUNTIME" image inspect "$IMAGE_TAG" >/dev/null 2>&1 \
  || { echo "FAIL: image $IMAGE_TAG not found; run ref/build-image.sh" >&2; exit 1; }
echo "  ok"

# 3. End-to-end round-trip. Spin up, exec echo hello, down, confirm no residue.
SANDBOX_NAME="verify-$$-$RANDOM"
FULL_NAME="seed-ubuntu-${SANDBOX_NAME}"

cleanup() {
  bash ref/sandbox.sh down "$SANDBOX_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[3/$TOTAL] End-to-end round-trip ($SANDBOX_NAME)..."

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

# 4. Exec proxies inner exit code. `false` inside the sandbox must exit non-zero
#    via the host wrapper — pins the documented "MUST proxy the inner command's
#    exit code" contract.
NEG_NAME="verify-neg-$$-$RANDOM"
cleanup_neg() {
  bash ref/sandbox.sh down "$NEG_NAME" >/dev/null 2>&1 || true
}
trap cleanup_neg EXIT
echo "[4/$TOTAL] exec proxies non-zero exit ($NEG_NAME)..."
bash ref/sandbox.sh up "$NEG_NAME" >/dev/null
if bash ref/sandbox.sh exec "$NEG_NAME" -- false; then
  echo "FAIL: 'sandbox.sh exec ... -- false' returned 0; exit code not proxied" >&2
  exit 1
fi
bash ref/sandbox.sh down "$NEG_NAME" >/dev/null
trap - EXIT
echo "  ok"

# 5. --mount round-trip. A host directory injected into the sandbox must be
#    readable from inside — pins the documented `--mount HOST:CONTAINER` flag.
MNT_NAME="verify-mnt-$$-$RANDOM"
MNT_HOST="$(mktemp -d)"
# mktemp creates 0700; widen to 0755 so the non-root sandbox user (uid 1001)
# can traverse the bind-mounted directory.
chmod 0755 "$MNT_HOST"
echo "verify-payload-$RANDOM" > "$MNT_HOST/probe"
EXPECTED="$(cat "$MNT_HOST/probe")"
cleanup_mnt() {
  bash ref/sandbox.sh down "$MNT_NAME" >/dev/null 2>&1 || true
  rm -rf "$MNT_HOST"
}
trap cleanup_mnt EXIT
echo "[5/$TOTAL] --mount round-trip ($MNT_NAME)..."
bash ref/sandbox.sh up "$MNT_NAME" --mount "$MNT_HOST:/probe" >/dev/null
GOT="$(bash ref/sandbox.sh exec "$MNT_NAME" -- cat /probe/probe)"
if [ "$GOT" != "$EXPECTED" ]; then
  echo "FAIL: --mount round-trip: expected '$EXPECTED', got '$GOT'" >&2
  exit 1
fi
bash ref/sandbox.sh down "$MNT_NAME" >/dev/null
rm -rf "$MNT_HOST"
trap - EXIT
echo "  ok"

echo "All checks passed."
