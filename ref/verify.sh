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

TOTAL=14
# Apple `container` doesn't have a docker-style cross-object name namespace
# (image/volume/network/container all share names), so the volume-collision
# probe at the end is docker-only — extra prompt on docker hosts. The
# daemon-error propagation probe in [15] is also docker-only because it
# shadows the `docker` binary in PATH to simulate failure.
[ "$RUNTIME" = "docker" ] && TOTAL=16

SANDBOX=ref/sandbox.sh
fail()    { echo "FAIL: $*" >&2; exit 1; }
sb_up()   { bash "$SANDBOX" up   "$@"; }
sb_exec() { bash "$SANDBOX" exec "$@"; }
sb_down() { bash "$SANDBOX" down "$@"; }
sb_list() { bash "$SANDBOX" list      ; }
cleanup_sandbox() { sb_down "$1" >/dev/null 2>&1 || true; }

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

trap 'cleanup_sandbox "$SANDBOX_NAME"' EXIT

echo "[3/$TOTAL] End-to-end round-trip ($SANDBOX_NAME)..."

sb_up "$SANDBOX_NAME" >/dev/null || fail "sandbox.sh up failed"

# Positive list assertion: running sandbox MUST appear in list output.
sb_list | grep -Fxq "$FULL_NAME" \
  || fail "list did not include running sandbox $FULL_NAME"

OUT="$(sb_exec "$SANDBOX_NAME" -- echo hello)"
[ "$OUT" = "hello" ] || fail "expected 'hello', got '$OUT'"

sb_down "$SANDBOX_NAME" >/dev/null || fail "sandbox.sh down failed"

# Confirm no residue.
! sb_list | grep -q "$FULL_NAME" \
  || fail "sandbox $FULL_NAME still present after down"

trap - EXIT
echo "  ok"

# 4. Exec proxies inner exit code. `false` inside the sandbox must exit non-zero
#    via the host wrapper — pins the documented "MUST proxy the inner command's
#    exit code" contract.
NEG_NAME="verify-neg-$$-$RANDOM"
trap 'cleanup_sandbox "$NEG_NAME"' EXIT
echo "[4/$TOTAL] exec proxies non-zero exit ($NEG_NAME)..."
sb_up "$NEG_NAME" >/dev/null
! sb_exec "$NEG_NAME" -- false \
  || fail "'sandbox.sh exec ... -- false' returned 0; exit code not proxied"
sb_down "$NEG_NAME" >/dev/null
trap - EXIT
echo "  ok"

# 5. --mount round-trip with TWO mounts. Repeated --mount flags MUST stack
#    (not overwrite), so consumers can inject workspace + config separately.
MNT_NAME="verify-mnt-$$-$RANDOM"
MNT_A="$(mktemp -d)"
MNT_B="$(mktemp -d)"
# mktemp creates 0700; widen to 0777 so this test works regardless of the
# host user's UID (test machine may not be UID 1000).
chmod 0777 "$MNT_A" "$MNT_B"
echo "payload-A-$RANDOM" > "$MNT_A/probe"
echo "payload-B-$RANDOM" > "$MNT_B/probe"
EXP_A="$(cat "$MNT_A/probe")"
EXP_B="$(cat "$MNT_B/probe")"
trap 'cleanup_sandbox "$MNT_NAME"; rm -rf "$MNT_A" "$MNT_B"' EXIT
echo "[5/$TOTAL] --mount round-trip with two mounts ($MNT_NAME)..."
sb_up "$MNT_NAME" --mount "$MNT_A:/a" --mount "$MNT_B:/b" >/dev/null

# Read: both mounts visible from inside.
GOT_A="$(sb_exec "$MNT_NAME" -- cat /a/probe)"
GOT_B="$(sb_exec "$MNT_NAME" -- cat /b/probe)"
[ "$GOT_A" = "$EXP_A" ] || fail "--mount A: expected '$EXP_A', got '$GOT_A'"
[ "$GOT_B" = "$EXP_B" ] || fail "--mount B (later mount lost?): expected '$EXP_B', got '$GOT_B'"

