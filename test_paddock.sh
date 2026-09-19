#!/bin/bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_BIN="${ROOT_DIR}/mock_bin"
MOCK_LOG="/tmp/mock_podman.log"
CONTAINERFILE="${ROOT_DIR}/profile/Containerfile"
# The exact flattened label run_label() produces with no PADDOCK_*/
# XDG_DATA_HOME overrides set. `$${}HOME`/`$${}PWD` appear as raw argv here,
# since the mock doesn't simulate podman's own reparse -- see run_label()
# in paddock.sh for why that spelling is needed.
# shellcheck disable=SC2016
LABEL='podman run --rm --interactive --tty --runtime krun --network pasta --annotation krun.use_passt=1 --annotation krun.ram_mib=8192 --annotation krun.cpus=4 --cap-drop ALL --security-opt no-new-privileges --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=2048m --pids-limit 1024 --hostname paddock-latest --user ai --userns keep-id:uid=1000,gid=1000 --volume $${}HOME/.local/share/paddock/home:/home/ai:z --volume $${}PWD:/home/ai/sandbox:z --workdir /home/ai/sandbox paddock:latest'
BUILD="podman build -t paddock:latest -f ${CONTAINERFILE} --label run=${LABEL} ${ROOT_DIR}"
IMAGES="paddock:latest"

# --- Lint gate ---------------------------------------------------------------
# Lint before the functional tests. ShellCheck ships in the image, so it is
# always present inside a paddock sandbox. When it is missing the suite still
# runs, but the gate is NOT enforced -- hence the loud SKIP.
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

# --- build: build only what is missing or out of date ------------------------

# Test 1: a missing image is built
echo "Test 1: build when the image is missing..."
reset_log
MOCK_IMAGES="" "${ROOT_DIR}/paddock.sh" build
assert_log "${BUILD}" "Missing image is built"

# Test 2: nothing to do when the image is current
echo "Test 2: build when the image is current..."
reset_log
MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" build
assert_no_log "podman build" "Nothing is rebuilt when up to date"

# Test 3: an out-of-date image is rebuilt
echo "Test 3: build when the image is older than its Containerfile..."
reset_log
MOCK_IMAGES="${IMAGES}" MOCK_IMAGE_EPOCH=0 "${ROOT_DIR}/paddock.sh" build
assert_log "${BUILD}" "Stale image is rebuilt"

# --- rebuild: always build, ignoring the staleness check ---------------------

# Test 4: rebuild builds the image even though it is current
echo "Test 4: rebuild when the image is current..."
reset_log
MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" rebuild
assert_log "${BUILD}" "Rebuild forces the image"

# --- run: ensure the image, then delegate to the label -----------------------

# Test 5: run prepares the home directory and delegates to runlabel
echo "Test 5: run..."
reset_log
MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" run
assert_dir "${PADDOCK_HOME}" "Persistent home folder is created"
assert_no_log "podman build" "A current image is not rebuilt before running"
assert_last_log "podman container runlabel run paddock:latest" \
    "Run delegates to 'podman container runlabel'"

# Test 6: run builds first when the image is out of date
echo "Test 6: run rebuilds a stale image before launching..."
reset_log
MOCK_IMAGES="${IMAGES}" MOCK_IMAGE_EPOCH=0 "${ROOT_DIR}/paddock.sh" run
assert_log "${BUILD}" "Stale image is rebuilt before launching"
assert_last_log "podman container runlabel run paddock:latest" \
    "Launch still happens after the rebuild"

# --- error handling ----------------------------------------------------------

# Test 7: an unknown action is rejected
echo "Test 7: rejecting an unknown action..."
assert_fails "'nosuch' is rejected" env MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" nosuch

# --- personal override: ~/.local/share/paddock/Containerfile takes ----------
# --- precedence over the shipped profile/Containerfile ----------------------

# Test 8: a personal override takes precedence over the shipped Containerfile,
# and still resolves to the same image tag and baked-in label.
echo "Test 8: a personal override takes precedence over the shipped Containerfile..."
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

# Test 9: paddock.sh delegates every mount and security flag to `LABEL run`, so
# the mock cannot observe them directly -- it only sees the `podman build
# --label run=...` argument on the logged command line. Assert the
# non-negotiable controls are present there.
# Tunables (sizes, counts) are deliberately NOT pinned to a single value here
# (Test 10 covers that they are overridable), only that the control exists.
echo "Test 9: verifying security invariants in the baked-in run label..."
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

# Test 10: PADDOCK_RAM_MIB/CPUS/PIDS_LIMIT/TMP_SIZE override the defaults
# baked into the run label at build time.
echo "Test 10: resource limits are customizable via env vars..."
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

# Test 11: an XDG_DATA_HOME that is itself $HOME plus a fixed suffix keeps
# the portable $${}HOME token -- only the suffix is baked in.
echo "Test 11: a \$HOME-relative XDG_DATA_HOME keeps the portable \$HOME token..."
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

# Test 12: a non-$HOME-relative XDG_DATA_HOME bakes in a fully resolved
# path instead, since there is no $HOME-relative form to express it.
echo "Test 12: a non-\$HOME-relative XDG_DATA_HOME bakes in a resolved path..."
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

# Test 13: ensure_image() validates the Containerfile even when the image
# already exists -- an existing tag doesn't by itself prove the shipped
# Containerfile is still there.
#
# Tests 13 and 14 both move/mutate the real shipped Containerfile. Restore it
# on every exit path -- including a failing assertion under `set -e` -- or a
# mid-test failure leaves the working tree without it.
restore_containerfile() {
    if [ -f "${CONTAINERFILE}.bak" ]; then
        mv -f "${CONTAINERFILE}.bak" "${CONTAINERFILE}"
    fi
}
trap restore_containerfile EXIT

echo "Test 13: a missing Containerfile is rejected even if the image exists..."
mv "${CONTAINERFILE}" "${CONTAINERFILE}.bak"
assert_fails "'build' is rejected when the Containerfile is missing" \
    env MOCK_IMAGES="${IMAGES}" "${ROOT_DIR}/paddock.sh" build
mv "${CONTAINERFILE}.bak" "${CONTAINERFILE}"

# Test 14: upgrade updates Containerfile build variables safely
echo "Test 14: upgrade assistants..."
# Preserve mtime: a plain `cp` would make the restored file look newer than
# the image built from it, forcing every subsequent build to look stale.
cp -p "${CONTAINERFILE}" "${CONTAINERFILE}.bak"

# Run upgrade (will trigger upgrade for gemini-cli to 0.55.0)
"${ROOT_DIR}/paddock.sh" upgrade

# Assert the Containerfile variables are correctly updated
if ! grep -q "ARG GEMINI_CLI_VER=0.55.0" "${CONTAINERFILE}"; then
    echo "FAIL: GEMINI_CLI_VER was not updated to 0.55.0" >&2
    exit 1
fi

mv -f "${CONTAINERFILE}.bak" "${CONTAINERFILE}"
echo "PASS: upgrade successfully updates Containerfile parameters"

echo "=== All Paddock Tests Passed Successfully ==="

# Cleanup
rm -rf "${MOCK_BIN}" "${MOCK_LOG}" "${HOME}"
