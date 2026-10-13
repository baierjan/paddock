#!/bin/bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_BIN="${ROOT_DIR}/mock_bin"
MOCK_LOG="$(mktemp)"
MOCK_ARGV_LOG="$(mktemp)"
export MOCK_LOG MOCK_ARGV_LOG
# A stand-in project dir for `run` tests -- ROOT_DIR itself becomes an ancestor of DATA_HOME below.
MOCK_WORKSPACE="${ROOT_DIR}/mock_workspace"
CONTAINERFILE="${ROOT_DIR}/profile/Containerfile"
# The exact flattened label run_label() produces with no PADDOCK_*/
# XDG_DATA_HOME overrides set; `$${}HOME`/`$${}PWD` appear as raw argv here
# since the mock doesn't simulate podman's own reparse (see run_label()).
# shellcheck disable=SC2016
LABEL='podman run --rm --interactive --tty --runtime krun --network pasta --annotation krun.use_passt=1 --annotation krun.ram_mib=8192 --annotation krun.cpus=4 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=2048m --pids-limit 1024 --hostname paddock-latest --user ai --userns keep-id:uid=1000,gid=1000 --volume $${}HOME/.local/share/paddock/home:/home/ai:z --volume $${}PWD:/home/ai/sandbox:z --workdir /home/ai/sandbox paddock:latest'
BUILD="podman build -t paddock:latest -f ${CONTAINERFILE} --label run=${LABEL} ${ROOT_DIR}"
# The mock's default "up to date" answer for `image inspect`: what a real
# image's `.Config.Labels.run` shows after podman's own --label reparse
# collapses `$${}` to a single `$`.
BAKED_LABEL="${LABEL//\$\${\}/\$}"
export BAKED_LABEL
IMAGES="paddock:latest"

# --- Lint gate ---------------------------------------------------------------
# ShellCheck always ships inside a paddock sandbox; when it's missing here,
# the gate isn't enforced, hence the loud SKIP below.
echo "=== Linting shell scripts ==="
if command -v shellcheck > /dev/null 2>&1; then
    mapfile -t SHELL_SCRIPTS < <(find "${ROOT_DIR}" -name '*.sh' -not -path '*/mock_*' | sort)
    if ! shellcheck "${SHELL_SCRIPTS[@]}"; then
        echo "FAIL: shellcheck reported issues" >&2
        exit 1
    fi
    echo "PASS: shellcheck clean (${#SHELL_SCRIPTS[@]} scripts)"
else
    echo "SKIP: shellcheck not installed -- LINT GATE NOT ENFORCED"
fi

# Setup mock environment
rm -rf "${MOCK_BIN}" "${MOCK_WORKSPACE}"
mkdir -p "${MOCK_BIN}" "${MOCK_WORKSPACE}"
: > "${MOCK_LOG}"

# Both stubbed queries are driven by environment variables so every test
# states its own preconditions; no shared state, no ordering between tests.
cat << 'EOF' > "${MOCK_BIN}/podman"
#!/bin/bash
echo "podman $*" >> "${MOCK_LOG}"
printf '<podman>' >> "${MOCK_ARGV_LOG}"
for a in "$@"; do
    a_esc="${a//$'\n'/\\n}"
    printf '<%s>' "$a_esc" >> "${MOCK_ARGV_LOG}"
done
echo >> "${MOCK_ARGV_LOG}"
# Which images exist: space-separated tags in MOCK_IMAGES (default: none).
if [ "$1" = "image" ] && [ "$2" = "exists" ]; then
    case " ${MOCK_IMAGES:-} " in
        *" $3 "*) exit 0 ;;
        *) exit 1 ;;
    esac
fi
# The image's baked-in `run` label; defaults to the current, up-to-date one,
# and a test sets MOCK_IMAGE_LABEL to simulate a stale one.
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
    echo "${MOCK_IMAGE_LABEL-${BAKED_LABEL}}"
    exit 0
fi
EOF
chmod +x "${MOCK_BIN}/podman"

export PATH="${MOCK_BIN}:${PATH}"

# Ensure XDG/PADDOCK variables are unset for deterministic test paths
unset XDG_DATA_HOME
unset PADDOCK_RAM_MIB PADDOCK_CPUS PADDOCK_PIDS_LIMIT PADDOCK_TMP_SIZE

# Override HOME to verify home directory creation
export HOME="${ROOT_DIR}/mock_home"
rm -rf "${HOME}"
mkdir -p "${HOME}"
PADDOCK_HOME="${HOME}/.local/share/paddock/home"
OVERRIDE_CF="${HOME}/.local/share/paddock/Containerfile"

# --- Helpers -----------------------------------------------------------------

reset_log() { : > "${MOCK_LOG}"; : > "${MOCK_ARGV_LOG}"; }

# assert_argv <fixed-substring> <description>
assert_argv() {
    local actual
    actual="$(tail -n 1 "${MOCK_ARGV_LOG}")"
    case "${actual}" in
        *"$1"*) ;;
        *)
            echo "FAIL: $2" >&2
            echo "  expected to contain: $1" >&2
            echo "  actual             : ${actual}" >&2
            exit 1
            ;;
    esac
    echo "PASS: $2"
}