# Write: container writes a file into /a, host MUST see it. Pins the
# README's "writable mount" promise — the sandbox user (uid 1000, matching
# typical Linux devs) can write through bind-mounts without sudo.
WROTE="wrote-from-sandbox-$RANDOM"
sb_exec "$MNT_NAME" -- bash -c "echo $WROTE > /a/written"
[ -f "$MNT_A/written" ] || fail "--mount A: write from sandbox did not reach host (no file)"
[ "$(cat "$MNT_A/written")" = "$WROTE" ] \
  || fail "--mount A: write from sandbox reached host but content mismatched"

sb_down "$MNT_NAME" >/dev/null
rm -rf "$MNT_A" "$MNT_B"
trap - EXIT
echo "  ok"

# 6. Collision: a second `up` with the same name MUST fail.
COL_NAME="verify-col-$$-$RANDOM"
trap 'cleanup_sandbox "$COL_NAME"' EXIT
echo "[6/$TOTAL] up rejects duplicate name without --recreate..."
sb_up "$COL_NAME" >/dev/null
! sb_up "$COL_NAME" >/dev/null 2>&1 \
  || fail "second 'up' without --recreate should have errored"
echo "  ok"

# 7. --recreate: replaces an existing sandbox in place. The current container
#    keeps the same name and is usable for exec.
echo "[7/$TOTAL] --recreate replaces existing sandbox..."
sb_up "$COL_NAME" --recreate >/dev/null
OUT="$(sb_exec "$COL_NAME" -- echo recreated)"
[ "$OUT" = "recreated" ] || fail "--recreate sandbox not usable; got '$OUT'"
sb_down "$COL_NAME" >/dev/null
trap - EXIT
echo "  ok"

# 8. Idempotent down: `down` on a never-created name MUST exit 0.
echo "[8/$TOTAL] down on absent sandbox exits 0..."
sb_down "verify-absent-$$-$RANDOM" >/dev/null \
  || fail "down on never-created sandbox should be a no-op"
echo "  ok"

# 9. preflight aborts on Intel Mac (named arm of detect_runtime's matrix).
echo "[9/$TOTAL] preflight aborts on Intel Mac..."
! echo y | UNAME_S=Darwin UNAME_M=x86_64 bash ref/preflight.sh >/dev/null 2>&1 \
  || fail "preflight should have aborted on Darwin/x86_64 (Intel Mac)"
echo "  ok"

# 10. preflight aborts on any other unsupported host (catch-all arm).
echo "[10/$TOTAL] preflight aborts on other unsupported host..."
! echo y | UNAME_S=FreeBSD UNAME_M=amd64 bash ref/preflight.sh >/dev/null 2>&1 \
  || fail "preflight should have aborted on FreeBSD/amd64"
echo "  ok"

# 11. Container identity. Pins both ends of the writable-mount contract:
#     the sandbox user MUST be uid 1000 (so it matches a typical Linux dev
#     host) AND MUST have passwordless sudo (so consumer SEED installs that
#     need root can run unattended). The chmod 0777 in prompt 5 is for
#     test portability; this prompt pins the actual contract.
ID_NAME="verify-id-$$-$RANDOM"
trap 'cleanup_sandbox "$ID_NAME"' EXIT
echo "[11/$TOTAL] container user is uid 1000 with passwordless sudo..."
sb_up "$ID_NAME" >/dev/null
USER_UID="$(sb_exec "$ID_NAME" -- id -u)"
[ "$USER_UID" = "1000" ] || fail "container user uid expected 1000, got '$USER_UID'"
sb_exec "$ID_NAME" -- sudo -n true \
  || fail "container user lacks passwordless sudo"
sb_down "$ID_NAME" >/dev/null
trap - EXIT
echo "  ok"

# 12. --mount host path validation. A missing host path MUST abort with a
#     clear message, not silently auto-create a root-owned dir. A relative
#     host path MUST abort separately even if it exists, because docker -v
#     would treat 'name:/x' as a named volume, not a bind mount.
echo "[12/$TOTAL] --mount rejects missing and relative host paths..."

