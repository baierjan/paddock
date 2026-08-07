#!/bin/bash
set -eo pipefail

# Determine directories
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${ROOT_DIR}/profiles"

# Colors for output
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# Helper: check for podman
command -v podman >/dev/null 2>&1 || error "Podman is required but not installed."

# image_tag <profile> -- the image name a profile builds to.
image_tag() {
    case "$1" in
        base) echo "paddock-base:latest" ;;
        default) echo "paddock:latest" ;;
        *) echo "paddock:$1" ;;
    esac
}

# containerfile_for <profile> -- the Containerfile that backs a profile name.
# A personal override at ~/.local/share/paddock/profiles/<profile>/Containerfile
# takes precedence over the shipped profiles/<profile>/Containerfile, for every
# profile name (including "base"). This is the one customization point that
# works both from a git checkout and from a packaged (read-only) install.
containerfile_for() {
    local override="${HOME}/.local/share/paddock/profiles/$1/Containerfile"
    if [ -f "${override}" ]; then
        echo "${override}"
    else
        echo "${PROFILES_DIR}/$1/Containerfile"
    fi
}

# image_epoch <tag> -- image creation time in seconds since the epoch, 0 if unknown.
image_epoch() {
    podman image inspect --format '{{.Created.Unix}}' "$1" 2>/dev/null || echo 0
}

# newest_epoch <file>... -- most recent mtime among the files that exist, 0 if none.
newest_epoch() {
    local newest=0 mtime file
    for file in "$@"; do
        [ -f "${file}" ] || continue
        if stat --version 2>/dev/null | grep -q "GNU"; then
            mtime="$(stat -c %Y "${file}" 2>/dev/null || echo 0)"
        else
            mtime="$(stat -f %m "${file}" 2>/dev/null || echo 0)"
        fi
        if [ "${mtime}" -gt "${newest}" ]; then
            newest="${mtime}"
        fi
    done
    echo "${newest}"
}

# assert_profile <profile> -- abort unless the profile has a Containerfile.
assert_profile() {
    local cf
    cf="$(containerfile_for "$1")"
    [ -f "${cf}" ] || error "Profile '$1' not found at ${cf}"
}

# build_profile <profile>
# Unconditional build of a single image, and the single point at which an
# unknown profile is rejected. Dependency ordering is the caller's job, so that
# base is refreshed exactly once per invocation.
build_profile() {
    local profile="$1" tag cf
    assert_profile "${profile}"
    tag="$(image_tag "${profile}")"
    cf="$(containerfile_for "${profile}")"

    info "Building image '${tag}'..."
    podman build -t "${tag}" -f "${cf}" "${ROOT_DIR}"
}

# ensure_image <profile>
# Rebuilds when the image is missing or older than its inputs. Every mount and
# security flag lives in the image's `LABEL run`, so an out-of-date image would
# otherwise keep silently applying the previous limits.
ensure_image() {
    local profile="$1" tag cf reason="" built inputs
    # Validate the profile even if its image already exists and is current:
    # an existing tag doesn't by itself prove the Containerfile behind it
    # (shipped or personally overridden) still exists.
    assert_profile "${profile}"
    tag="$(image_tag "${profile}")"
    cf="$(containerfile_for "${profile}")"

    # A profile is built FROM the base image, so bring that up to date first.
    if [ "${profile}" != "base" ]; then
        ensure_image "base"
    fi

    if ! podman image exists "${tag}"; then
        reason="is missing"
    else
        built="$(image_epoch "${tag}")"
        inputs="$(newest_epoch "${cf}" "$(dirname "${cf}")/entrypoint.sh")"
        if [ "${inputs}" -gt "${built}" ]; then
            reason="is older than its Containerfile"
        elif [ "${profile}" != "base" ] && [ "$(image_epoch "$(image_tag base)")" -gt "${built}" ]; then
            reason="is older than paddock-base:latest"
        fi
    fi

    if [ -n "${reason}" ]; then
        info "Image '${tag}' ${reason}; rebuilding..."
        build_profile "${profile}"
    fi
}

# rebuild_profile <profile>
# Unconditional rebuild of the profile and, for non-base profiles, its base.
rebuild_profile() {
    local profile="$1"
    if [ "${profile}" != "base" ]; then
        build_profile "base"
    fi
    build_profile "${profile}"
}

run_profile() {
    local profile="$1" tag
    tag="$(image_tag "${profile}")"

    # `base` is an abstract parent image; it carries no `LABEL run` and is not
    # meant to be entered directly.
    [ "${profile}" = "base" ] && error "Profile 'base' is an abstract base image and cannot be run directly."

    # Build if the image is missing or its inputs have changed since it was built
    ensure_image "${profile}"

    # The profile's `LABEL run` owns every mount and security flag; this script
    # deliberately keeps no second copy of them. It only pre-creates the host
    # home directory so it is owned by the invoking user rather than by podman.
    local home_host="${HOME}/.local/share/paddock/homes/default"
    mkdir -p "${home_host}"

    # Listed in mount order: the home volume lands on /home/ai first, then the
    # workspace is mounted at /home/ai/sandbox inside it.
    info "Launching profile '${profile}' via 'podman container runlabel'..."
    info "Home directory: ${home_host} -> /home/ai"
    info "Workspace: $(pwd) -> /home/ai/sandbox"

    podman container runlabel run "${tag}"
}

