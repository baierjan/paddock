#!/bin/bash
set -e

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
    if [ "$1" = "base" ]; then echo "paddock-base:latest"; else echo "paddock:$1"; fi
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
        mtime="$(stat -c %Y "${file}" 2>/dev/null || echo 0)"
        if [ "${mtime}" -gt "${newest}" ]; then
            newest="${mtime}"
        fi
    done
    echo "${newest}"
}

# assert_profile <profile> -- abort unless the profile has a Containerfile.
assert_profile() {
    [ -f "${PROFILES_DIR}/$1/Containerfile" ] \
        || error "Profile '$1' not found at ${PROFILES_DIR}/$1/Containerfile"
}

# build_profile <profile>
# Unconditional build of a single image, and the single point at which an
# unknown profile is rejected. Dependency ordering is the caller's job, so that
# base is refreshed exactly once per invocation.
build_profile() {
    local profile="$1" tag
    assert_profile "${profile}"
    tag="$(image_tag "${profile}")"

    info "Building image '${tag}'..."
    podman build -t "${tag}" -f "${PROFILES_DIR}/${profile}/Containerfile" "${ROOT_DIR}"
}

# ensure_image <profile>
# Rebuilds when the image is missing or older than its inputs. Every mount and
# security flag lives in the image's `LABEL run`, so an out-of-date image would
# otherwise keep silently applying the previous limits.
ensure_image() {
    local profile="$1" tag reason="" built inputs
    tag="$(image_tag "${profile}")"

    # A profile is built FROM the base image, so bring that up to date first.
    if [ "${profile}" != "base" ]; then
        ensure_image "base"
    fi

    if ! podman image exists "${tag}"; then
        reason="is missing"
    else
        built="$(image_epoch "${tag}")"
        inputs="$(newest_epoch \
            "${PROFILES_DIR}/${profile}/Containerfile" \
            "${PROFILES_DIR}/${profile}/entrypoint.sh")"
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
    local profile="$1"
    local tag="paddock:${profile}"

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

# Main routing
ACTION="$1"
PROFILE="${2:-latest}"

if [ -z "${ACTION}" ] || [ "${ACTION}" = "help" ] || [ "${ACTION}" = "--help" ] || [ "${ACTION}" = "-h" ]; then
    echo "Usage: $0 {build|rebuild|run} [profile]   (profile defaults to 'latest')"
    echo "Examples:"
    echo "  $0 build            # Build the profile if it is missing or out of date"
    echo "  $0 rebuild base     # Force a rebuild, ignoring the staleness check"
    echo "  $0 run              # Build if needed, then launch the sandbox"
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
    *)
        error "Unknown action '${ACTION}'. Use 'build', 'rebuild' or 'run'."
        ;;
esac
