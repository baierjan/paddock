# Specification: Paddock — Project-Specific Sandboxed AI Runner

## 1. Overview
**Paddock** is a secure, light-weight, and project-specific sandboxed runtime container environment designed to run AI coding assistants (such as Gemini CLI and Claude Code) in complete isolation from the host system.

Unlike the complex multi-bind approach used in other sandboxes, Paddock utilizes a **Pure Containerfile Layering** strategy and a **Pristine Home Directory** strategy to provide 100% transparent and standard host bind-mounting.

---

## 2. Goals & Success Criteria
*   **Simple Command Interface:** A single, easily-remembered shell command `./paddock.sh` (or native `podman container runlabel`) to build and run sandboxes.
*   **Zero Magic Customizations:** No complex configuration-parsing script or custom DSL. All environment layers are standard, readable `Containerfile`s.
*   **Persistent CLI Configs:** Standard host bind-mounting to `/home/ai` preserves credentials, shell histories, and CLI caches across container runs without named volumes.
*   **Clean System Defaults:** Environment prompts, Git configurations, and standard tools are declared system-wide, keeping `/home/ai` completely empty in the image.

---

## 3. Project Directory Structure
The repository structure is organized as follows:

```text
paddock/
├── profiles/
│   ├── base/
│   │   └── Containerfile       # Defines 'paddock-base:latest'
│   ├── ruby/
│   │   └── Containerfile       # Custom Ruby profile: starts FROM paddock-base:latest
│   └── perl/
│       └── Containerfile       # Custom Perl profile: starts FROM paddock-base:latest
├── paddock.sh                  # Simple execution/orchestration shell script
└── README.md
```

---

## 4. Architectural Details

### 4.1. Base Image (`paddock-base`)
Defined in `profiles/base/Containerfile` using **openSUSE Tumbleweed**.
*   **Security:** Runs as non-root user `ai` (UID: 1000, GID: 1000).
*   **Foundational Packages:** Standard packages for developer environments (`git`, `curl`, `nodejs`, `npm`, `python3`, `pip`, `less`, etc.) and the core AI CLI agents (e.g., `gemini-cli`, `@anthropic-ai/claude-code`).
*   **System-Wide Shell Customization:** 
    *   To keep `/home/ai` completely pristine, the customized `PS1` command prompt is declared globally in `/etc/bash.bashrc.local` or `/etc/profile.d/paddock.sh`.
    *   Global Git settings are declared globally in `/etc/gitconfig`.
*   **Pristine Home Execution:** At the end of the base build, `/home/ai` is thoroughly cleaned of any default shell skeleton files (e.g., `.bashrc`, `.profile`) so it is completely empty.

### 4.2. Custom Profile Images (`paddock:<profile>`)
Custom environments are declared as pure `Containerfile`s under `profiles/<profile>/`.
*   **Format:**
    ```dockerfile
    FROM paddock-base:latest
    USER root

    # Install profile-specific Tumbleweed packages system-wide
    RUN zypper --non-interactive install --no-recommends ruby ruby-devel

    USER ai
    ```
*   **Build command:** 
    ```bash
    podman build -t paddock:ruby -f profiles/ruby/Containerfile .
    ```

---

## 5. Volume Mounts & Persistence Strategy

Paddock uses exactly two high-level host bind-mounts:

1.  **Workspace Mount:** The current working directory is mounted at the static path `/home/ai/sandbox`. Nesting the workspace inside the user's home directory satisfies Git’s security ownership checks without system-wide `safe.directory` overrides. The path is static because `runlabel` performs literal variable substitution only — it cannot evaluate `basename` — and `paddock.sh` delegates to the same label, so both entrypoints behave identically.
    ```bash
    -v "$PWD:/home/ai/sandbox:z" -w "/home/ai/sandbox"
    ```

2.  **Home Mount:**
    A single shared host state directory is mounted directly to `/home/ai` in the container, so every profile reuses the same credentials, history and caches. `runlabel` expands `$HOME` but no other environment variable, so the path is fixed rather than XDG-derived:
    ```bash
    -v "$HOME/.local/share/paddock/homes/default:/home/ai:z"
    ```

### Why this works cleanly:
Because `/home/ai` is completely empty in the image, the host home bind-mount never masks or hides pre-compiled configurations. Any configurations, history files, or API credentials created by AI tools (e.g., `.config/`, `.cache/`, `.gemini/`, `.bash_history`) are natively written to and read from the persistent host directory.

---

## 6. Execution Command (`./paddock.sh`) and Podman `runlabel`

Paddock supports a dual-execution flow:

### 6.1. The CLI Script (`./paddock.sh`)
A simple, portable shell script `./paddock.sh` handles the high-level builder and runner flows.
*   **Build a Profile:**
    ```bash
    ./paddock.sh build <profile>
    ```
    *Builds `paddock-base` if not present, then builds the custom profile.*
*   **Run a Profile:**
    ```bash
    ./paddock.sh run <profile>
    ```
    *Prepares the local host home directory (`~/.local/share/paddock/homes/default`), ensures the profile image exists, then delegates the launch to `podman container runlabel run paddock:<profile>`.*

### 6.2. Podman `runlabel` Integration
Each profile's `Containerfile` includes a `LABEL run` indicating how it should be launched. For example:
```dockerfile
LABEL run="podman run --rm --interactive --tty \
  --runtime krun \
  --network pasta \
  --annotation krun.use_passt=1 \
  --annotation krun.ram_mib=8192 \
  --annotation krun.cpus=4 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=2048m \
  --pids-limit 1024 \
  --hostname paddock-latest \
  --user ai \
  --userns keep-id:uid=1000,gid=1000 \
  --volume \$HOME/.local/share/paddock/homes/default:/home/ai:z \
  --volume \$PWD:/home/ai/sandbox:z \
  --workdir /home/ai/sandbox \
  paddock:latest"
```
This enables running the sandbox directly using standard Podman, completely bypassing the shell script:
```bash
podman container runlabel run paddock:latest
```

---

## 7. Plan for Verification and Testing
*   **Base Image Verification:** Build the base image, run it with an empty home, and verify that custom system prompts and Git configurations load correctly.
*   **Profile Image Verification:** Build a custom profile (e.g., `ruby` or `perl`), verify that it correctly builds on top of the base, and verify that the custom packages are available.
*   **Persistent Mount Verification:** Run a profile with the home bind-mount, perform tool authorization/file writing, exit, run it again, and confirm the configurations are persisted and fully functioning.
