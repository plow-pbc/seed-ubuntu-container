# seed-ubuntu-container

## Purpose

A SEED that gives any host machine the capability to spin up ephemeral, disposable Ubuntu sandboxes — used by other SEEDs and tooling to install/test in a clean environment.

Not a security boundary: the sandbox runs under the host's container runtime, with passwordless sudo inside, and `--mount` exposes host paths as writable. For untrusted code, use a VM.

## Install

Tell any AI agent:

> Install `git@github.com:plow-pbc/seed-ubuntu-container.git`

## License

MIT.
