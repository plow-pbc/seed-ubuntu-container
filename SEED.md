# Purpose

> See [[README#Purpose]].

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

### Hardware

- amd64 or arm64 CPU. ^dep-cpu
- ~2 GB free disk for the base image plus a few sandboxes. ^dep-disk

### API

- (none) — fully local; no accounts or keys. ^dep-api

### Software

All interactive asks (sudo, confirmation prompts, group-add re-login) are batched at the frontend in `ref/preflight.sh`. Run it first on a fresh host, then the build is non-interactive.

#### 1. Preflight — collect all interactive asks

Display and confirm the following shell block before execution:

```bash
bash ref/preflight.sh
```

This script:

- Detects host. Linux/amd64, Linux/arm64, Darwin/arm64 continue. Darwin/amd64 (Intel Mac) aborts with a clear message. Any other host aborts.
- Detects runtime: `docker` on Linux, `container` on macOS. If missing, the plan names what will be installed and how (sudo on Linux, Homebrew on macOS).
- Prints a single plan to stdout summarizing what will be installed and whether re-login is required.
- Asks a single y/n confirm. On y, runs all install commands non-interactively.
- If `usermod -aG docker $USER` was required, exits non-zero with `"Log out and back in, then re-run preflight"`. Does NOT fall back to `sudo docker`.

#### 2. Build base image

Display and confirm the following shell block before execution:

```bash
bash ref/build-image.sh
```

Idempotent. Builds `seed-ubuntu:<sha256-of-Dockerfile>` if missing. No sudo, no prompts.

## Objects

### `seed-ubuntu:<sha>` image

- The OCI image built from `ref/Dockerfile`. ^obj-image
- Tag is the sha256 of `ref/Dockerfile` content — cross-host reproducibility by content, not tag-bump discipline.
- Built locally on first use; cached for subsequent runs.

### `sandbox.sh` command surface

- `ref/sandbox.sh` exposes four subcommands: `up`, `exec`, `down`, `list`. ^obj-sandbox-sh

### `$SEED_UBUNTU_NAME`

- The suggested env-var convention for consumers when they pick a sandbox name. ^obj-name-var
- Sandbox containers are named `seed-ubuntu-<name>` on the host so `list` can filter cleanly.

### `ref/`

- Sub-folder holding the SEED's runnable artifacts: `Dockerfile`, `preflight.sh`, `build-image.sh`, `sandbox.sh`, `verify.sh`. ^obj-ref
- Not its own sub-SEED; described and contracted in this `SEED.md`.

## Actions

### Sandbox is spun up

- `sandbox.sh up <name>` builds the image if missing, then creates and starts a fresh container named `seed-ubuntu-<name>`. ^act-up
- MUST error if a container with that name already exists; `--recreate` tears down first.
- Accepts `--mount HOST:CONTAINER` to inject a host directory.
- Container runs detached with `CMD ["sleep", "infinity"]` so `exec` works.

### Sandbox is exec'd into

- `sandbox.sh exec <name> -- <cmd> [args...]` runs the command inside the sandbox. ^act-exec
- Streams stdout/stderr. MUST proxy the inner command's exit code.

### Sandbox is torn down

- `sandbox.sh down <name>` stops and removes the container. ^act-down
- MUST be idempotent — no error if the sandbox is missing.

### Sandboxes are listed

- `sandbox.sh list` enumerates all `seed-ubuntu-*` containers on the host. ^act-list

## Verify

A deterministic implementation lives at [`ref/verify.sh`](ref/verify.sh).

1. **Runtime is healthy.** On Linux, does `docker version --format '{{.Server.Version}}'` return a version string? On macOS, does `container --version`? Expected: yes.

2. **Base image is present.** Compute `sha256(ref/Dockerfile)` and check that the local image store contains `seed-ubuntu:<sha>`. Expected: yes.

3. **End-to-end round-trip.** Spin up an ephemeral sandbox via `sandbox.sh up verify-<random>`, exec `echo hello` inside it, expect stdout `hello` and exit code 0, then `sandbox.sh down verify-<random>`. After teardown, the sandbox MUST NOT appear in `sandbox.sh list`. Cleanup runs via `trap` even on failure. Expected: round-trip succeeds, no residue.

## Feedback

(default)

## Open

- No Intel Mac support. If demand emerges, a separate `seed-ubuntu-container-colima` is the path — no in-repo fallback. ^o-intel-mac
- No image pinning by digest in `sandbox.sh up`. `apt-get install` pulls unpinned package versions inside the Dockerfile. Tightening deferred to v1. ^o-pinning
- No `sandbox.sh cp`. Consumers use `--mount` (live) or `exec ... -- bash -c '...'` (snapshot). Add `cp` in v1 if a host-to-sandbox file-copy pattern recurs. ^o-cp
- No Windows host. WSL2 + Docker probably works as a Linux host but is unverified. ^o-windows
- Image tag is content-addressed by Dockerfile source, not built image. amd64 and arm64 builds share a tag locally. Fine for local-only use; revisit if v1 pushes to a registry. ^o-multiarch
- Apple `container` CLI subcommand compatibility with Docker is unverified. `sandbox.sh` assumes `image inspect`, `inspect`, `run -d --name -v`, `exec`, `rm -f`, and `build --tag` overlap with Docker; `list` is the one known-differing surface and already has a case-split. First Mac user to exercise the path reports actual divergence; if other subcommands also differ, refactor those behind per-operation helpers in `ref/lib.sh`. Not preempted because the cost stance is "cut LOC over add" — no parallel API seam built on a guess. ^o-apple-grammar

## Non-Goals

- Not a long-running Ubuntu devbox. Steady state is no running container.
- Not multi-runtime on a single host. Linux = docker; macOS = Apple `container`. No "pick the best of what's installed."
- Not a registry. Image lives locally.
- Not an orchestrator. One sandbox per name; no compose/swarm/pod abstractions.
- Not a Claude Code skill. A `/seed-create` skill would be a downstream consumer that calls `sandbox.sh`.
- Not a security boundary. The sandbox `seed` user has passwordless sudo; `--mount` exposes host paths as writable; preflight's docker-group add is host-root-equivalent (docker's own threat model). For running untrusted code, reach for a VM (Lima, Firecracker), not this SEED.
