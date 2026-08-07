#!/bin/bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_BIN="${ROOT_DIR}/mock_bin"
MOCK_LOG="/tmp/mock_podman.log"
CONTAINERFILE="${ROOT_DIR}/profiles/default/Containerfile"
BASE_CONTAINERFILE="${ROOT_DIR}/profiles/base/Containerfile"
BUILD_BASE="podman build -t paddock-base:latest -f ${BASE_CONTAINERFILE} ${ROOT_DIR}"
# The exact flattened label run_label_for() produces with no PADDOCK_*/
# XDG_DATA_HOME overrides set. `$${}HOME`/`$${}PWD` appear as raw argv here,
# since the mock doesn't simulate podman's own reparse -- see run_label_for()
# in paddock.sh for why that spelling is needed.
# shellcheck disable=SC2016
DEFAULT_LABEL='podman run --rm --interactive --tty --runtime krun --network pasta --annotation krun.use_passt=1 --annotation krun.ram_mib=8192 --annotation krun.cpus=4 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=2048m --pids-limit 1024 --hostname paddock-latest --user ai --userns keep-id:uid=1000,gid=1000 --volume $${}HOME/.local/share/paddock/homes/default:/home/ai:z --volume $${}PWD:/home/ai/sandbox:z --workdir /home/ai/sandbox paddock:latest'
BUILD_DEFAULT="podman build -t paddock:latest -f ${CONTAINERFILE} --label run=${DEFAULT_LABEL} ${ROOT_DIR}"
BOTH_IMAGES="paddock-base:latest paddock:latest"

# --- Lint gate ---------------------------------------------------------------
# Lint before the functional tests. ShellCheck ships in the `default` profile,
# so it is always present inside a paddock sandbox. When it is missing the suite
# still runs, but the gate is NOT enforced -- hence the loud SKIP.
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
mkdir -p "${MOCK_BIN}"
: > "${MOCK_LOG}"

# Create mock podman command. Both stubbed queries are driven by environment
# variables so every test states its own preconditions -- no shared state, no
# ordering between tests.
cat << 'EOF' > "${MOCK_BIN}/podman"
#!/bin/bash
echo "podman $*" >> "/tmp/mock_podman.log"
# Which images exist: space-separated tags in MOCK_IMAGES (default: none).
if [ "$1" = "image" ] && [ "$2" = "exists" ]; then
    case " ${MOCK_IMAGES:-} " in
        *" $3 "*) exit 0 ;;
        *) exit 1 ;;
    esac
fi
# Image creation time for the staleness check; far future = always current.
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
    echo "${MOCK_IMAGE_EPOCH:-9999999999}"
    exit 0
fi
EOF
chmod +x "${MOCK_BIN}/podman"

# Create mock curl command to simulate offline NPM registry responses
cat << 'EOF' > "${MOCK_BIN}/curl"
#!/bin/bash
# Check which package's latest metadata is requested
if [[ "$*" == *"@google/gemini-cli/latest"* ]]; then
    # Return simulated payload with an upgraded mock version 0.55.0
    echo '{"version":"0.55.0","dist":{"tarball":"https://registry.npmjs.org/@google/gemini-cli/-/gemini-cli-0.55.0.tgz","integrity":"sha512-Olber5MK116YhYzdSn0/UPNo3rbxj4CJEgSBARIELwKFm1NHGJ4Fc7kMjvEPPLtxip0Aki8xUM28HG4sQ2GE0g=="}}'
elif [[ "$*" == *"opencode-ai/latest"* ]]; then
    # Return simulated payload with an up-to-date version matching current (1.18.14)
    echo '{"version":"1.18.14","dist":{"tarball":"https://registry.npmjs.org/opencode-ai/-/opencode-ai-1.18.14.tgz","integrity":"sha512-E5son8EQkh+cQ3bYkeGCOSNTcx8wmgsHBZ3bJjY0rOA84JaRb3VvqkfT41A8ChgEzwbSNe7uzEHDKqJOkNMynQ=="}}'
else
    /usr/bin/curl "$@"
fi
EOF
chmod +x "${MOCK_BIN}/curl"

export PATH="${MOCK_BIN}:${PATH}"

# Ensure XDG variables are unset for deterministic test paths
unset XDG_DATA_HOME
unset XDG_CONFIG_HOME