# assert_log <fixed-substring> <description>
assert_log() {
    if ! grep -qF -- "$1" "${MOCK_LOG}"; then
        echo "FAIL: $2" >&2
        cat "${MOCK_LOG}" >&2
        exit 1
    fi
    echo "PASS: $2"
}

# assert_no_log <fixed-substring> <description>
assert_no_log() {
    if grep -qF -- "$1" "${MOCK_LOG}"; then
        echo "FAIL: $2" >&2
        cat "${MOCK_LOG}" >&2
        exit 1
    fi
    echo "PASS: $2"
}

# assert_last_log <expected-line> <description>
assert_last_log() {
    local actual
    actual="$(tail -n 1 "${MOCK_LOG}")"
    if [ "${actual}" != "$1" ]; then
        echo "FAIL: $2" >&2
        echo "  expected: $1" >&2
        echo "  actual  : ${actual}" >&2
        exit 1
    fi
    echo "PASS: $2"
}

# assert_dir <path> <description>
assert_dir() {
    if [ ! -d "$1" ]; then
        echo "FAIL: $2 (missing $1)" >&2
        exit 1
    fi
    echo "PASS: $2"
}

# assert_fails <description> <command...>
assert_fails() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then
        echo "FAIL: ${desc}" >&2
        exit 1
    fi
    echo "PASS: ${desc}"
}

echo "=== Running Paddock Tests ==="

# --- build: unconditional, always (re)builds the image ------------------------

# Test 1: build always (re)builds the image, even though it already exists
# and its baked-in label is current; `run` is the only caller that checks first.
echo "Test 1: build always (re)builds the image..."
reset_log
MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" build
assert_log "${BUILD}" "'build' unconditionally (re)builds the image"

# --- run: ensure the image, then delegate to the label -----------------------

# Test 2: run prepares the home directory and delegates to runlabel
echo "Test 2: run..."
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run)
assert_dir "${PADDOCK_HOME}" "Persistent home folder is created"
assert_no_log "podman build" "A current image is not rebuilt before running"
assert_last_log "podman container runlabel run paddock:latest" \
    "Run delegates to 'podman container runlabel'"

# Test 3: run builds first when the baked-in run label no longer matches
# run_label(); MOCK_IMAGE_LABEL="" simulates that mismatch.
echo "Test 3: run rebuilds when the baked-in run label is out of date..."
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" MOCK_IMAGE_LABEL="" "${ROOT_DIR}/paddock.sh" run)
assert_log "${BUILD}" "Image with an out-of-date run label is rebuilt before launching"
assert_last_log "podman container runlabel run paddock:latest" \
    "Launch still happens after the rebuild"

# Test 4: run builds first when the image is missing outright
echo "Test 4: run builds a missing image before launching..."
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="" "${ROOT_DIR}/paddock.sh" run)
assert_log "${BUILD}" "Missing image is built before launching"
assert_last_log "podman container runlabel run paddock:latest" \
    "Launch still happens after the build"

# --- error handling ----------------------------------------------------------

# Test 5: an unknown action is rejected
echo "Test 5: rejecting an unknown action..."
assert_fails "'nosuch' is rejected" env MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" nosuch

# --- personal override: ~/.local/share/paddock/Containerfile takes ----------
# --- precedence over the shipped profile/Containerfile ----------------------

# Test 6: a personal override takes precedence over the shipped Containerfile,
# and still resolves to the same image tag and baked-in label.
echo "Test 6: a personal override takes precedence over the shipped Containerfile..."
BUILD_OVERRIDE="podman build -t paddock:latest -f ${OVERRIDE_CF} --label run=${LABEL} ${ROOT_DIR}"
mkdir -p "$(dirname "${OVERRIDE_CF}")"
echo 'FROM registry.opensuse.org/opensuse/tumbleweed:latest' > "${OVERRIDE_CF}"

reset_log
MOCK_IMAGES="" "${ROOT_DIR}/paddock.sh" build
assert_log "${BUILD_OVERRIDE}" "'build' uses the override, not profile/Containerfile"
assert_no_log "${BUILD}" "profile/Containerfile is not built while overridden"

rm -f "${OVERRIDE_CF}"
echo "PASS: personal override resolves and preserves tag naming"

# --- the baked-in label is the only definition of the sandbox ----------------

# Test 7: the mock can only observe the `podman build --label run=...`
# argument, so this asserts the non-negotiable flags are present in it (not
# their exact values; Test 8 covers that they're overridable).
echo "Test 7: verifying security invariants in the baked-in run label..."
reset_log
MOCK_IMAGES="" "${ROOT_DIR}/paddock.sh" build
BAKED_LABEL="$(tail -n 1 "${MOCK_LOG}")"
# `$${}HOME`/`$${}PWD` below are the exact, unreparsed form run_label()
# produces (see there for why); real podman reparses these into literal
# `$HOME`/`$PWD` for `podman container runlabel` to expand later.
# shellcheck disable=SC2016
for flag in \
    '--runtime krun' \
    '--network pasta' \
    '--cap-drop ALL' \
    '--security-opt no-new-privileges' \
    '--read-only' \
    '--tmpfs /tmp:rw,noexec,nosuid,nodev' \
    '--pids-limit ' \
    '--annotation krun.ram_mib=' \
    '--annotation krun.cpus=' \
    '--user ai' \
    '--userns keep-id:uid=1000,gid=1000' \
    '--volume $${}HOME/.local/share/paddock/home:/home/ai:z' \
    '--volume $${}PWD:/home/ai/sandbox:z' \
    '--workdir /home/ai/sandbox'
