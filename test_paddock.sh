#!/bin/bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_BIN="${ROOT_DIR}/mock_bin"
MOCK_LOG="$(mktemp)"
export MOCK_LOG
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
mkdir -p "${MOCK_BIN}" "${MOCK_WORKSPACE}"
: > "${MOCK_LOG}"

# Both stubbed queries are driven by environment variables so every test
# states its own preconditions; no shared state, no ordering between tests.
cat << 'EOF' > "${MOCK_BIN}/podman"
#!/bin/bash
echo "podman $*" >> "${MOCK_LOG}"
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

reset_log() { : > "${MOCK_LOG}"; }

# assert_log <fixed-substring> <description>
assert_log() {
    if ! grep -qF "$1" "${MOCK_LOG}"; then
        echo "FAIL: $2" >&2
        cat "${MOCK_LOG}" >&2
        exit 1
    fi
    echo "PASS: $2"
}

# assert_no_log <fixed-substring> <description>
assert_no_log() {
    if grep -qF "$1" "${MOCK_LOG}"; then
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

echo "=== All Paddock Tests Passed Successfully ==="

# Cleanup
rm -rf "${MOCK_BIN}" "${MOCK_LOG}" "${MOCK_WORKSPACE}" "${HOME}"
