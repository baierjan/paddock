# AGENTS.md — Paddock

Paddock builds hardened, krun/microVM-backed Podman sandboxes for AI coding CLIs.
The entire project is Bash + Containerfiles: no package manager, no build system, no CI.

## Commands

```bash
./test_paddock.sh            # lint + tests; the only verification step
./paddock.sh build [profile]   # build only if missing or out of date (base cascades)
./paddock.sh rebuild [profile] # always build, ignoring the staleness check (base too)
./paddock.sh run [profile]     # build if needed, then launch; 'base' is rejected (no LABEL run)
podman container runlabel run paddock:latest   # equivalent, needs no checkout
```

`profile` defaults to `default`, which always builds/runs as tag `paddock:latest` regardless of
which Containerfile backs it — see "Profiles are personally overridable" below.

`test_paddock.sh` is offline: it shims `podman` via a generated `mock_bin/` on `PATH` and asserts
the exact logged command lines. It does **not** need podman/krun installed — keep it that way; new
tests must go through the mock, never a real container runtime.

**Lint gate:** the suite runs `shellcheck` over every `*.sh` in the repo (`mock_*` excluded) *before*
the functional tests and aborts on any finding — all shell here must stay shellcheck-clean, warnings
included. New scripts are picked up automatically. If `shellcheck` is absent the suite prints
`SKIP: ... LINT GATE NOT ENFORCED` and continues, so a green run on a host without it proves less
than it appears; `ShellCheck` ships in the `default` profile, so running inside a paddock sandbox
always enforces the gate.

### Test-suite gotchas

- On failure (`set -e`) cleanup is skipped and `mock_bin/` and `mock_home/` are left in the repo
  root — they are placed relative to `BASH_SOURCE`, not the CWD, so they land there wherever you
  invoke the suite from. `.gitignore` covers both — delete them before `git add` regardless.
- Each test states its own preconditions via `MOCK_IMAGES` (space-separated tags that "exist") and
  `MOCK_IMAGE_EPOCH` (image creation time; the far-future default means "current", `0` means
  "stale"). There is no shared mock state and no ordering between tests — keep it that way rather
  than reintroducing appended handlers.
- `reset_log()` clears the mock log at the start of every test, so cross-test contamination isn't
  the concern `assert_last_log` guards against. Tests 5, 7 and 8 use it because a build can
  legitimately precede the final action within a *single* test (e.g. Test 8 rebuilds a stale image
  before launching it) — exact-match on the tail line proves the launch happened **last**, not
  merely that it happened somewhere in that test's log.
- `label_run()` flattens `LABEL run` for Test 13 and leaves `$HOME`/`$PWD` **unexpanded** — the
  label is asserted in its stored form, since podman expands those at launch.
- The mock answers `image inspect` with `${MOCK_IMAGE_EPOCH:-9999999999}`, so images look current by
  default and the staleness check stays inert. Tests 4 and 8 set `MOCK_IMAGE_EPOCH=0` to force the
  rebuild path (build and run respectively); Tests 3 and 7 assert the opposite (no spurious
  rebuild). Prefer that env var over touching file mtimes.
- Tests 11-12 create and remove real `Containerfile`s under the mock `HOME`'s
  `.local/share/paddock/profiles/<name>/` to exercise the override described in "Profiles are
  personally overridable" below. Since `HOME` is redirected to `mock_home/` for the whole suite
  (see above), these never touch a real `~/.local/share/paddock/`; a failure mid-test leaves them
  under `mock_home/`, which is deleted along with it.

## The flag list has exactly one home

`profiles/<profile>/Containerfile` `LABEL run=...` is the **sole** definition of every mount,
annotation and security flag. `paddock.sh run` does not build a `podman run` line at all — it calls
`podman container runlabel run paddock:<profile>` and lets podman expand the label. Adding a
`podman run` back into `paddock.sh` would recreate the duplication this design removed.

Consequences worth knowing:

- **The limits are baked into the image**, so an out-of-date image would apply out-of-date limits.
  `ensure_image()` guards this: `paddock.sh run` compares the image's creation time
  (`podman image inspect --format '{{.Created.Unix}}'`) against the mtimes of the profile's
  `Containerfile`/`entrypoint.sh`, and against the base image, rebuilding whatever is behind. Base
  is checked first so a base change cascades. `build` and `run` share this path; `rebuild` skips
  the check and always builds. `build_profile()` is a pure builder and the single place an unknown
  profile is rejected — keep dependency ordering in its callers, or base gets built twice. Editing
  `LABEL run` therefore takes effect on the next `build`/`run`, but a bare `podman container
  runlabel` does **not** get this and needs `./paddock.sh rebuild`.
- **The mock cannot see the flags.** Since podman resolves the label internally, `test_paddock.sh`
  only observes `podman container runlabel run <tag>`. Test 13 therefore asserts the required
  controls textually against the label (`--cap-drop ALL`, `--read-only`, `no-new-privileges`,
  `--user ai`, `--userns keep-id`, `noexec` on `/tmp`, `--network pasta`, `--runtime krun`, and the
  presence of `--pids-limit` / `krun.ram_mib` / `krun.cpus`). Tunable *values* are deliberately not
  pinned, so limits can be retuned without touching the suite. Add new security flags to that list.
