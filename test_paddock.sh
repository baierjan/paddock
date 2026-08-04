#!/bin/bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_BIN="${ROOT_DIR}/mock_bin"
MOCK_LOG="/tmp/mock_podman.log"
CONTAINERFILE="${ROOT_DIR}/profiles/latest/Containerfile"
BASE_CONTAINERFILE="${ROOT_DIR}/profiles/base/Containerfile"
BUILD_BASE="podman build -t paddock-base:latest -f ${BASE_CONTAINERFILE} ${ROOT_DIR}"
BUILD_LATEST="podman build -t paddock:latest -f ${CONTAINERFILE} ${ROOT_DIR}"
BOTH_IMAGES="paddock-base:latest paddock:latest"

# --- Lint gate ---------------------------------------------------------------
# Lint before the functional tests. ShellCheck ships in the `latest` profile, so
# it is always present inside a paddock sandbox. When it is missing the suite
# still runs, but the gate is NOT enforced -- hence the loud SKIP.
echo "=== Linting shell scripts ==="
if command -v shellcheck > /dev/null 2>&1; then
    mapfile -t SHELL_SCRIPTS < <(find "${ROOT_DIR}" -name '*.sh' -not -path '*/mock_*' | sort)
    if ! shellcheck "${SHELL_SCRIPTS[@]}"; then
        echo "FAIL: shellcheck reported issues"
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
        echo "FAIL: $2"
        cat "${MOCK_LOG}"
        exit 1
    fi
    echo "PASS: $2"
}

# assert_no_log <fixed-substring> <description>
assert_no_log() {
    if grep -qF "$1" "${MOCK_LOG}"; then
        echo "FAIL: $2"
        cat "${MOCK_LOG}"
        exit 1
    fi
    echo "PASS: $2"
}

# assert_last_log <expected-line> <description>
assert_last_log() {
    local actual
    actual="$(tail -n 1 "${MOCK_LOG}")"
    if [ "${actual}" != "$1" ]; then
        echo "FAIL: $2"
        echo "  expected: $1"
        echo "  actual  : ${actual}"
        exit 1
    fi
    echo "PASS: $2"
}

# assert_dir <path> <description>
assert_dir() {
    if [ ! -d "$1" ]; then
        echo "FAIL: $2 (missing $1)"
        exit 1
    fi
    echo "PASS: $2"
}

# assert_fails <description> <command...>
assert_fails() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then
        echo "FAIL: ${desc}"
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
echo "Test 2: build latest when only base exists..."
reset_log
MOCK_IMAGES="paddock-base:latest" "${ROOT_DIR}/paddock.sh" build latest
assert_log "${BUILD_LATEST}" "Missing profile is built"
assert_no_log "${BUILD_BASE}" "Current base is not rebuilt"

# Test 3: nothing to do when both images are current (profile defaults to latest)
echo "Test 3: build when everything is current..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" build
assert_no_log "podman build" "Nothing is rebuilt when up to date"

# Test 4: an out-of-date image is rebuilt, and a stale base cascades
echo "Test 4: build when the images are older than their Containerfiles..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" MOCK_IMAGE_EPOCH=0 "${ROOT_DIR}/paddock.sh" build latest
assert_log "${BUILD_BASE}" "Stale base is rebuilt"
assert_log "${BUILD_LATEST}" "Stale profile is rebuilt"

# --- rebuild: always build, ignoring the staleness check ---------------------

# Test 5: rebuild builds both images even though they are current
echo "Test 5: rebuild latest when everything is current..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" rebuild latest
assert_log "${BUILD_BASE}" "Rebuild forces the base image"
assert_last_log "${BUILD_LATEST}" "Rebuild builds the profile after its base"

# Test 6: rebuilding base alone must not build it twice
echo "Test 6: rebuild base..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" rebuild base
if [ "$(grep -c "^${BUILD_BASE}$" "${MOCK_LOG}")" != "1" ]; then
    echo "FAIL: 'rebuild base' should build the base image exactly once"
    cat "${MOCK_LOG}"
    exit 1
fi
echo "PASS: 'rebuild base' builds the base image exactly once"

# --- run: ensure the image, then delegate to the label -----------------------

# Test 7: run prepares the home directory and delegates to runlabel
echo "Test 7: run latest..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" "${ROOT_DIR}/paddock.sh" run latest
assert_dir "${DEFAULT_HOME}" "Persistent home folder is created"
assert_no_log "podman build" "A current image is not rebuilt before running"
assert_last_log "podman container runlabel run paddock:latest" \
    "Run delegates to 'podman container runlabel'"

# Test 8: run builds first when the image is out of date
echo "Test 8: run rebuilds a stale image before launching..."
reset_log
MOCK_IMAGES="${BOTH_IMAGES}" MOCK_IMAGE_EPOCH=0 "${ROOT_DIR}/paddock.sh" run
assert_log "${BUILD_LATEST}" "Stale image is rebuilt before launching"
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

# --- the label is the only definition of the sandbox -------------------------

# Test 11: paddock.sh delegates every mount and security flag to `LABEL run`, so
# the mock cannot observe them. Assert the non-negotiable controls are present.
# Tunables (sizes, counts) are deliberately NOT pinned, only that the control
# exists, so limits can be retuned without touching this suite.
echo "Test 11: verifying security invariants in 'LABEL run'..."
LABEL="$(label_run)"
if [ -z "${LABEL}" ]; then
    echo "FAIL: Could not extract 'LABEL run' from ${CONTAINERFILE}"
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
            echo "FAIL: 'LABEL run' is missing required flag: ${flag}"
            echo "  label: ${LABEL}"
            exit 1
            ;;
    esac
done
echo "PASS: 'LABEL run' contains all required security flags"

echo "=== All Paddock Tests Passed Successfully ==="

# Cleanup
rm -rf "${MOCK_BIN}" "${MOCK_LOG}" "${HOME}"
