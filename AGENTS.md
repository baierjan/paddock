# AGENTS.md — Paddock

Paddock builds hardened, krun/microVM-backed Podman sandboxes for AI coding CLIs.
The entire project is Bash + Containerfiles: no package manager, no build system, no CI.

## Commands

```bash
./test_paddock.sh    # lint + tests; the only verification step
./paddock.sh build   # build only if missing or out of date
./paddock.sh rebuild # always build, ignoring the staleness check
./paddock.sh run     # build if needed, then launch
podman container runlabel run paddock:latest   # equivalent, needs no checkout
```

The image always builds/runs as tag `paddock:latest` regardless of which Containerfile backs it —
see "The Containerfile is personally overridable" below.

`test_paddock.sh` is offline: it shims `podman` via a generated `mock_bin/` on `PATH` and asserts
the exact logged command lines. It does **not** need podman/krun installed — keep it that way; new
tests must go through the mock, never a real container runtime.

**Lint gate:** the suite runs `shellcheck` over every `*.sh` in the repo (`mock_*` excluded) *before*
the functional tests and aborts on any finding — all shell here must stay shellcheck-clean, warnings
included. New scripts are picked up automatically. If `shellcheck` is absent the suite prints
`SKIP: ... LINT GATE NOT ENFORCED` and continues, so a green run on a host without it proves less
than it appears; `ShellCheck` ships in the image, so running inside a paddock sandbox always
enforces the gate.

### Test-suite gotchas

- On failure (`set -e`) cleanup is skipped and `mock_bin/` and `mock_home/` are left in the repo
  root — they are placed relative to `BASH_SOURCE`, not the CWD, so they land there wherever you
  invoke the suite from. `.gitignore` covers both — delete them before `git add` regardless.
- Each test states its own preconditions via `MOCK_IMAGES` (space-separated tags that "exist") and
  `MOCK_IMAGE_EPOCH` (image creation time; the far-future default means "current", `0` means
  "stale"). There is no shared mock state and no ordering between tests — keep it that way rather
  than reintroducing appended handlers.
- `reset_log()` clears the mock log at the start of every test, so cross-test contamination isn't
  the concern `assert_last_log` guards against. Tests 5 and 6 use it because a build can
  legitimately precede the final action within a *single* test (e.g. Test 6 rebuilds a stale image
  before launching it) — exact-match on the tail line proves the launch happened **last**, not
  merely that it happened somewhere in that test's log.
- Tests 9-12 read the run label off the logged `podman build ... --label run=...` command line
  (`tail -n 1` of the mock log right after a `build`), not off a file — `run_label()` bakes it in
  via `podman build`, it is never written to the Containerfile. `$${}HOME`/`$${}PWD` inside it are
  asserted in that exact, unreparsed spelling (matched verbatim): that is what `run_label()`
  actually hands to `--label`, and it is real podman's own reparse — not this mock — that turns it
  into literal `$HOME`/`$PWD` for `podman container runlabel` to expand later. See "The run label
  lives in paddock.sh" for why that specific spelling, and not a plain or `\$`-escaped
  `$HOME`/`$PWD`, is required.
- The mock answers `image inspect` with `${MOCK_IMAGE_EPOCH:-9999999999}`, so images look current by
  default and the staleness check stays inert. Tests 3 and 6 set `MOCK_IMAGE_EPOCH=0` to force the
  rebuild path (build and run respectively); Tests 2 and 5 assert the opposite (no spurious
  rebuild). Prefer that env var over touching file mtimes.
- Test 8 creates and removes a real `Containerfile` under the mock `HOME`'s
  `.local/share/paddock/` to exercise the override described in "The Containerfile is personally
  overridable" below. Since `HOME` is redirected to `mock_home/` for the whole suite (see above),
  it never touches a real `~/.local/share/paddock/`; a failure mid-test leaves it under
  `mock_home/`, which is deleted along with it.

## The run label lives in paddock.sh

`run_label()` in `paddock.sh` is the **sole** definition of every mount, annotation and security
flag — not the Containerfile. `build()` passes it to `podman build --label run=...` at build time,
so it still ends up baked into the image; `paddock.sh run` still does not build a `podman run` line
at all, it calls `podman container runlabel run paddock:latest` and lets podman expand the baked-in
label. Adding a `podman run` back into `paddock.sh` would recreate the duplication this design
removed.

**A literal, still-unexpanded `$HOME`/`$PWD` cannot be spelled as `$HOME`/`$PWD` or `\$HOME`/`\$PWD`
in this value — it must be `$${}HOME`/`$${}PWD`.** `podman build --label run=...` re-injects the
value as a *synthesized* `LABEL "run"="..."` instruction and reparses it through Dockerfile's own
environment-variable substitution (`imagebuildah/executor.go` builds the instruction text via Go's
`%q`; `imagebuilder`'s own `shell_parser.go` — not the `moby/buildkit` shell package used elsewhere
in this codebase — then reparses it), the same mechanism that expands `${ARG}`/`${ENV}` references
elsewhere in a Containerfile:

- A bare `$HOME`/`$PWD` resolves against the *build's* environment instead of surviving to
  `podman container runlabel` — `$PWD` came back empty (`os.Environ()` on the build host rarely has
  it, matching podman's own `containers_runlabel.go` comment: "it appears PWD is not in the os env
  list"), while `$HOME` silently baked in the *builder's* home directory, permanently, which only
  looked correct because the same user built and ran the image.
- `\$HOME` does not survive either: `%q` unconditionally doubles a literal backslash (`\` → `\\`),
  and `imagebuilder`'s reparse only removes one level of that doubling (`\\` → `\`), leaving a bare,
  unescaped `$PWD` right behind it — the same failure as above, just introduced through escaping
  that looks like it should have worked.
- `$${}HOME` does survive, because of how `imagebuilder`'s parser (`shellWord.processDollar()`)
  reads a bare `$` one character at a time: the first `$` is immediately followed by a second `$`,
  which isn't a valid identifier character, so `processName()` returns empty and that first `$` is
  emitted as a literal `$`. The second `$` then sees `{` next, parses `${}` as an *empty* variable
  name, and resolves it to `""` via a plain, always-succeeds lookup. The trailing `HOME` was never
  part of either token — it's ordinary text with no leading `$`, so it passes through untouched.
  Concatenated, `$` + `""` + `HOME` reads back out as the literal text `$HOME`. `%q` doesn't touch
  any of this either, since none of `$`, `{`, `}` need escaping in a Go string literal.

The label moved out of the Containerfile specifically because a static `LABEL` instruction cannot
read host state at build time: `run_label()` resolves `PADDOCK_RAM_MIB` / `PADDOCK_CPUS` /
`PADDOCK_PIDS_LIMIT` / `PADDOCK_TMP_SIZE` (env vars, defaulting to today's values) and, if
`XDG_DATA_HOME` is set, an XDG-aware home path, none of which a Containerfile can express.

**An `XDG_DATA_HOME` that is itself `$HOME`-relative keeps the portable `$HOME` token.** Setting
`XDG_DATA_HOME` doesn't automatically mean giving up portability: `run_label()` checks whether
its value is `$HOME` itself or `$HOME` plus a fixed suffix (the common case — e.g. the XDG default
of `$HOME/.local/share` — and anything else `$HOME`-relative) and, if so, bakes in only that suffix
next to the still-literal `$${}HOME` token, exactly as if `XDG_DATA_HOME` had never been set. Only
an `XDG_DATA_HOME` pointing somewhere genuinely unrelated to `$HOME` (e.g. `/mnt/xdg-data`) loses
portability, since there is then no `$HOME`-relative form left to express.

Consequences worth knowing:

- **The limits are baked into the image**, so an out-of-date image would apply out-of-date limits.
  `ensure_image()` guards this: `paddock.sh run` compares the image's creation time
  (`podman image inspect --format '{{.Created.Unix}}'`) against the mtimes of the
  `Containerfile`/`entrypoint.sh` *and `paddock.sh` itself* (`SELF`, since that is where the label
  logic now lives), rebuilding if either is newer. `build` and `run` share this path; `rebuild`
  skips the check and always builds. Editing `run_label()` therefore takes effect on the next
  `build`/`run`, but a bare `podman container runlabel` does **not** get this and needs
  `./paddock.sh rebuild`. Env vars alone (`PADDOCK_RAM_MIB` etc.) changing between runs does **not**
  trigger a rebuild either — only a file mtime does — so a limit change via env var needs an
  explicit `./paddock.sh rebuild` to actually take effect, same as an `upgrade`-updated `ARG` in
  the Containerfile.
- **The mock cannot see the flags.** Since podman resolves the label internally, `test_paddock.sh`
  only observes `podman container runlabel run <tag>`. Test 9 therefore asserts the required
  controls textually against the `podman build --label run=...` argument on the logged command line
  (`--cap-drop ALL`, `--read-only`, `no-new-privileges`, `--user ai`, `--userns keep-id`, `noexec`
  on `/tmp`, `--network pasta`, `--runtime krun`, the presence of `--pids-limit` / `krun.ram_mib` /
  `krun.cpus`). Test 10 that the four `PADDOCK_*` env vars actually change those values, Test 11
  that a `$HOME`-relative `XDG_DATA_HOME` keeps the `$${}HOME` spelling and only bakes in the
  suffix, Test 12 that a non-`$HOME`-relative one bakes in a fully resolved path instead. Add new
  security flags to Test 9's list.
- `README.md` describes the flags **by name, with no numeric values**. Do not re-add concrete limits.

`runlabel` expands only `$HOME`, `$PWD`, `$IMAGE`, `$NAME` and `$OPT1..3` (the last three via hidden
`--opt1..3` flags); everything else silently becomes `""`. The man page's VARIABLES section omits
`HOME` and the `OPT`s — trust `pkg/domain/infra/abi/containers_runlabel.go` over the docs. Two
consequences: the label cannot express anything derived (no `basename`, no string ops) — which is
exactly why `XDG_DATA_HOME` has to be resolved in bash at build time rather than left as a token for
podman to expand later, it is not on that substitution list and would silently become `""` — and
because podman does `os.Expand` then `shlex.Split`, **a `$PWD` or `$HOME` containing a space breaks
the argv** (it fails loudly as image-not-found, not silently).

The baked-in label deliberately omits `--name` so concurrent launches from different directories get
unique auto-generated names. A path cannot go there anyway: podman's `NameRegex` is
`^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`, which rejects `$PWD` for its slashes.

## The Containerfile is personally overridable

The image can be overridden without touching the shipped tree: `containerfile()` checks
`~/.local/share/paddock/Containerfile` first and falls back to the shipped `profile/Containerfile`
only if no override exists. It lives under `~/.local/share/paddock/`, alongside the persistent
sandbox home (`run()`'s `~/.local/share/paddock/home`), because that tree is already the project's
convention for machine-local, never-shipped state, and — unlike a path inside the repo/install
tree — it is writable regardless of whether `paddock.sh` was checked out from git or installed
system-wide (e.g. from a package, under a read-only `/usr/share/paddock`).

Regardless of which file backs it, the image tag is always `paddock:latest` (the `IMAGE` constant),
never derived from the Containerfile. This is deliberate: `podman container runlabel run
paddock:latest` and every doc reference to that tag must keep working whether or not a personal
override exists. The run label is unaffected by which Containerfile is in play either — `run_label()`
is always baked in via `--label run=...` at build time, so an override gets the exact same
paddock.sh-baked label as the shipped Containerfile, winning over anything the override's own
`LABEL run` might independently declare.

Worth knowing:

- **`ensure_image()` validates the Containerfile even when the image already exists.** The tag never
  changes, but that alone doesn't prove the Containerfile behind it (shipped or overridden) is still
  there — e.g. the override could have been deleted since the image was last built. `ensure_image()`
  checks for it unconditionally, before the "does the tag already exist" fast path, to close this.
  Test 13 pins it by temporarily moving the shipped Containerfile aside.
- **An override Containerfile still builds with the repo/install root as its context**
  (`podman build -f <containerfile> "$ROOT_DIR"` — see "Build context" under Architecture
  constraints). A `COPY` in an override resolves relative to `$ROOT_DIR`, not to the override's own
  location under `~/.local/share/paddock/`.

## Architecture constraints

- **Pristine home**: `/home/ai` must stay completely empty in the image (`useradd --no-create-home`,
  manual `mkdir`). The host home bind-mount over `/home/ai` would otherwise mask baked-in files.
  Put shell config in `/etc/bash.bashrc` (starship is initialized there), never in `/home/ai`.
- **Entrypoint privilege drop**: `profile/entrypoint.sh` re-execs itself via `setpriv` when
  the guest kernel boots it as UID 0 (krun does this despite `--user ai`). No `cd` is needed
  around this: cwd is a process attribute (`fs_struct`), untouched by `exec` or by credential
  syscalls (`setuid`/`setgid`/`initgroups`), so it survives the re-exec on its own.
- **Build context is the repo root** (`podman build -f profile/Containerfile $ROOT_DIR`);
  `profile/Containerfile` relies on this for `COPY profile/entrypoint.sh`.
- **The image is x86_64-only.** It unconditionally installs the Google Cloud CLI from the
  `cloud-sdk-el10-x86_64` repo, which publishes no other architecture. There is no build-time
  switch to opt out — assistants (`opencode` + `@google/gemini-cli`) are fixed, not selectable.
- Host prerequisites for `run` (not for tests): rootless podman, the `krun` runtime, and `pasta`.

## Conventions

**`profile/Containerfile`:** each `zypper` layer follows `zypper --non-interactive install
--no-recommends` → `zypper clean --all && rm -rf /var/cache/zypp/* /tmp/* /var/tmp/*`. Keep package
lists alphabetized (ASCII order: `ShellCheck` sorts before lowercase names). It is a plain
Containerfile by design — do not add a DSL, config parser, or generator layer, and do not reintroduce
per-profile layering. The one deliberate exception is the run label: see "The run label lives in
paddock.sh" for why it is assembled in `paddock.sh` instead of a static `LABEL run` here.

**`paddock.sh`:** portable Bash, `set -e`, and user-facing output through the existing `info()` /
`error()` helpers (`error()` exits 1) rather than bare `echo`. Declare-and-assign separately when
the value comes from a subshell (`local x; x="$(...)"`) — SC2155 is enforced.

## Docs

`GEMINI.md` is a **symlink to this file** (Gemini CLI auto-loads that filename) — edit `AGENTS.md`
only. `README.md` is user-facing. Trust `paddock.sh` and the Containerfile over both.
