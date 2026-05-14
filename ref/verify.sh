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

TOTAL=9

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Runtime is healthy.
echo "[1/$TOTAL] Runtime is healthy ($RUNTIME)..."
case "$RUNTIME" in
  docker)    docker version --format '{{.Server.Version}}' >/dev/null || fail "docker not responsive" ;;
  container) container --version >/dev/null || fail "apple container CLI not responsive" ;;
esac
echo "  ok"

# 2. Base image is present.
echo "[2/$TOTAL] Base image $IMAGE_TAG is present..."
"$RUNTIME" image inspect "$IMAGE_TAG" >/dev/null 2>&1 \
  || fail "image $IMAGE_TAG not found; run ref/build-image.sh"
echo "  ok"

# 3. End-to-end round-trip. Spin up, exec echo hello, down, confirm no residue.
SANDBOX_NAME="verify-$$-$RANDOM"
FULL_NAME="$(full_name "$SANDBOX_NAME")"

cleanup() {
  bash ref/sandbox.sh down "$SANDBOX_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[3/$TOTAL] End-to-end round-trip ($SANDBOX_NAME)..."

bash ref/sandbox.sh up "$SANDBOX_NAME" >/dev/null || fail "sandbox.sh up failed"

# Positive list assertion: running sandbox MUST appear in list output.
bash ref/sandbox.sh list | grep -Fxq "$FULL_NAME" \
  || fail "list did not include running sandbox $FULL_NAME"

OUT="$(bash ref/sandbox.sh exec "$SANDBOX_NAME" -- echo hello)"
[ "$OUT" = "hello" ] || fail "expected 'hello', got '$OUT'"

bash ref/sandbox.sh down "$SANDBOX_NAME" >/dev/null || fail "sandbox.sh down failed"

# Confirm no residue.
! bash ref/sandbox.sh list | grep -q "$FULL_NAME" \
  || fail "sandbox $FULL_NAME still present after down"

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
! bash ref/sandbox.sh exec "$NEG_NAME" -- false \
  || fail "'sandbox.sh exec ... -- false' returned 0; exit code not proxied"
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
[ "$GOT" = "$EXPECTED" ] || fail "--mount round-trip: expected '$EXPECTED', got '$GOT'"
bash ref/sandbox.sh down "$MNT_NAME" >/dev/null
rm -rf "$MNT_HOST"
trap - EXIT
echo "  ok"

# 6. Collision: a second `up` with the same name MUST fail.
COL_NAME="verify-col-$$-$RANDOM"
cleanup_col() {
  bash ref/sandbox.sh down "$COL_NAME" >/dev/null 2>&1 || true
}
trap cleanup_col EXIT
echo "[6/$TOTAL] up rejects duplicate name without --recreate..."
bash ref/sandbox.sh up "$COL_NAME" >/dev/null
! bash ref/sandbox.sh up "$COL_NAME" >/dev/null 2>&1 \
  || fail "second 'up' without --recreate should have errored"
echo "  ok"

# 7. --recreate: replaces an existing sandbox in place. The current container
#    keeps the same name and is usable for exec.
echo "[7/$TOTAL] --recreate replaces existing sandbox..."
bash ref/sandbox.sh up "$COL_NAME" --recreate >/dev/null
OUT="$(bash ref/sandbox.sh exec "$COL_NAME" -- echo recreated)"
[ "$OUT" = "recreated" ] || fail "--recreate sandbox not usable; got '$OUT'"
bash ref/sandbox.sh down "$COL_NAME" >/dev/null
trap - EXIT
echo "  ok"

# 8. Idempotent down: `down` on a never-created name MUST exit 0.
echo "[8/$TOTAL] down on absent sandbox exits 0..."
bash ref/sandbox.sh down "verify-absent-$$-$RANDOM" >/dev/null \
  || fail "down on never-created sandbox should be a no-op"
echo "  ok"

# 9. preflight aborts on unsupported host (the SEED's explicit fail-fast
#    guarantee: no Colima fallback, no silent substitution).
echo "[9/$TOTAL] preflight aborts on Intel Mac..."
! echo y | UNAME_S=Darwin UNAME_M=x86_64 bash ref/preflight.sh >/dev/null 2>&1 \
  || fail "preflight should have aborted on Darwin/x86_64 (Intel Mac)"
echo "  ok"

echo "All checks passed."