# Override HOME to verify home directory creation
export HOME="${ROOT_DIR}/mock_home"
rm -rf "${HOME}"
mkdir -p "${HOME}"
DEFAULT_HOME="${HOME}/.local/share/paddock/homes/default"
OVERRIDE_ROOT="${HOME}/.local/share/paddock/profiles"

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

# --- build: build only what is missing or out of date ------------------------

# Test 1: a missing base image is built
echo "Test 1: build base when the image is missing..."
reset_log
MOCK_IMAGES="" "${ROOT_DIR}/paddock.sh" build base
assert_log "${BUILD_BASE}" "Missing base is built"

# Test 2: a missing profile is built, a current base is left alone
echo "Test 2: build default when only base exists..."
reset_log
MOCK_IMAGES="paddock-base:latest" "${ROOT_DIR}/paddock.sh" build default
assert_log "${BUILD_DEFAULT}" "Missing profile is built"
assert_no_log "${BUILD_BASE}" "Current base is not rebuilt"

# Test 3: nothing to do when both images are current (profile defaults to 'default')
echo "Test 3: build when everything is current..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" build
assert_no_log "podman build" "Nothing is rebuilt when up to date"

# Test 4: an out-of-date image is rebuilt, and a stale base cascades
echo "Test 4: build when the images are older than their Containerfiles..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" MOCK_IMAGE_EPOCH=0 "${ROOT_DIR}/paddock.sh" build default
assert_log "${BUILD_BASE}" "Stale base is rebuilt"
assert_log "${BUILD_DEFAULT}" "Stale profile is rebuilt"

# --- rebuild: always build, ignoring the staleness check ---------------------

# Test 5: rebuild builds both images even though they are current
echo "Test 5: rebuild default when everything is current..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" rebuild default
assert_log "${BUILD_BASE}" "Rebuild forces the base image"
assert_last_log "${BUILD_DEFAULT}" "Rebuild builds the profile after its base"

# Test 6: rebuilding base alone must not build it twice
echo "Test 6: rebuild base..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" rebuild base
if [ "$(grep -c "^${BUILD_BASE}$" "${MOCK_LOG}")" != "1" ]; then
    echo "FAIL: 'rebuild base' should build the base image exactly once" >&2
    cat "${MOCK_LOG}" >&2
    exit 1
fi
echo "PASS: 'rebuild base' builds the base image exactly once"

# --- run: ensure the image, then delegate to the label -----------------------

# Test 7: run prepares the home directory and delegates to runlabel
echo "Test 7: run default..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" run default
assert_dir "${DEFAULT_HOME}" "Persistent home folder is created"
assert_no_log "podman build" "A current image is not rebuilt before running"
assert_last_log "podman container runlabel run paddock:latest" \
    "Run delegates to 'podman container runlabel'"

# Test 8: run builds first when the image is out of date
echo "Test 8: run rebuilds a stale image before launching..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" MOCK_IMAGE_EPOCH=0 "${ROOT_DIR}/paddock.sh" run
assert_log "${BUILD_DEFAULT}" "Stale image is rebuilt before launching"
assert_last_log "podman container runlabel run paddock:latest" \
    "Launch still happens after the rebuild"

# --- error handling ----------------------------------------------------------

# Test 9: `base` is an abstract image and must not be runnable
echo "Test 9: rejecting 'run base'..."
reset_log
assert_fails "'run base' is rejected" env MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" run base
assert_no_log "runlabel" "'run base' never reaches podman"

# Test 10: an unknown profile is rejected on both verbs
echo "Test 10: rejecting an unknown profile..."
assert_fails "'build nosuch' is rejected" env MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" build nosuch
assert_fails "'run nosuch' is rejected" env MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" run nosuch

# --- personal overrides: ~/.local/share/paddock/profiles/<name>/ takes -------
# --- precedence over the shipped profiles/<name>/, per profile, but the ------
# --- image tag never changes --------------------------------------------

# Test 11: an unrelated profile name is unaffected by an override that exists
# for a different profile -- overrides are keyed by the real profile name,
# with no shared special case between them.
echo "Test 11: an override for one profile does not leak into another..."
mkdir -p "${OVERRIDE_ROOT}/default"
echo 'FROM paddock-base:latest' > "${OVERRIDE_ROOT}/default/Containerfile"
reset_log
MOCK_IMAGES="" "${ROOT_DIR}/paddock.sh" build base
assert_log "${BUILD_BASE}" "'build base' ignores an active override for 'default'"
rm -rf "${OVERRIDE_ROOT}/default"

