<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-header-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/logo-header-light.png">
    <img alt="Paddock" src="docs/logo-header-light.png">
  </picture>
</p>

**Paddock** is a secure, lightweight, project-specific sandboxed runtime container environment designed to run AI coding assistants (such as OpenCode and Gemini CLI) in complete, virtualized isolation from your host system.

Unlike complex multi-bind sandboxes, Paddock utilizes a single plain **Containerfile** and a **Pristine Home Directory** strategy to provide 100% transparent and standard host bind-mounting under a highly hardened, VM-level virtualization boundary.

---

## Prerequisites & Requirements

### Host Environment for Sandboxing (`run`)
*   **Linux Host** with KVM support (microVM sandboxing is Linux-only).
*   Rootless **Podman** container engine.
*   The **`krun`** container runtime (or `libkrun`) and the **`pasta`** network isolator.

### Host Environment for Automatic Upgrades (`upgrade`)
*   **`curl`**: Used to query latest stable version metadata from the NPM registry.
*   **`jq`**: Used to parse JSON payloads.
*   **`openssl`**: Used for portable, cross-platform Base64-to-Hex conversions of registry integrity hashes.

---

## Key Features

1.  **Simple Command Interface:** A single, easily-remembered shell command `./paddock.sh` (or native `podman container runlabel`) to build and run sandboxes.
2.  **MicroVM Virtualization (`krun`):** Shakes off standard shared-kernel container namespace boundaries, executing the sandbox cleanly inside its own KVM-backed microVM using `libkrun` and the `krun` runtime.
3.  **Tightly Hardened Sandbox:** Out-of-the-box system-wide hardening:
    - Strips all Linux capabilities (`--cap-drop ALL`).
    - Disables all privilege escalation paths (`no-new-privileges`).
    - Mounts the system root filesystem as **read-only** (`--read-only`).
    - Secures `/tmp` inside an in-memory, size-limited, non-executable filesystem (`tmpfs` with `noexec,nosuid,nodev`).
    - Restricts runaway processes or fork-bombs (`--pids-limit`).
4.  **Pasta Network Isolation:** Combines isolated network namespaces via modern `pasta` with `passt` translation annotations (`krun.use_passt=1`) for high-performance and secure network sandboxing.
5.  **MicroVM Resource Capping:** Restricts the guest VM from consuming host resources using libkrun annotations:
    - Caps the guest's available RAM (`krun.ram_mib`).
    - Restricts the number of virtual CPU cores (`krun.cpus`).
6.  **Secure Workspace Mounting:** Automatically mounts the current host directory at `/home/ai/sandbox` inside the container.
7.  **Persistent CLI Configs:** Standard host bind-mounting to the unprivileged `/home/ai` folder preserves credentials, shell histories, and CLI caches across container runs without named volumes.
8.  **Clean System Defaults:** Environment prompts and standard tools are declared system-wide, keeping `/home/ai` completely empty in the image.

> The concrete limits (RAM, vCPU count, `/tmp` size, PID cap) are intentionally not
> reproduced here. They are baked into the image at build time by `paddock.sh`
> itself (see `run_label()`), overridable via `PADDOCK_RAM_MIB`, `PADDOCK_CPUS`,
> `PADDOCK_PIDS_LIMIT` and `PADDOCK_TMP_SIZE`. `run` picks up a changed env var
> automatically on its next invocation.

---

## Project Structure

```text
paddock/
├── profile/
│   ├── entrypoint.sh       # Secure guest VM privilege-dropping entrypoint
│   └── Containerfile       # Builds 'paddock:latest'
├── packaging/              # OBS/RPM packaging (spec, changes)
├── docs/                   # Branding assets used by this README
├── paddock.sh              # Simple execution/orchestration shell script
├── test_paddock.sh         # Automated mock-based test suite
└── README.md
```

---

## Getting Started

### 1. Build the Image
```bash
./paddock.sh build
```
`build` unconditionally (re)builds the image; run it again any time you edit the `Containerfile` or
`entrypoint.sh`. `run` builds automatically too, but only when the image is missing or its baked-in
run label is out of date (e.g. a `PADDOCK_*` env var changed) — it does not pick up a Containerfile
edit on its own, so run `build` explicitly after one.

#### Overriding the Containerfile
The image can be personally customized without touching a tracked file: a
`~/.local/share/paddock/Containerfile`, if present, takes precedence over the shipped
`profile/Containerfile`. It still builds and runs as `paddock:latest` regardless of which
Containerfile backs it, and still gets the same `paddock.sh`-baked run label (see below) as the
shipped Containerfile. This works whether `paddock.sh` was checked out from git or installed
system-wide.

#### Bundled AI Assistants
The image installs both `opencode` and the Gemini CLI (`@google/gemini-cli`) globally, alongside
the Google Cloud CLI. No build-time selection is required.

> Because the Google Cloud CLI is published only for `x86_64`, the image is **x86_64-only**.

### 2. Run the Sandbox
To run your project inside a sandbox:
```bash
./paddock.sh run
```
This automatically:
*   Prepares a persistent local home folder on the host at `~/.local/share/paddock/home`.
*   Delegates the launch to the image's `LABEL run` via `podman container runlabel`, mounting the current directory at `/home/ai/sandbox`.
*   Starts an interactive bash shell as the non-root `ai` user in that workspace.

---

## Native Podman `runlabel` Support
The image carries a `LABEL run`, baked in by `paddock.sh` at build time (see "Key Features" above), which is the single definition of every mount and security flag. `./paddock.sh run` simply invokes it, so running Podman directly is equivalent and needs no checkout of this repository:
```bash
podman container runlabel run paddock:latest
```
The label deliberately omits `--name`, so Podman assigns a unique container name on each launch and
you can run sandboxes from several directories concurrently. Use `podman ps` to find the generated
name.

---

## Architecture: Pristine Home Directory & Guest Privilege Dropping
To prevent container file masking (hiding pre-installed files inside the image), Paddock ensures `/home/ai` in the image is **completely empty**:
*   Custom terminal prompts are initialized globally via `starship` in `/etc/bash.bashrc`.
*   Any shell commands run inside write persistent caches natively to the host's `~/.local/share/paddock/home`, which is bind-mounted directly to `/home/ai`.

Additionally, to work seamlessly inside virtualized **`krun`** environments (where guest kernels boot standard entrypoints as root by default), Paddock includes a secure `/usr/local/bin/entrypoint.sh` privilege-dropper. This utility dynamically captures the container's starting directory, registers the `ai` user's environmental properties, and utilizes `setpriv` to drop all VM-level permissions down to the unprivileged `ai` user before spawning your shell.

---

## Testing & Verification
Paddock includes a robust automated mock-based integration test suite. You can run it on any Linux or macOS environment to verify script behavior and container argument generation without needing `podman` fully installed:
```bash
./test_paddock.sh
```

---

## License
Paddock is released under the terms of the [Apache License, Version 2.0 (Apache-2.0)](LICENSE).

Copyright (C) 2026 Jan Baier <jbaier@suse.cz>