do
    case "${BAKED_LABEL}" in
        *"${flag}"*) ;;
        *)
            echo "FAIL: baked-in run label is missing required flag: ${flag}" >&2
            echo "  label: ${BAKED_LABEL}" >&2
            exit 1
            ;;
    esac
done
echo "PASS: baked-in run label contains all required security flags"

# Test 8: PADDOCK_RAM_MIB/CPUS/PIDS_LIMIT/TMP_SIZE override the defaults
# baked into the run label at build time.
echo "Test 8: resource limits are customizable via env vars..."
reset_log
MOCK_IMAGES="" \
    PADDOCK_RAM_MIB=4096 PADDOCK_CPUS=2 PADDOCK_PIDS_LIMIT=256 PADDOCK_TMP_SIZE=512m \
    "${ROOT_DIR}/paddock.sh" build
BAKED_LABEL="$(tail -n 1 "${MOCK_LOG}")"
for flag in \
    '--annotation krun.ram_mib=4096' \
    '--annotation krun.cpus=2' \
    '--pids-limit 256' \
    'size=512m'
do
    case "${BAKED_LABEL}" in
        *"${flag}"*) ;;
        *)
            echo "FAIL: PADDOCK_* env vars did not override the label: ${flag}" >&2
            echo "  label: ${BAKED_LABEL}" >&2
            exit 1
            ;;
    esac
done
echo "PASS: resource limits are overridable via PADDOCK_* env vars"

# Test 9: an XDG_DATA_HOME that is itself $HOME plus a fixed suffix keeps
# the portable $${}HOME token -- only the suffix is baked in.
echo "Test 9: a \$HOME-relative XDG_DATA_HOME keeps the portable \$HOME token..."
reset_log
MOCK_IMAGES="" XDG_DATA_HOME="${HOME}/xdg-data" \
    "${ROOT_DIR}/paddock.sh" build
BAKED_LABEL="$(tail -n 1 "${MOCK_LOG}")"
# shellcheck disable=SC2016
case "${BAKED_LABEL}" in
    *'--volume $${}HOME/xdg-data/paddock/home:/home/ai:z'*)
        echo "PASS: the \$HOME-relative suffix is baked in, the \$HOME token stays portable" ;;
    *)
        echo "FAIL: a \$HOME-relative XDG_DATA_HOME did not keep the portable \$HOME token" >&2
        echo "  label: ${BAKED_LABEL}" >&2
        exit 1
        ;;
esac

# Test 10: a non-$HOME-relative XDG_DATA_HOME bakes in a fully resolved
# path instead, since there is no $HOME-relative form to express it.
echo "Test 10: a non-\$HOME-relative XDG_DATA_HOME bakes in a resolved path..."
reset_log
MOCK_IMAGES="" XDG_DATA_HOME="/mnt/xdg-data" \
    "${ROOT_DIR}/paddock.sh" build
BAKED_LABEL="$(tail -n 1 "${MOCK_LOG}")"
case "${BAKED_LABEL}" in
    *"--volume /mnt/xdg-data/paddock/home:/home/ai:z"*)
        echo "PASS: XDG_DATA_HOME is baked into the home volume path" ;;
    *)
        echo "FAIL: XDG_DATA_HOME was not reflected in the baked-in label" >&2
        echo "  label: ${BAKED_LABEL}" >&2
        exit 1
        ;;
esac
# shellcheck disable=SC2016
case "${BAKED_LABEL}" in
    *'--volume $${}HOME'*)
        echo "FAIL: label still contains the portable literal \$HOME token" >&2
        exit 1
        ;;
    *) echo "PASS: the portable literal \$HOME token is gone once XDG_DATA_HOME points elsewhere" ;;
esac

# Test 11: build() validates the Containerfile even when the image already
# exists, since an existing tag doesn't prove the Containerfile is still there.
#
# Tests 11 and 12 both move/mutate the real shipped Containerfile; the trap
# below restores it on every exit path, including a failing assertion under
# `set -e`.
restore_containerfile() {
    if [ -f "${CONTAINERFILE}.bak" ]; then
        mv -f "${CONTAINERFILE}.bak" "${CONTAINERFILE}"
    fi
}
trap restore_containerfile EXIT

echo "Test 11: a missing Containerfile is rejected even if the image exists..."
mv "${CONTAINERFILE}" "${CONTAINERFILE}.bak"
assert_fails "'build' is rejected when the Containerfile is missing" \
    env MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" build
mv "${CONTAINERFILE}.bak" "${CONTAINERFILE}"

# Test 12: ensure_image() (the path 'run' uses) validates the Containerfile
# too, even when no rebuild would otherwise be triggered.
echo "Test 12: 'run' is rejected when the Containerfile is missing..."
mv "${CONTAINERFILE}" "${CONTAINERFILE}.bak"
assert_fails "'run' is rejected when the Containerfile is missing" \
    env MOCK_IMAGES="${IMAGES}" bash -c "cd '${MOCK_WORKSPACE}' && '${ROOT_DIR}/paddock.sh' run"
mv "${CONTAINERFILE}.bak" "${CONTAINERFILE}"