# upgrade_assistants
# Sniffs latest stable release versions from the NPM registry,
# converts their SHA-512 Base64 hashes into Hex format, and updates
# profiles/base/Containerfile if newer versions are available.
upgrade_assistants() {
    local cf="${PROFILES_DIR}/base/Containerfile"
    [ -f "${cf}" ] || error "Base Containerfile not found at ${cf}"

    # Verify required host tools
    command -v curl >/dev/null 2>&1 || error "curl is required on the host for upgrades."
    command -v jq >/dev/null 2>&1 || error "jq is required on the host for upgrades."
    command -v openssl >/dev/null 2>&1 || error "openssl is required on the host for upgrades."

    # Parse current values from Containerfile
    local curr_gemini_ver; curr_gemini_ver="$(grep "ARG GEMINI_CLI_VER=" "${cf}" | cut -d= -f2)"
    local curr_opencode_ver; curr_opencode_ver="$(grep "ARG OPENCODE_AI_VER=" "${cf}" | cut -d= -f2)"

    info "Checking for upgrades..."
    info "Current @google/gemini-cli: ${curr_gemini_ver}"
    info "Current opencode-ai: ${curr_opencode_ver}"

    # Query latest stable versions and metadata
    local gemini_json; gemini_json="$(curl -fsSL https://registry.npmjs.org/@google/gemini-cli/latest)"
    local opencode_json; opencode_json="$(curl -fsSL https://registry.npmjs.org/opencode-ai/latest)"

    local latest_gemini_ver; latest_gemini_ver="$(echo "${gemini_json}" | jq -r .version)"
    local latest_opencode_ver; latest_opencode_ver="$(echo "${opencode_json}" | jq -r .version)"

    local needs_update=0
    local new_gemini_ver="${curr_gemini_ver}"
    local new_gemini_hash; new_gemini_hash="$(grep "ARG GEMINI_CLI_HASH=" "${cf}" | cut -d= -f2)"
    local new_opencode_ver="${curr_opencode_ver}"
    local new_opencode_hash; new_opencode_hash="$(grep "ARG OPENCODE_AI_HASH=" "${cf}" | cut -d= -f2)"

    # Handle Gemini CLI Upgrade
    if [ "${latest_gemini_ver}" != "${curr_gemini_ver}" ]; then
        info "New @google/gemini-cli version found: ${latest_gemini_ver}"
        local gemini_integrity; gemini_integrity="$(echo "${gemini_json}" | jq -r .dist.integrity)"
        local gemini_b64="${gemini_integrity#sha512-}"
        new_gemini_ver="${latest_gemini_ver}"
        new_gemini_hash="$(echo -n "${gemini_b64}" | openssl enc -base64 -d -A | od -An -tx1 | tr -d ' \n')"
        needs_update=1
    fi

    # Handle OpenCode AI Upgrade
    if [ "${latest_opencode_ver}" != "${curr_opencode_ver}" ]; then
        info "New opencode-ai version found: ${latest_opencode_ver}"
        local opencode_integrity; opencode_integrity="$(echo "${opencode_json}" | jq -r .dist.integrity)"
        local opencode_b64="${opencode_integrity#sha512-}"
        new_opencode_ver="${latest_opencode_ver}"
        new_opencode_hash="$(echo -n "${opencode_b64}" | openssl enc -base64 -d -A | od -An -tx1 | tr -d ' \n')"
        needs_update=1
    fi

    if [ "${needs_update}" -eq 1 ]; then
        info "Updating ${cf}..."
        sed \
          -e "s/ARG GEMINI_CLI_VER=.*/ARG GEMINI_CLI_VER=${new_gemini_ver}/" \
          -e "s/ARG GEMINI_CLI_HASH=.*/ARG GEMINI_CLI_HASH=${new_gemini_hash}/" \
          -e "s/ARG OPENCODE_AI_VER=.*/ARG OPENCODE_AI_VER=${new_opencode_ver}/" \
          -e "s/ARG OPENCODE_AI_HASH=.*/ARG OPENCODE_AI_HASH=${new_opencode_hash}/" \
          "${cf}" > "${cf}.tmp" && mv "${cf}.tmp" "${cf}"

        info "Successfully upgraded assistants in Containerfile!"
        info "To apply these changes, rebuild your base image using:"
        info "  ./paddock.sh rebuild base"
    else
        info "All AI assistants are already up to date!"
    fi
}

# Main routing
ACTION="$1"
PROFILE="${2:-default}"

if [ -z "${ACTION}" ] || [ "${ACTION}" = "help" ] || [ "${ACTION}" = "--help" ] || [ "${ACTION}" = "-h" ]; then
    echo "Usage: $0 {build|rebuild|run|upgrade} [profile]   (profile defaults to 'default')"
    echo "Examples:"
    echo "  $0 build            # Build the profile if it is missing or out of date"
    echo "  $0 rebuild base     # Force a rebuild, ignoring the staleness check"
    echo "  $0 run              # Build if needed, then launch the sandbox"
    echo "  $0 upgrade          # Fetch latest assistants and update hashes"
    echo
    echo "'default' always builds/runs as tag 'paddock:latest'. Any profile can be"
    echo "personally overridden via ~/.local/share/paddock/profiles/<profile>/Containerfile,"
    echo "which takes precedence over the shipped profiles/<profile>/Containerfile."
    exit 1
fi

case "${ACTION}" in
    build)
        ensure_image "${PROFILE}"
        ;;
    rebuild)
        rebuild_profile "${PROFILE}"
        ;;
    run)
        run_profile "${PROFILE}"
        ;;
    upgrade)
        upgrade_assistants
        ;;
    *)
        error "Unknown action '${ACTION}'. Use 'build', 'rebuild', 'run' or 'upgrade'."
        ;;
esac