MISSING="/tmp/verify-absent-$$-$RANDOM"
[ -e "$MISSING" ] && fail "test setup bug: $MISSING shouldn't exist"
! sb_up "verify-mnt-miss-$$-$RANDOM" --mount "$MISSING:/x" >/dev/null 2>&1 \
  || fail "--mount with missing host path should have errored"

# Create a real relative directory so the existence guard passes; the
# absolute-path guard is then what MUST reject this. Without an existing
# relative dir, this prompt would only exercise the existence guard.
REL_DIR="verify-rel-$$-$RANDOM"
mkdir "$REL_DIR"
trap 'rmdir "$REL_DIR" 2>/dev/null || true' EXIT
! sb_up "verify-mnt-rel-$$-$RANDOM" --mount "$REL_DIR:/x" >/dev/null 2>&1 \
  || fail "--mount with existing relative host path should have errored (absolute guard didn't fire)"
rmdir "$REL_DIR"
trap - EXIT

# Colonless --mount must error too — docker -v with a single absolute path
# creates an anonymous volume, not a bind mount, so writes don't reach the
# host caller expected.
! sb_up "verify-mnt-nocolon-$$-$RANDOM" --mount "/tmp" >/dev/null 2>&1 \
  || fail "--mount without colon (HOST only) should have errored"
echo "  ok"

# 13. Preflight install grammar on Darwin/arm64. Pins the two macOS-specific
#     commands the v0 install path depends on: `brew install container`
#     (formula, not --cask) and `container system start --enable-kernel-install`
#     (non-interactive kata kernel install). PATH-shadows `brew` and the
#     `container` binary it materializes, so this runs unconditionally — a
#     contributor on Linux can still catch a regression on the macOS path.
#     Reuses test 9's UNAME_S env-var override seam and test 14's PATH-shadow
#     seam.
echo "[13/$TOTAL] preflight install grammar on Darwin/arm64..."
PFB_DIR="$(mktemp -d)"
PFB_LOG="$PFB_DIR/calls.log"
trap 'rm -rf "$PFB_DIR"' EXIT
# Outer heredoc unquoted: $PFB_LOG and $PFB_DIR resolve to real paths at
# write time, but \$*/\$1/\$2 are escaped so fake-brew evaluates them at run
# time. Inner heredoc single-quoted: $* and $FAKE_LOG stay literal, deferred
# to fake-container's run-time env.
cat > "$PFB_DIR/brew" <<FAKE
#!/usr/bin/env bash
echo "brew \$*" >> "$PFB_LOG"
if [ "\$1" = "install" ] && [ "\$2" = "container" ]; then
  cat > "$PFB_DIR/container" <<'INNER'
#!/usr/bin/env bash
echo "container \$*" >> "\$FAKE_LOG"
INNER
  chmod +x "$PFB_DIR/container"
fi
FAKE
chmod +x "$PFB_DIR/brew"
# Scrubbed PATH ($PFB_DIR plus /usr/bin:/bin for `bash` itself). Without this,
# a real `container` binary on the host (e.g. /opt/homebrew/bin/container)
# would shadow the to-be-installed fake, preflight would skip the install
# branch, and the regression check would silently pass.
PFB_OUT="$(echo y | FAKE_LOG="$PFB_LOG" UNAME_S=Darwin UNAME_M=arm64 \
  PATH="$PFB_DIR:/usr/bin:/bin" bash ref/preflight.sh)" \
  || fail "preflight should succeed on Darwin/arm64 with brew on PATH"
grep -Fxq "brew install container" "$PFB_LOG" \
  || fail "preflight must call 'brew install container' (formula, not --cask)"
grep -Fxq "container system start --enable-kernel-install" "$PFB_LOG" \
  || fail "preflight must pass --enable-kernel-install (non-interactive kata kernel)"
# Plan-print is part of the user-facing install contract (SEED.md says
# "display and confirm the following shell block before execution"). Pin
# that the printed plan matches what actually executes, so the two can't
# drift silently.
printf '%s\n' "$PFB_OUT" | grep -Fq "brew install container" \
  || fail "preflight plan must print 'brew install container'"
printf '%s\n' "$PFB_OUT" | grep -Fq "container system start --enable-kernel-install" \
  || fail "preflight plan must print 'container system start --enable-kernel-install'"