# --- run: refuses to launch from a dangerous cwd -----------------------------

# Test 13: run refuses to recursively SELinux-relabel $HOME.
echo "Test 13: run refuses to launch from \$HOME..."
assert_fails "'run' is rejected from \$HOME" \
    env MOCK_IMAGES="${IMAGES}" bash -c "cd '${HOME}' && '${ROOT_DIR}/paddock.sh' run"

# --- run: -w and command forwarding -----------------------------------------

# Reset BAKED_LABEL after Tests 7-10 scratch builds to avoid spurious rebuilds.
BAKED_LABEL="${LABEL//\$\${\}/\$}"

# The label's flags with the runtime-resolved mounts substituted and the
# workdir/image tail removed.
PODMAN_DIRECT_RUN="${LABEL%% --workdir *}"
# shellcheck disable=SC2016
PODMAN_DIRECT_RUN="${PODMAN_DIRECT_RUN/'$${}HOME/.local/share/paddock/home'/${PADDOCK_HOME}}"
# shellcheck disable=SC2016
PODMAN_DIRECT_RUN="${PODMAN_DIRECT_RUN/'$${}PWD'/${MOCK_WORKSPACE}}"

# Test 14: run -w launches podman directly with custom workdir
echo "Test 14: run -w launches podman directly with custom workdir..."
mkdir -p "${MOCK_WORKSPACE}/subproj/nested"
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run -w subproj)
assert_last_log "${PODMAN_DIRECT_RUN} --workdir /home/ai/sandbox/subproj paddock:latest" \
    "run -w launches podman directly with custom workdir"
assert_argv "<--workdir></home/ai/sandbox/subproj>" \
    "Workdir flag and value are separate argv tokens"
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run -w subproj/nested)
assert_last_log "${PODMAN_DIRECT_RUN} --workdir /home/ai/sandbox/subproj/nested paddock:latest" \
    "run -w with nested path launches podman directly"

# Test 15: run -w with command forwards command after image
echo "Test 15: run -w with command forwards command after image..."
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run -w subproj opencode -c)
assert_last_log "${PODMAN_DIRECT_RUN} --workdir /home/ai/sandbox/subproj paddock:latest opencode -c" \
    "run -w with command forwards command arguments"

# Test 16: run with command but no -w forwards command directly
echo "Test 16: run with command but no -w forwards command directly..."
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run opencode -c)
assert_last_log "${PODMAN_DIRECT_RUN} --workdir /home/ai/sandbox paddock:latest opencode -c" \
    "run forwards command arguments directly without -w"

# Test 17: run -w with nonexistent directory is rejected
echo "Test 17: run -w with nonexistent directory is rejected..."
assert_fails "run -w nonexistent is rejected" \
    env MOCK_IMAGES="${IMAGES}" bash -c "cd '${MOCK_WORKSPACE}' && '${ROOT_DIR}/paddock.sh' run -w nonexistent"
assert_fails "run -w without argument is rejected" \
    env MOCK_IMAGES="${IMAGES}" bash -c "cd '${MOCK_WORKSPACE}' && '${ROOT_DIR}/paddock.sh' run -w"
assert_fails "run with unknown option is rejected" \
    env MOCK_IMAGES="${IMAGES}" bash -c "cd '${MOCK_WORKSPACE}' && '${ROOT_DIR}/paddock.sh' run -x"

# Test 18: run -w rejects directories outside the workspace, directly or via symlink
echo "Test 18: run -w rejects directories outside the workspace..."
ln -snf "${ROOT_DIR}" "${MOCK_WORKSPACE}/symlink_outside"
for outside in .. symlink_outside; do
    # shellcheck disable=SC2016
    assert_fails "run -w ${outside} is rejected" \
        env MOCK_IMAGES="${IMAGES}" bash -c 'cd "$1" && "$2" run -w "$3"' _ "${MOCK_WORKSPACE}" "${ROOT_DIR}/paddock.sh" "${outside}"
done

# Test 19: run -w with spaces in folder name succeeds via direct podman run
echo "Test 19: run -w with spaces in folder name succeeds..."
mkdir -p "${MOCK_WORKSPACE}/sub dir"
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run -w "sub dir")
assert_argv "<--workdir></home/ai/sandbox/sub dir>" \
    "Folder with spaces is preserved as a single workdir argument"

# Test 20: run forwards command arguments containing spaces and metacharacters safely
echo "Test 20: run forwards arbitrary command arguments safely..."
reset_log
# shellcheck disable=SC2016
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run echo "hello world" '$FOO' 'rg \d')
assert_argv "<echo><hello world><\$FOO><rg \\d>" \
    "Command arguments with spaces and metacharacters preserve exact argv boundaries"

# Test 21: run -w with newline in folder name preserves argv boundary without flag injection
echo "Test 21: run -w with newline in folder name preserves argv boundary..."
mkdir -p "${MOCK_WORKSPACE}/"$'\n'"--privileged"
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run -w $'\n'"--privileged")
assert_argv '<--workdir></home/ai/sandbox/\n--privileged>' \
    "Folder with newline is preserved as a single workdir argument"

# Test 22: run -- forwards commands starting with a hyphen
echo "Test 22: run -- forwards command starting with a hyphen..."
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run -- ls -l)
assert_last_log "${PODMAN_DIRECT_RUN} --workdir /home/ai/sandbox paddock:latest ls -l" \
    "run -- forwards hyphen-prefixed command"