# Test 12: a personal override at ~/.local/share/paddock/profiles/<name>/ --
# never shipped, machine-local -- is used instead of the shipped
# profiles/<name>/Containerfile, and still resolves to the same image tag.
echo "Test 12: a personal override takes precedence over the shipped profile..."
OVERRIDE_DEFAULT="${OVERRIDE_ROOT}/default/Containerfile"
# 'default' is recognized by run_label_for() regardless of which Containerfile
# backs it, so the override build gets the same baked-in label as the shipped one.
BUILD_OVERRIDE_DEFAULT="podman build -t paddock:latest -f ${OVERRIDE_DEFAULT} --label run=${DEFAULT_LABEL} ${ROOT_DIR}"
mkdir -p "$(dirname "${OVERRIDE_DEFAULT}")"
echo 'FROM paddock-base:latest' > "${OVERRIDE_DEFAULT}"

reset_log
MOCK_IMAGES="paddock-base:latest" "${ROOT_DIR}/paddock.sh" build
assert_log "${BUILD_OVERRIDE_DEFAULT}" "'build default' uses the override, not profiles/default/"
assert_no_log "${BUILD_DEFAULT}" "profiles/default/Containerfile is not built while overridden"

rm -rf "${OVERRIDE_ROOT}/default"

# The mechanism is not special-cased to 'default': overriding 'base' works the
# same way, keyed by the real profile name.
OVERRIDE_BASE="${OVERRIDE_ROOT}/base/Containerfile"
BUILD_OVERRIDE_BASE="podman build -t paddock-base:latest -f ${OVERRIDE_BASE} ${ROOT_DIR}"
mkdir -p "$(dirname "${OVERRIDE_BASE}")"
echo 'FROM opensuse/tumbleweed' > "${OVERRIDE_BASE}"

reset_log
MOCK_IMAGES="" "${ROOT_DIR}/paddock.sh" build base
assert_log "${BUILD_OVERRIDE_BASE}" "'build base' uses its own override the same way"
assert_no_log "${BUILD_BASE}" "profiles/base/Containerfile is not built while overridden"

rm -rf "${OVERRIDE_ROOT}/base"
echo "PASS: personal overrides resolve per-profile and preserve tag naming"

# --- the baked-in label is the only definition of the sandbox ----------------

# Test 13: paddock.sh delegates every mount and security flag to `LABEL run`, so
# the mock cannot observe them directly -- it only sees the `podman build
# --label run=...` argument on the logged command line. Assert the
# non-negotiable controls are present there.
# Tunables (sizes, counts) are deliberately NOT pinned to a single value here
# (Test 14 covers that they are overridable), only that the control exists.
echo "Test 13: verifying security invariants in the baked-in run label..."
reset_log
MOCK_IMAGES="paddock-base:latest" "${ROOT_DIR}/paddock.sh" build default
LABEL="$(tail -n 1 "${MOCK_LOG}")"
# `$${}HOME`/`$${}PWD` below are the exact, unreparsed form run_label_for()
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
    '--volume $${}HOME/.local/share/paddock/homes/default:/home/ai:z' \
    '--volume $${}PWD:/home/ai/sandbox:z' \
    '--workdir /home/ai/sandbox'
do
    case "${LABEL}" in
        *"${flag}"*) ;;
        *)
            echo "FAIL: baked-in run label is missing required flag: ${flag}" >&2
            echo "  label: ${LABEL}" >&2
            exit 1
            ;;
    esac
done
echo "PASS: baked-in run label contains all required security flags"

# Test 14: PADDOCK_RAM_MIB/CPUS/PIDS_LIMIT/TMP_SIZE override the defaults
# baked into the 'default' profile's run label at build time.
echo "Test 14: resource limits are customizable via env vars..."
reset_log
MOCK_IMAGES="paddock-base:latest" \
    PADDOCK_RAM_MIB=4096 PADDOCK_CPUS=2 PADDOCK_PIDS_LIMIT=256 PADDOCK_TMP_SIZE=512m \
    "${ROOT_DIR}/paddock.sh" build default