rm -rf "$PFB_DIR"
trap - EXIT
echo "  ok"

# 14. sandbox.sh list (Darwin) uses the Apple `container list --all --quiet`
#     grammar. Apple's CLI rejects Docker-style `--format '{{.Names}}'`, so a
#     regression here would silently fail on macOS but pass on Linux/Docker
#     CI. PATH-shadows a fake `container` that ONLY accepts `list --all
#     --quiet` (with exactly 3 args) — any drift in argv shape errors loud.
#     Reuses test 9's UNAME_S override and test 13's PATH-shadow seam.
echo "[14/$TOTAL] sandbox.sh list (Darwin) uses 'container list --all --quiet'..."
CLG_DIR="$(mktemp -d)"
trap 'rm -rf "$CLG_DIR"' EXIT
cat > "$CLG_DIR/container" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "list" ] && [ "$2" = "--all" ] && [ "$3" = "--quiet" ] && [ $# = 3 ]; then
  printf '%s\n' "seed-ubuntu-listprobe" "not-a-seed-prefix"
  exit 0
fi
echo "fake container: unexpected argv '$*'" >&2
exit 2
FAKE
chmod +x "$CLG_DIR/container"
got="$(UNAME_S=Darwin UNAME_M=arm64 PATH="$CLG_DIR:/usr/bin:/bin" bash ref/sandbox.sh list)" \
  || fail "sandbox.sh list must call 'container list --all --quiet' (no --format template)"
[ "$got" = "seed-ubuntu-listprobe" ] \
  || fail "sandbox.sh list NAME_PREFIX filter broken — got '$got', expected 'seed-ubuntu-listprobe'"
rm -rf "$CLG_DIR"
trap - EXIT
echo "  ok"

# 15. (Docker only) cmd_down propagates real runtime errors. `inspect` failing
#     doesn't mean "absent" — that's the bug we fixed by switching to a
#     list-and-filter query. Pin it by faking docker as a binary that always
#     exits non-zero; sandbox.sh down must propagate. Apple `container` doesn't
#     share the docker binary name, so the PATH shadow can't bite on macOS.
if [ "$RUNTIME" = "docker" ]; then
  echo "[15/$TOTAL] cmd_down propagates daemon errors..."
  FAKE_BIN="$(mktemp -d)"
  trap 'rm -rf "$FAKE_BIN"' EXIT
  cat > "$FAKE_BIN/docker" <<'FAKE'
#!/usr/bin/env bash
echo "fake docker: simulated daemon error" >&2
exit 1
FAKE
  chmod +x "$FAKE_BIN/docker"
  ! PATH="$FAKE_BIN:$PATH" sb_down "verify-fake-$$-$RANDOM" >/dev/null 2>&1 \
    || fail "sandbox.sh down should have propagated fake-docker failure (regressed back to inspect-and-swallow?)"
  rm -rf "$FAKE_BIN"
  trap - EXIT
  echo "  ok"
fi

# 16. (Docker only) cmd_up's collision check must NOT match non-container
#     docker objects. Round-10 narrowed from `docker inspect` (matches
#     containers/images/volumes/networks) via `cmd_list` (containers only).
#     If someone reverts to broad inspect, a same-named docker volume
#     would falsely block `sandbox.sh up`. Apple `container` doesn't share
#     this namespace so the probe is docker-only.
if [ "$RUNTIME" = "docker" ]; then
  echo "[16/$TOTAL] cmd_up ignores non-container docker objects..."
  VOL_NAME="verify-vol-$$-$RANDOM"
  FULL_VOL="$(full_name "$VOL_NAME")"
  docker volume create "$FULL_VOL" >/dev/null
  trap 'cleanup_sandbox "$VOL_NAME"; docker volume rm -f "$FULL_VOL" >/dev/null 2>&1 || true' EXIT
  sb_up "$VOL_NAME" >/dev/null \
    || fail "sandbox.sh up errored on volume-name collision (regressed to broad inspect?)"
  sb_down "$VOL_NAME" >/dev/null
  docker volume rm -f "$FULL_VOL" >/dev/null
  trap - EXIT
  echo "  ok"
fi

echo "All checks passed."