- **`docs/design.md` §6.2 quotes the whole `LABEL run`** and goes stale silently — docs only.
- `README.md` describes the flags **by name, with no numeric values**. Do not re-add concrete limits.

`runlabel` expands only `$HOME`, `$PWD`, `$IMAGE`, `$NAME` and `$OPT1..3` (the last three via hidden
`--opt1..3` flags); everything else silently becomes `""`. The man page's VARIABLES section omits
`HOME` and the `OPT`s — trust `pkg/domain/infra/abi/containers_runlabel.go` over the docs. Two
consequences: the label cannot express anything derived (no `basename`, no string ops), and because
podman does `os.Expand` then `shlex.Split`, **a `$PWD` or `$HOME` containing a space breaks the
argv** (it fails loudly as image-not-found, not silently).

`LABEL run` deliberately omits `--name` so concurrent launches from different directories get
unique auto-generated names. A path cannot go there anyway: podman's `NameRegex` is
`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`, which rejects `$PWD` for its slashes.

## Profiles are personally overridable

Every profile can be overridden without touching the shipped tree: `containerfile_for()` checks
`~/.local/share/paddock/profiles/<profile>/Containerfile` first and falls back to the shipped
`profiles/<profile>/Containerfile` only if no override exists. This is the single override
mechanism for every profile name, including `base` — there is no special-cased name. It lives under
`~/.local/share/paddock/`, alongside the persistent sandbox homes (`run_profile()`'s
`~/.local/share/paddock/homes/<profile>`), because that tree is already the project's convention for
machine-local, never-shipped state, and — unlike a path inside the repo/install tree — it is
writable regardless of whether `paddock.sh` was checked out from git or installed system-wide
(e.g. from a package, under a read-only `/usr/share/paddock`).

Regardless of which file backs a profile, its image tag is derived from the profile name alone
(`image_tag()`), never from which Containerfile produced it. This is deliberate:
`podman container runlabel run paddock:latest` and every doc reference to that tag must keep working
whether or not a personal override exists for `default`.

Worth knowing:

- **The override key is the profile name itself.** Overriding `default` means creating
  `~/.local/share/paddock/profiles/default/Containerfile`; overriding `base` means
  `~/.local/share/paddock/profiles/base/Containerfile`. There is no indirection through a
  differently-named directory. Tests 11-12 pin that an override for one profile has no effect on
  another.
- **`ensure_image()` validates the profile even when its image already exists.** A profile's tag is
  unique to its name, but that alone doesn't prove the Containerfile behind it (shipped or
  overridden) is still there — e.g. the override could have been deleted since the image was last
  built. `ensure_image()` calls `assert_profile()` unconditionally, before the "does the tag already
  exist" fast path, to close this.
- **An override Containerfile still builds with the repo/install root as its context**
  (`podman build -f <containerfile> "$ROOT_DIR"`, same as every other profile — see "Build context"
  under Architecture constraints). A `COPY` in an override resolves relative to `$ROOT_DIR`, not to
  the override's own directory under `~/.local/share/paddock/`.

## Architecture constraints

- **Pristine home**: `/home/ai` must stay completely empty in the image (`useradd --no-create-home`,
  manual `mkdir`). The host home bind-mount over `/home/ai` would otherwise mask baked-in files.
  Put shell config in `/etc/bash.bashrc` (starship is initialized there), never in `/home/ai`.
- **Entrypoint privilege drop**: `profiles/base/entrypoint.sh` re-execs itself via `setpriv` when
  the guest kernel boots it as UID 0 (krun does this despite `--user ai`). It re-`cd`s to the
  captured `$PWD` because `setpriv --init-groups` loses it.
- **Build context is the repo root** for every profile (`podman build -f <profile>/Containerfile $ROOT_DIR`);
  `profiles/base/Containerfile` relies on this for `COPY profiles/base/entrypoint.sh`.
- **`paddock-base` is x86_64-only.** It unconditionally installs the Google Cloud CLI from the
  `cloud-sdk-el10-x86_64` repo, which publishes no other architecture. There is no build-time
  switch to opt out — assistants (`@google/gemini-cli` + `opencode-ai`) are fixed, not selectable.
- Host prerequisites for `run` (not for tests): rootless podman, the `krun` runtime, and `pasta`.

## Conventions

**Profile Containerfiles:** `FROM paddock-base:latest` → `USER root` → `zypper --non-interactive
install --no-recommends` → `zypper clean --all && rm -rf /var/cache/zypp/* /tmp/* /var/tmp/*` →
`LABEL run="..."` → `USER ai`. Keep package lists alphabetized (ASCII order: `ShellCheck` sorts
before lowercase names). Profiles are plain Containerfiles by design — do not add a DSL, config
parser, or generator layer.

**`paddock.sh`:** portable Bash, `set -e`, and user-facing output through the existing `info()` /
`error()` helpers (`error()` exits 1) rather than bare `echo`. Declare-and-assign separately when
the value comes from a subshell (`local x; x="$(...)"`) — SC2155 is enforced.

## Docs

`GEMINI.md` is a **symlink to this file** (Gemini CLI auto-loads that filename) — edit `AGENTS.md`
only. `README.md` is user-facing. `docs/design.md` is the original spec and is partly stale
(mentions `ruby`/`perl` profiles and an `/etc/gitconfig` that do not exist). Trust `paddock.sh`
and the Containerfiles over both.