LABEL="$(tail -n 1 "${MOCK_LOG}")"
for flag in \
    '--annotation krun.ram_mib=4096' \
    '--annotation krun.cpus=2' \
    '--pids-limit 256' \
    'size=512m'
do
    case "${LABEL}" in
        *"${flag}"*) ;;
        *)
            echo "FAIL: PADDOCK_* env vars did not override the label: ${flag}" >&2
            echo "  label: ${LABEL}" >&2
            exit 1
            ;;
    esac
done
echo "PASS: resource limits are overridable via PADDOCK_* env vars"

# Test 15: an XDG_DATA_HOME that is itself $HOME plus a fixed suffix keeps
# the portable $${}HOME token -- only the suffix is baked in.
echo "Test 15: a \$HOME-relative XDG_DATA_HOME keeps the portable \$HOME token..."
reset_log
MOCK_IMAGES="paddock-base:latest" XDG_DATA_HOME="${HOME}/xdg-data" \
    "${ROOT_DIR}/paddock.sh" build default
LABEL="$(tail -n 1 "${MOCK_LOG}")"
# shellcheck disable=SC2016
case "${LABEL}" in
    *'--volume $${}HOME/xdg-data/paddock/homes/default:/home/ai:z'*)
        echo "PASS: the \$HOME-relative suffix is baked in, the \$HOME token stays portable" ;;
    *)
        echo "FAIL: a \$HOME-relative XDG_DATA_HOME did not keep the portable \$HOME token" >&2
        echo "  label: ${LABEL}" >&2
        exit 1
        ;;
esac

# Test 16: a non-$HOME-relative XDG_DATA_HOME bakes in a fully resolved
# path instead, since there is no $HOME-relative form to express it.
echo "Test 16: a non-\$HOME-relative XDG_DATA_HOME bakes in a resolved path..."
reset_log
MOCK_IMAGES="paddock-base:latest" XDG_DATA_HOME="/mnt/xdg-data" \
    "${ROOT_DIR}/paddock.sh" build default
LABEL="$(tail -n 1 "${MOCK_LOG}")"
case "${LABEL}" in
    *"--volume /mnt/xdg-data/paddock/homes/default:/home/ai:z"*)
        echo "PASS: XDG_DATA_HOME is baked into the home volume path" ;;
    *)
        echo "FAIL: XDG_DATA_HOME was not reflected in the baked-in label" >&2
        echo "  label: ${LABEL}" >&2
        exit 1
        ;;
esac
# shellcheck disable=SC2016
case "${LABEL}" in
    *'--volume $${}HOME'*)
        echo "FAIL: label still contains the portable literal \$HOME token" >&2
        exit 1
        ;;
    *) echo "PASS: the portable literal \$HOME token is gone once XDG_DATA_HOME points elsewhere" ;;
esac

# Test 17: upgrade updates base Containerfile build variables safely
echo "Test 17: upgrade assistants..."
# Create a backup of Containerfile
cp "${BASE_CONTAINERFILE}" "${BASE_CONTAINERFILE}.bak"

# Run upgrade (will trigger upgrade for gemini-cli to 0.55.0, opencode stays at 1.18.14)
"${ROOT_DIR}/paddock.sh" upgrade

# Assert the Containerfile variables are correctly updated
if ! grep -q "ARG GEMINI_CLI_VER=0.55.0" "${BASE_CONTAINERFILE}"; then
    echo "FAIL: GEMINI_CLI_VER was not updated to 0.55.0" >&2
    mv "${BASE_CONTAINERFILE}.bak" "${BASE_CONTAINERFILE}"
    exit 1
fi
if ! grep -q "ARG OPENCODE_AI_VER=1.18.14" "${BASE_CONTAINERFILE}"; then
    echo "FAIL: OPENCODE_AI_VER was altered from 1.18.14" >&2
    mv "${BASE_CONTAINERFILE}.bak" "${BASE_CONTAINERFILE}"
    exit 1
fi

# Restore backup
mv "${BASE_CONTAINERFILE}.bak" "${BASE_CONTAINERFILE}"
echo "PASS: upgrade successfully updates Containerfile parameters"

echo "=== All Paddock Tests Passed Successfully ==="

# Cleanup
rm -rf "${MOCK_BIN}" "${MOCK_LOG}" "${HOME}"