# Test 23: run refuses to launch when HOME is reached via a symlink
echo "Test 23: run refuses to launch from symlinked HOME..."
mkdir -p "${HOME}/real_home"
ln -snf "${HOME}/real_home" "${HOME}/sym_home"
assert_fails "'run' is rejected from symlinked HOME" \
    env MOCK_IMAGES="${IMAGES}" HOME="${HOME}/sym_home" bash -c "cd '${HOME}/real_home' && '${ROOT_DIR}/paddock.sh' run"

# Test 24: the guest entrypoint hardens /tmp before dropping privileges
echo "Test 24: entrypoint hardens /tmp before dropping privileges..."
ENTRY_STUBS="${MOCK_BIN}/entry"
mkdir -p "${ENTRY_STUBS}"
cat << 'EOF' > "${ENTRY_STUBS}/id"
#!/bin/bash
case "$*" in
    "-u") echo 0 ;;
    "-u ai" | "-g ai") echo 1000 ;;
esac
EOF
cat << 'EOF' > "${ENTRY_STUBS}/mount"
#!/bin/bash
echo "mount $*" >> "${MOCK_LOG}"
[ -z "${MOCK_MOUNT_FAIL:-}" ]
EOF
cat << 'EOF' > "${ENTRY_STUBS}/setpriv"
#!/bin/bash
echo "setpriv $*" >> "${MOCK_LOG}"
EOF
chmod +x "${ENTRY_STUBS}/id" "${ENTRY_STUBS}/mount" "${ENTRY_STUBS}/setpriv"
reset_log
PATH="${ENTRY_STUBS}:${PATH}" bash "${ROOT_DIR}/profile/entrypoint.sh" bash
assert_log "mount -o remount,bind,noexec,nosuid,nodev /tmp" "entrypoint remounts /tmp noexec,nosuid,nodev"
assert_last_log "setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps=-all --bounding-set=-all --nnp ${ROOT_DIR}/profile/entrypoint.sh bash" \
    "privileges are dropped only after /tmp is hardened"
reset_log
assert_fails "entrypoint aborts when a mount fails" \
    env PATH="${ENTRY_STUBS}:${PATH}" MOCK_MOUNT_FAIL=1 bash "${ROOT_DIR}/profile/entrypoint.sh" bash
assert_no_log "setpriv" "a failed mount never reaches setpriv"

# Test 25: -P forwards verbatim to --publish, repeatable, after the workdir and before the image
echo "Test 25: run -P forwards to podman --publish..."
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run -P 127.0.0.1:9000:8080 -P 9001 echo hi)
assert_last_log "${PODMAN_DIRECT_RUN} --workdir /home/ai/sandbox --publish 127.0.0.1:9000:8080 --publish 9001 paddock:latest echo hi" \
    "-P is repeatable and passed through unchanged"
assert_argv "<--publish><127.0.0.1:9000:8080><--publish><9001><paddock:latest>" \
    "publish values are separate argv tokens"
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run -P 8080)
assert_last_log "${PODMAN_DIRECT_RUN} --workdir /home/ai/sandbox --publish 8080 paddock:latest" \
    "-P alone takes the direct path instead of runlabel"
assert_fails "run -P without argument is rejected" \
    env MOCK_IMAGES="${IMAGES}" bash -c "cd '${MOCK_WORKSPACE}' && '${ROOT_DIR}/paddock.sh' run -P"

# Test 26: -p publishes 4096 on loopback and leaves the command alone
echo "Test 26: run -p publishes 4096 on loopback..."
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run -p)
assert_last_log "${PODMAN_DIRECT_RUN} --workdir /home/ai/sandbox --publish 127.0.0.1:4096:4096 paddock:latest" \
    "-p publishes 4096 on loopback without adding a command"

# Test 27: publishing never enters the baked label or bare runs
echo "Test 27: publishing stays out of the baked label..."
reset_log
MOCK_IMAGES="" "${ROOT_DIR}/paddock.sh" build
assert_no_log "--publish" "build label has no --publish"
reset_log
(cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run)
assert_last_log "podman container runlabel run paddock:latest" "bare run still uses runlabel"
assert_no_log "--publish" "bare run has no --publish"

# Test 28: build forwards extra args to podman build, before the context dir
echo "Test 28: build forwards extra args to podman build..."
reset_log
MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" build --no-cache --build-arg "X=a b"
assert_last_log "podman build -t paddock:latest -f ${CONTAINERFILE} --label run=${LABEL} --no-cache --build-arg X=a b ${ROOT_DIR}" \
    "build args are forwarded ahead of the context directory"
assert_argv "<--no-cache><--build-arg><X=a b><${ROOT_DIR}>" \
    "forwarded args stay separate argv tokens"

# --- home repository: init, git, sops filter, restore ------------------------

# Real git on throwaway repos; sops is a fake (MOCK_SOPS_FAIL[_DECRYPT] force failures).
if command -v git > /dev/null 2>&1; then
    cat << 'EOF' > "${MOCK_BIN}/sops"
