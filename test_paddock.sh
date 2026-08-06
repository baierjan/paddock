#!/bin/bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_BIN="${ROOT_DIR}/mock_bin"
MOCK_LOG="/tmp/mock_podman.log"
CONTAINERFILE="${ROOT_DIR}/profiles/default/Containerfile"
BASE_CONTAINERFILE="${ROOT_DIR}/profiles/base/Containerfile"
OVERRIDE_CONTAINERFILE="${ROOT_DIR}/profiles/latest/Containerfile"
BUILD_BASE="podman build -t paddock-base:latest -f ${BASE_CONTAINERFILE} ${ROOT_DIR}"
BUILD_DEFAULT="podman build -t paddock:latest -f ${CONTAINERFILE} ${ROOT_DIR}"
BUILD_OVERRIDE="podman build -t paddock:latest -f ${OVERRIDE_CONTAINERFILE} ${ROOT_DIR}"
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

# --- Helpers -----------------------------------------------------------------

reset_log() { : > "${MOCK_LOG}"; }

# label_run -- flattens the profile's `LABEL run` to a single line. `$HOME` and
# `$PWD` are left unexpanded: podman substitutes those at runlabel time, so the
# label is asserted in the form it is stored in.
label_run() {
    sed -n '/^LABEL run="/,/"$/p' "${CONTAINERFILE}" \
        | sed -e 's/\\$//' \
        | tr '\n' ' ' \
        | sed -e 's/^LABEL run="//' -e 's/"[[:space:]]*$//' \
        | tr -s ' ' \
        | sed -e 's/[[:space:]]*$//' -e 's/\\\$/$/g'
}

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

# --- 'default' resolution: personal override takes precedence over the -------
# --- shipped profile, but the image tag never changes ------------------------

# Test 11: explicit 'latest' is an ordinary profile name, not an alias of
# 'default'. Only 'default' gets override-preferring resolution (see
# containerfile_for() in paddock.sh) -- pinned here so it isn't "simplified"
# into a second special-cased name later.
echo "Test 11: 'latest' with no local override behaves like any other unknown profile..."
assert_fails "'build latest' is rejected when profiles/latest/ does not exist" \
    env MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" build latest

# Test 12: a local profiles/latest/Containerfile -- a personal override, never
# shipped, listed in .gitignore -- is used instead of profiles/default/ for
# every spelling of the default profile, and still tags as 'paddock:latest'.
echo "Test 12: a local profiles/latest/ override takes precedence over profiles/default/..."
mkdir -p "$(dirname "${OVERRIDE_CONTAINERFILE}")"
echo 'FROM paddock-base:latest' > "${OVERRIDE_CONTAINERFILE}"

reset_log
MOCK_IMAGES="paddock-base:latest" "${ROOT_DIR}/paddock.sh" build
assert_log "${BUILD_OVERRIDE}" "Bare 'build' uses the override, not profiles/default/"
assert_no_log "${BUILD_DEFAULT}" "profiles/default/Containerfile is not built while overridden"

reset_log
MOCK_IMAGES="paddock-base:latest" "${ROOT_DIR}/paddock.sh" build latest
assert_log "${BUILD_OVERRIDE}" "Explicit 'build latest' resolves to the same override"

# The override must be scoped to the name "default" only -- any other profile,
# 'base' included, must ignore it even while it exists on disk.
reset_log
MOCK_IMAGES="" "${ROOT_DIR}/paddock.sh" build base
assert_log "${BUILD_BASE}" "'build base' ignores an active profiles/latest/ override"

rm -rf "$(dirname "${OVERRIDE_CONTAINERFILE}")"
echo "PASS: 'default' resolution and tag naming verified with an active override"

# --- the label is the only definition of the sandbox -------------------------

# Test 13: paddock.sh delegates every mount and security flag to `LABEL run`, so
# the mock cannot observe them. Assert the non-negotiable controls are present.
# Tunables (sizes, counts) are deliberately NOT pinned, only that the control
# exists, so limits can be retuned without touching this suite.
echo "Test 13: verifying security invariants in 'LABEL run'..."
LABEL="$(label_run)"
if [ -z "${LABEL}" ]; then
    echo "FAIL: Could not extract 'LABEL run' from ${CONTAINERFILE}" >&2
    exit 1
fi
# The `$HOME`/`$PWD` below are literal: the label stores them unexpanded and
# podman substitutes them at runlabel time, so they must be matched verbatim.
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
    '--volume $HOME/.local/share/paddock/homes/default:/home/ai:z' \
    '--volume $PWD:/home/ai/sandbox:z' \
    '--workdir /home/ai/sandbox'
do
    case "${LABEL}" in
        *"${flag}"*) ;;
        *)
            echo "FAIL: 'LABEL run' is missing required flag: ${flag}" >&2
            echo "  label: ${LABEL}" >&2
            exit 1
            ;;
    esac
done
echo "PASS: 'LABEL run' contains all required security flags"

# Test 14: upgrade updates base Containerfile build variables safely
echo "Test 14: upgrade assistants..."
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