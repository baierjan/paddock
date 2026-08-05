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
which Containerfile backs it — see "The 'default' profile is overridable" below.

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
  invoke the suite from. `.gitignore` covers both, plus `profiles/latest/` (see below) — delete
  them before `git add` regardless, since a stray copy can still shadow the real profile locally.
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
- Tests 11-12 create and remove a real `profiles/latest/Containerfile` on disk to exercise the
  override in "The 'default' profile is overridable" below. Like the mock dirs, a failure mid-test
  leaves it behind; `.gitignore` keeps that from becoming a stray commit, but it will still shadow
  `profiles/default/` for every subsequent invocation until removed.

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

## The "default" profile is overridable

`profiles/default/` is the shipped general-purpose profile, but the name you actually address it by
is `default`, not a directory name — `paddock.sh` resolves `default` through `containerfile_for()`:
if a `profiles/latest/Containerfile` exists it is used *instead of* `profiles/default/`, for every
spelling (`build`, `build default`, `build latest` all resolve to the same file when the override is
present). `profiles/latest/` is never shipped by this repo and is listed in `.gitignore` — it exists
purely as a personal, machine-local override point.

Regardless of which file backs it, the image always tags as `paddock:latest` (`image_tag()`
special-cases `default` the same way it special-cases `base` → `paddock-base:latest`). This is
deliberate: `podman container runlabel run paddock:latest` and every doc reference to that tag must
keep working whether or not a local override exists.

Two things that look like they should generalize but must not:

- **The override is scoped to the name `default` only.** `containerfile_for()` checks
  `[ "$1" = "default" ]` before checking whether `profiles/latest/Containerfile` exists — checking
  only the file's existence would make *every* profile (including `base`) silently resolve to the
  override. Test 12 pins this by asserting `build base` is unaffected while an override is active.
- **Typing `latest` explicitly is not an alias of `default`.** If no `profiles/latest/` override
  exists, `./paddock.sh build latest` fails with a normal "profile not found" error — it is treated
  as an ordinary (currently nonexistent) profile name, not silently redirected to
  `profiles/default/`. Only `default` gets fallback resolution. Test 11 pins this.
- **`ensure_image()` validates the profile even when its image already exists.** Before this
  feature, a profile's tag was unique to its name, so an existing tag was itself proof the name was
  valid. That stopped being true the moment `default` and `latest` could share `paddock:latest`: a
  stale `paddock:latest` built from `profiles/default/` could otherwise make `build latest` silently
  no-op without ever checking `profiles/latest/` exists. `ensure_image()` calls `assert_profile()`
  unconditionally, before the "does the tag already exist" fast path, to close this.

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