#!/bin/bash
rules=
if [ "$1" = --config ]; then rules="$(head -n 1 "$2")"; shift 2; fi
mode="$1"; shift
echo "sops ${mode} rules=${rules}" >> "${MOCK_LOG}"
[ -z "${MOCK_SOPS_FAIL:-}" ] || exit 1
[ "${mode}" != decrypt ] || [ -z "${MOCK_SOPS_FAIL_DECRYPT:-}" ] || exit 1
file=
while [ $# -gt 0 ]; do
    case "$1" in
        --filename-override | --input-type | --output-type) shift 2 ;;
        *) file="$1"; shift ;;
    esac
done
data="$(cat ${file:+"${file}"} && echo x)" || exit 1
data="${data%x}"
case "${mode}" in
    encrypt) echo "mac: ENC[AES256_GCM,${RANDOM}]:$(printf %s "${data}" | base64 -w0)" ;;
    decrypt) [[ "${data}" == "mac: ENC["* ]] && { data="${data#*]:}"; printf %s "${data%$'\n'}" | base64 -d; } ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "${MOCK_BIN}/sops"
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

    HOME_GIT="${HOME}/.local/share/paddock/home.git"
    PADDOCK="${ROOT_DIR}/paddock.sh"
    SECRET=.config/example/secret.json
    rm -rf "${PADDOCK_HOME}" "${HOME_GIT}"

    fail() { echo "FAIL: $1" >&2; exit 1; }
    # blob_id <path>: the staged blob of a tracked file
    blob_id() { "${PADDOCK}" git rev-parse ":$1"; }
    # assert_staged_encrypted <path> <message>
    assert_staged_encrypted() {
        case "$("${PADDOCK}" git cat-file blob ":$1")" in
            "mac: ENC["*) ;;
            *) fail "$2" ;;
        esac
    }

    # Test 29: git without a repository points at init
    echo "Test 29: git requires an initialized home repository..."
    assert_fails "'git' is rejected before 'init'" "${PADDOCK}" git status

    # Test 30: init creates a bare repo that hides untracked files
    echo "Test 30: init creates the home repository..."
    "${PADDOCK}" init > /dev/null
    assert_dir "${HOME_GIT}" "Bare home repository is created"
    assert_dir "${PADDOCK_HOME}" "Home directory is created"
    [ "$(git --git-dir="${HOME_GIT}" config status.showUntrackedFiles)" = no ] \
        || fail "untracked files are not hidden"
    echo "PASS: untracked files are hidden"

    # Test 31: the rules are committed first, then secrets are stored encrypted
    echo "Test 31: tracked secrets are stored encrypted, the home stays plaintext..."
    mkdir -p "${PADDOCK_HOME}/.config/example" "${PADDOCK_HOME}/.gemini"
    echo 'password-in-clear' > "${PADDOCK_HOME}/${SECRET}"
    echo 'export FOO=1' > "${PADDOCK_HOME}/.bashrc"
    echo '{}' > "${PADDOCK_HOME}/.gemini/settings.json"
    echo junk > "${PADDOCK_HOME}/opencode.db"
    echo '# committed rules' > "${PADDOCK_HOME}/.sops.yaml"
    echo "${SECRET} filter=sops diff=sops" > "${PADDOCK_HOME}/.gitattributes"
    "${PADDOCK}" git add .sops.yaml .gitattributes
    "${PADDOCK}" git commit -q -m rules
    echo '# guest rules' > "${PADDOCK_HOME}/.sops.yaml"
    reset_log
    "${PADDOCK}" git add "${SECRET}" .bashrc .gemini/settings.json
    assert_log "sops encrypt rules=# committed rules" "sops uses the committed rules, not the home's copy"
    echo '# committed rules' > "${PADDOCK_HOME}/.sops.yaml"
    "${PADDOCK}" git commit -q -m "two words"
    [ "$("${PADDOCK}" git log -1 --format=%s)" = "two words" ] || fail "git arguments with spaces were split"
    BLOB="$("${PADDOCK}" git show "HEAD:${SECRET}")"
    case "${BLOB}" in
        "mac: ENC["*) ;;
        *) fail "committed secret is not encrypted: ${BLOB}" ;;
    esac
    case "${BLOB}" in
        *password-in-clear*) fail "committed secret contains the plaintext" ;;
    esac
    [ "$(cat "${PADDOCK_HOME}/${SECRET}")" = password-in-clear ] || fail "the home copy is not plaintext"
    echo "PASS: repository holds ciphertext, home holds plaintext, arguments stay intact"

    # Test 32: plaintext staged under a filtered path, new or renamed, must not be committed
    echo "Test 32: the pre-commit check rejects plaintext under a filtered path..."
    echo 'other-secret' > "${PADDOCK_HOME}/.config/example/other.json"
    cp "${PADDOCK_HOME}/.gitattributes" "${HOME}/gitattributes.bak"
    echo ".config/example/other.json filter=sops" >> "${PADDOCK_HOME}/.gitattributes"
    "${PADDOCK}" git add .gitattributes .config/example/other.json
    out="$("${PADDOCK}" git commit -q -m leak 2>&1)" && fail "a plaintext secret was committed"
    case "${out}" in
        *"other.json is staged unencrypted"*) ;;
        *) fail "the pre-commit check did not explain the rejection: ${out}" ;;
    esac
    "${PADDOCK}" git reset -q
    mv "${HOME}/gitattributes.bak" "${PADDOCK_HOME}/.gitattributes"
    rm "${PADDOCK_HOME}/.config/example/other.json"
    echo "PASS: the pre-commit check refuses a secret its new rule did not encrypt"
    echo ".config/example/renamed.json filter=sops" >> "${PADDOCK_HOME}/.gitattributes"
    "${PADDOCK}" git commit -q -m "rule for renamed.json" .gitattributes
    "${PADDOCK}" git mv .gemini/settings.json .config/example/renamed.json
    out="$("${PADDOCK}" git commit -q -m leak 2>&1)" && fail "a renamed plaintext file was committed under a filtered path"
    case "${out}" in
        *"renamed.json is staged unencrypted"*) ;;
        *) fail "the pre-commit check did not explain the rejection: ${out}" ;;
    esac
    "${PADDOCK}" git mv .config/example/renamed.json .gemini/settings.json
    "${PADDOCK}" git reset -q
    echo "PASS: the pre-commit check refuses a plaintext file renamed into a filtered path"

    # Test 33: unchanged plaintext keeps the committed ciphertext
    echo "Test 33: the clean filter does not create phantom changes..."
    OLD_ID="$(blob_id "${SECRET}")"
    touch "${PADDOCK_HOME}/${SECRET}"
    [ -z "$("${PADDOCK}" git status --short)" ] || fail "touched secret shows as modified"
    "${PADDOCK}" git add "${SECRET}"
    [ "$(blob_id "${SECRET}")" = "${OLD_ID}" ] || fail "re-adding unchanged plaintext re-encrypted it"
    echo 'changed' > "${PADDOCK_HOME}/${SECRET}"
    "${PADDOCK}" git add "${SECRET}"
    [ "$(blob_id "${SECRET}")" != "${OLD_ID}" ] || fail "changed plaintext kept the old ciphertext"
    touch "${PADDOCK_HOME}/${SECRET}"
    [ "$("${PADDOCK}" git status --short)" = "M  ${SECRET}" ] || fail "a staged change shows as modified again"
    "${PADDOCK}" git reset -q
    echo 'password-in-clear' > "${PADDOCK_HOME}/${SECRET}"
    echo "PASS: ciphertext is reused when unchanged and replaced when changed"

    # Test 34: the guest cannot opt a secret out of the filter
    echo "Test 34: a guest-written .gitattributes cannot disable the filter..."
    echo "${SECRET} -filter -diff" > "${PADDOCK_HOME}/.gitattributes"
    echo 'changed-again' > "${PADDOCK_HOME}/${SECRET}"
    "${PADDOCK}" git add "${SECRET}"
    assert_staged_encrypted "${SECRET}" "the guest turned the filter off"
    "${PADDOCK}" git reset -q
    echo "${SECRET} filter=sops diff=sops" > "${PADDOCK_HOME}/.gitattributes"
    echo 'password-in-clear' > "${PADDOCK_HOME}/${SECRET}"
    echo "PASS: the committed .gitattributes wins over the home's copy"

    # Test 35: no private key re-encrypts, a failing encryption aborts the add
    echo "Test 35: sops failures never stage stale or plaintext content..."
    touch "${PADDOCK_HOME}/${SECRET}"
    MOCK_SOPS_FAIL_DECRYPT=1 "${PADDOCK}" git add "${SECRET}"
    [ "$(blob_id "${SECRET}")" != "${OLD_ID}" ] || fail "undecryptable HEAD blob was reused"
    assert_staged_encrypted "${SECRET}" "staged blob is not ciphertext"
    "${PADDOCK}" git reset -q
    echo 'changed' > "${PADDOCK_HOME}/${SECRET}"
    assert_fails "add aborts when sops fails" env MOCK_SOPS_FAIL=1 "${PADDOCK}" git add "${SECRET}"
    [ "$(blob_id "${SECRET}")" = "${OLD_ID}" ] || fail "a failed add changed the index"
    echo 'password-in-clear' > "${PADDOCK_HOME}/${SECRET}"
    echo "PASS: decrypt failure re-encrypts, encrypt failure aborts"

    # Test 36: git checkout -f restores a deleted home
    echo "Test 36: restoring the home with git checkout -f..."
    rm -rf "${PADDOCK_HOME}"
    reset_log
    (cd "${MOCK_WORKSPACE}" && MOCK_IMAGES="${IMAGES}" "${PADDOCK}" run)
    [ -z "$(ls -A "${PADDOCK_HOME}")" ] || fail "run restored files by itself"
    rm -rf "${PADDOCK_HOME}"
    assert_fails "'git' with the home missing is rejected" "${PADDOCK}" git status
    [ ! -d "${PADDOCK_HOME}" ] || fail "'git' created the home"
    "${PADDOCK}" init > /dev/null
    "${PADDOCK}" git checkout -q -f
    [ "$(cat "${PADDOCK_HOME}/${SECRET}")" = password-in-clear ] || fail "secret was not decrypted on restore"
    [ "$(cat "${PADDOCK_HOME}/.bashrc")" = 'export FOO=1' ] || fail ".bashrc was not restored"
    [ ! -e "${PADDOCK_HOME}/opencode.db" ] || fail "an untracked file appeared"
    [ -z "$("${PADDOCK}" git status --short)" ] || fail "restored home shows as modified"
    echo "PASS: git checkout -f restores the home with decrypted files"

    # Test 37: a failing sops aborts the checkout, and a retry recovers
    echo "Test 37: a failing sops aborts the restore..."
    rm -rf "${PADDOCK_HOME}"
    "${PADDOCK}" init > /dev/null
    assert_fails "checkout fails when sops fails" env MOCK_SOPS_FAIL=1 "${PADDOCK}" git checkout -q -f
    [ ! -e "${PADDOCK_HOME}/${SECRET}" ] || fail "a secret was written despite the failure"
    "${PADDOCK}" git checkout -q -f
    [ "$(cat "${PADDOCK_HOME}/${SECRET}")" = password-in-clear ] || fail "restore does not recover after a failure"

    # Test 38: the filter lives in the repo config, so plain git behaves like 'paddock.sh git'
    echo "Test 38: plain git on the home repository uses the sops filter..."
    plain_git() { (cd "${PADDOCK_HOME}" && git --git-dir="${HOME_GIT}" --work-tree="${PADDOCK_HOME}" "$@"); }
    echo 'changed-by-plain-git' > "${PADDOCK_HOME}/${SECRET}"
    plain_git add "${SECRET}"
    assert_staged_encrypted "${SECRET}" "plain git staged a secret unencrypted"
    plain_git reset -q
    echo 'password-in-clear' > "${PADDOCK_HOME}/${SECRET}"
    rm "${PADDOCK_HOME}/${SECRET}"
    plain_git checkout -q -- "${SECRET}"
    [ "$(cat "${PADDOCK_HOME}/${SECRET}")" = password-in-clear ] || fail "plain git did not decrypt on checkout"
    git --git-dir="${HOME_GIT}" config filter.sops.clean "'/gone/sops-filter.sh' clean %f"
    echo 'stale' > "${PADDOCK_HOME}/${SECRET}"
    assert_fails "plain git with a stale filter path refuses to add" plain_git add "${SECRET}"
    assert_fails "'paddock.sh git' has no side effects, so it keeps a stale filter path" \
        "${PADDOCK}" git add "${SECRET}"
    "${PADDOCK}" init > /dev/null
    "${PADDOCK}" git add "${SECRET}"
    assert_staged_encrypted "${SECRET}" "'init' did not repair a stale filter path"
    "${PADDOCK}" git reset -q
    echo 'password-in-clear' > "${PADDOCK_HOME}/${SECRET}"
    echo "PASS: plain git encrypts, decrypts, and fails loudly until init repairs a stale filter path"

    # Test 39: init URL clones, sets the upstream, repairs setup, and refuses an existing repository
    echo "Test 39: init clones a repository..."
    CLONE_DATA="${HOME}/xdg-clone"
    CLONE_HOME="${CLONE_DATA}/paddock/home"
    CLONE_GIT="${CLONE_DATA}/paddock/home.git"
    clone_paddock() { XDG_DATA_HOME="${CLONE_DATA}" "${PADDOCK}" "$@"; }
    mkdir -p "${CLONE_HOME}"
    echo local > "${CLONE_HOME}/.bashrc"
    clone_paddock init "${HOME_GIT}" > /dev/null
    ! clone_paddock git status --short | grep -q '^D' \
        || fail "a fresh clone stages every file as deleted, so the first commit would delete them"
    rm -rf "${CLONE_HOME}"
    clone_paddock init > /dev/null
    clone_paddock git checkout -q -f
    [ "$(cat "${CLONE_HOME}/${SECRET}")" = password-in-clear ] || fail "clone did not restore the decrypted secret"
    echo ".config/example/pulled.json filter=sops" >> "${PADDOCK_HOME}/.gitattributes"
    "${PADDOCK}" git commit -q -m rule .gitattributes
    echo 'pulled-secret' > "${PADDOCK_HOME}/.config/example/pulled.json"
    "${PADDOCK}" git add .config/example/pulled.json
    "${PADDOCK}" git commit -q -m pulled
    clone_paddock git pull -q 2>/dev/null
    [ "$(cat "${CLONE_HOME}/.config/example/pulled.json")" = pulled-secret ] \
        || fail "a pulled file whose rule arrived in the same pull stayed encrypted"
    [ "$(git --git-dir="${CLONE_GIT}" config status.showUntrackedFiles)" = no ] \
        || fail "clone does not hide untracked files"
    mkdir -p "${CLONE_HOME}/.agents"
    echo x > "${CLONE_HOME}/.agents/note"
    clone_paddock git add .agents/note
    clone_paddock git commit -q -m note
    clone_paddock git push -q || fail "a plain push from a clone fails (no upstream)"
    git --git-dir="${CLONE_GIT}" config --unset status.showUntrackedFiles
    clone_paddock init > /dev/null
    [ "$(git --git-dir="${CLONE_GIT}" config status.showUntrackedFiles)" = no ] \
        || fail "init does not repair showUntrackedFiles"
    assert_fails "init URL is rejected when the repository exists" \
        env XDG_DATA_HOME="${CLONE_DATA}" "${PADDOCK}" init "${HOME_GIT}"
else
    echo "SKIP: git not installed -- home repository tests not run"
fi

echo "=== All Paddock Tests Passed Successfully ==="

# Cleanup
rm -rf "${MOCK_BIN}" "${MOCK_LOG}" "${MOCK_ARGV_LOG}" "${MOCK_WORKSPACE}" "${HOME}"
