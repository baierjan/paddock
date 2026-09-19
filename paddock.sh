#!/bin/bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${ROOT_DIR}/$(basename "${BASH_SOURCE[0]}")"

# Paddock's own persistent, machine-local state: the sandbox home and a
# personal Containerfile override. Honors XDG_DATA_HOME per the XDG Base
# Directory spec.
DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/paddock"

IMAGE="paddock:latest"

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

require_podman() {
    command -v podman >/dev/null 2>&1 || error "Podman is required but not installed."
}

# containerfile -- the Containerfile paddock builds. A personal override at
# ~/.local/share/paddock/Containerfile takes precedence over the shipped
# profile/Containerfile. This is the one customization point that works both
# from a git checkout and from a packaged (read-only) install.
containerfile() {
    local override="${DATA_HOME}/Containerfile"
    if [ -f "${override}" ]; then
        echo "${override}"
    else
        echo "${ROOT_DIR}/profile/Containerfile"
    fi
}

# resolved_containerfile -- containerfile(), rejecting a missing file.
resolved_containerfile() {
    local cf
    cf="$(containerfile)"
    [ -f "${cf}" ] || error "Containerfile not found at ${cf}"
    echo "${cf}"
}

# run_label -- the `podman run ...` string baked into the image via
# `podman build --label run=...`. Kept out of the Containerfile because it
# needs to read host state a static LABEL instruction cannot: env-var-driven
# resource limits, and an XDG-aware home path.
run_label() {
    local ram="${PADDOCK_RAM_MIB:-8192}"
    local cpus="${PADDOCK_CPUS:-4}"
    local pids="${PADDOCK_PIDS_LIMIT:-1024}"
    local tmp_size="${PADDOCK_TMP_SIZE:-2048m}"
    # Unvalidated values here get shlex-split into podman's argv via --label.
    [[ "${ram}" =~ ^[0-9]+$ ]] || error "PADDOCK_RAM_MIB must be a positive integer (MiB): '${ram}'"
    [[ "${cpus}" =~ ^[0-9]+$ ]] || error "PADDOCK_CPUS must be a positive integer: '${cpus}'"
    [[ "${pids}" =~ ^[0-9]+$ ]] || error "PADDOCK_PIDS_LIMIT must be a positive integer: '${pids}'"
    [[ "${tmp_size}" =~ ^[0-9]+[kKmMgG]?$ ]] || error "PADDOCK_TMP_SIZE must be an integer optionally suffixed with k/m/g: '${tmp_size}'"
    # $HOME/$PWD are spelled `$${}HOME`/`$${}PWD`, not plain or `\$`-escaped:
    # `--label` reparses the value through Dockerfile's own environment
    # substitution, which resolves a bare token at build time and doesn't
    # let `\$`-escaping survive either. See AGENTS.md, "The run label lives
    # in paddock.sh", for the full mechanism and the parser trace behind
    # this specific spelling.
    #
    # Portable by default (podman resolves $HOME fresh per invocation). If
    # XDG_DATA_HOME is itself $HOME plus a fixed suffix, only that suffix is
    # baked in, keeping the portable token; otherwise the fully resolved
    # path is baked in, since no $HOME-relative form exists to express it.
    # shellcheck disable=SC2016
    local home_volume='$${}HOME/.local/share/paddock/home'
    case "${XDG_DATA_HOME:-}" in
        "")
            ;;
        "${HOME}" | "${HOME}"/*)
            # shellcheck disable=SC2016
            home_volume="\$\${}HOME${XDG_DATA_HOME#"${HOME}"}/paddock/home"
            ;;
        *)
            home_volume="${DATA_HOME}/home"
            ;;
    esac
    # shellcheck disable=SC2016
    local pwd_volume='$${}PWD'

    # Array elements, not a string: the indentation is inter-word
    # whitespace, so it can't leak into the joined value below.
    local -a flags=(
        podman run --rm --interactive --tty
        --runtime krun
        --network pasta
        --annotation krun.use_passt=1
        "--annotation krun.ram_mib=${ram}"
        "--annotation krun.cpus=${cpus}"
        --cap-drop ALL
        --security-opt no-new-privileges
        --read-only
        "--tmpfs /tmp:rw,noexec,nosuid,nodev,size=${tmp_size}"
        "--pids-limit ${pids}"
        --hostname paddock-latest
        --user ai
        "--userns keep-id:uid=1000,gid=1000"
        "--volume ${home_volume}:/home/ai:z"
        "--volume ${pwd_volume}:/home/ai/sandbox:z"
        --workdir /home/ai/sandbox
        "${IMAGE}"
    )
    echo "${flags[*]}"
}

# image_epoch <tag> -- image creation time in seconds since the epoch, 0 if unknown.
image_epoch() {
    podman image inspect --format '{{.Created.Unix}}' "$1" 2>/dev/null || echo 0
}

# newest_epoch <file>... -- most recent mtime among the files that exist, 0 if none.
newest_epoch() {
    local newest=0 mtime file gnu_stat=0
    stat --version 2>/dev/null | grep -q "GNU" && gnu_stat=1
    for file in "$@"; do
        [ -f "${file}" ] || continue
        if [ "${gnu_stat}" = 1 ]; then
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

# build -- unconditional build of the image.
build() {
    require_podman
    local cf
    cf="$(resolved_containerfile)"

    info "Building image '${IMAGE}'..."
    podman build -t "${IMAGE}" -f "${cf}" --label "run=$(run_label)" "${ROOT_DIR}"
}

# ensure_image -- rebuilds when the image is missing or older than its
# inputs. Every mount and security flag lives in the image's `LABEL run`, so
# an out-of-date image would otherwise keep silently applying the previous
# limits; that label comes from run_label() in this very script, so
# paddock.sh's own mtime (SELF) is an input too, alongside the Containerfile
# and entrypoint.sh.
ensure_image() {
    require_podman
    local cf reason=""
    cf="$(resolved_containerfile)"

    if ! podman image exists "${IMAGE}"; then
        reason="is missing"
    else
        local built inputs
        built="$(image_epoch "${IMAGE}")"
        inputs="$(newest_epoch "${cf}" "${ROOT_DIR}/profile/entrypoint.sh" "${SELF}")"
        if [ "${inputs}" -gt "${built}" ]; then
            reason="is older than its Containerfile or paddock.sh"
        fi
    fi

    if [ -n "${reason}" ]; then
        info "Image '${IMAGE}' ${reason}; rebuilding..."
        build
    fi
}

run() {
    # Build if the image is missing or its inputs have changed since it was built
    ensure_image

    # $PWD is mounted with a recursive SELinux relabel (:z) -- refuse anywhere too broad.
    local cwd; cwd="$(pwd)"
    case "${cwd}" in
        "/" | "${HOME}")
            error "Refusing to run from '${cwd}': mounting it recursively SELinux-relabels your entire home or root filesystem. cd into a project directory first." ;;
    esac
    case "${DATA_HOME}" in
        "${cwd}"/*)
            error "Refusing to run from '${cwd}': it contains paddock's own state (${DATA_HOME}). cd into a project directory first." ;;
    esac

    # The image's `LABEL run` owns every mount and security flag; this script
    # deliberately keeps no second copy of them. It only pre-creates the host
    # home directory so it is owned by the invoking user rather than by podman.
    local home_host="${DATA_HOME}/home"
    mkdir -p "${home_host}"

    # Listed in mount order: the home volume lands on /home/ai first, then the
    # workspace is mounted at /home/ai/sandbox inside it.
    info "Launching sandbox via 'podman container runlabel'..."
    info "Home directory: ${home_host} -> /home/ai"
    info "Workspace: $(pwd) -> /home/ai/sandbox"

    podman container runlabel run "${IMAGE}"
}

# upgrade_assistants
# Sniffs latest stable release versions from the NPM registry,
# converts their SHA-512 Base64 hashes into Hex format, and updates
# profile/Containerfile if newer versions are available.
upgrade_assistants() {
    local cf
    cf="$(resolved_containerfile)"

    # Verify required host tools
    command -v curl >/dev/null 2>&1 || error "curl is required on the host for upgrades."
    command -v jq >/dev/null 2>&1 || error "jq is required on the host for upgrades."
    command -v openssl >/dev/null 2>&1 || error "openssl is required on the host for upgrades."

    # Parse current values from Containerfile
    local curr_gemini_ver
    curr_gemini_ver="$(grep "ARG GEMINI_CLI_VER=" "${cf}" | cut -d= -f2)" || \
        error "No 'ARG GEMINI_CLI_VER=' line found in ${cf}"

    info "Checking for upgrades..."
    info "Current @google/gemini-cli: ${curr_gemini_ver}"

    # Query latest stable version and metadata
    local gemini_json; gemini_json="$(curl -fsSL https://registry.npmjs.org/@google/gemini-cli/latest)"
    local latest_gemini_ver; latest_gemini_ver="$(echo "${gemini_json}" | jq -r .version)"
    # Reject a malformed version before it reaches sed and corrupts the Containerfile.
    [[ "${latest_gemini_ver}" =~ ^[0-9]+(\.[0-9]+)+([-.][0-9A-Za-z.]+)?$ ]] || \
        error "Unexpected version string from registry: '${latest_gemini_ver}'"

    local newest
    newest="$(printf '%s\n%s\n' "${curr_gemini_ver}" "${latest_gemini_ver}" | sort -V | tail -n1)"

    if [ "${latest_gemini_ver}" = "${curr_gemini_ver}" ]; then
        info "@google/gemini-cli is already up to date!"
    elif [ "${newest}" != "${latest_gemini_ver}" ]; then
        info "Registry version (${latest_gemini_ver}) is older than the pinned version (${curr_gemini_ver}); not downgrading."
    else
        info "New @google/gemini-cli version found: ${latest_gemini_ver}"
        local gemini_integrity; gemini_integrity="$(echo "${gemini_json}" | jq -r .dist.integrity)"
        [[ "${gemini_integrity}" == sha512-* ]] || \
            error "Registry integrity hash is not sha512-prefixed: '${gemini_integrity}'"
        local gemini_b64="${gemini_integrity#sha512-}"
        local new_gemini_hash; new_gemini_hash="$(echo -n "${gemini_b64}" | openssl enc -base64 -d -A | od -An -tx1 | tr -d ' \n')"
        [[ "${new_gemini_hash}" =~ ^[0-9a-f]{128}$ ]] || \
            error "Decoded hash is not a 128-char sha512 digest: '${new_gemini_hash}'"

        info "Updating ${cf}..."
        sed \
          -e "s/ARG GEMINI_CLI_VER=.*/ARG GEMINI_CLI_VER=${latest_gemini_ver}/" \
          -e "s/ARG GEMINI_CLI_HASH=.*/ARG GEMINI_CLI_HASH=${new_gemini_hash}/" \
          "${cf}" > "${cf}.tmp" && mv "${cf}.tmp" "${cf}"

        info "Successfully upgraded @google/gemini-cli in Containerfile!"
        info "To apply these changes, rebuild your image using:"
        info "  ./paddock.sh rebuild"
    fi
}

# Main routing
usage() {
    echo "Usage: $0 {build|rebuild|run|upgrade}"
    echo "Examples:"
    echo "  $0 build            # Build the image if it is missing or out of date"
    echo "  $0 rebuild          # Force a rebuild, ignoring the staleness check"
    echo "  $0 run              # Build if needed, then launch the sandbox"
    echo "  $0 upgrade          # Fetch latest assistants and update hashes"
    echo
    echo "The image can be personally overridden via a Containerfile at"
    echo "\$HOME/.local/share/paddock/Containerfile, which takes precedence over"
    echo "the shipped profile/Containerfile."
    echo
    echo "Resource limits are set at build time via PADDOCK_RAM_MIB, PADDOCK_CPUS,"
    echo "PADDOCK_PIDS_LIMIT and PADDOCK_TMP_SIZE (defaults: 8192, 4, 1024, 2048m)."
    echo "XDG_DATA_HOME, if set, is baked in as the sandbox home's location instead"
    echo "of the portable default \$HOME/.local/share/paddock."
}

ACTION="$1"

if [ "${ACTION}" = "help" ] || [ "${ACTION}" = "--help" ] || [ "${ACTION}" = "-h" ]; then
    usage
    exit 0
fi

if [ -z "${ACTION}" ]; then
    usage
    exit 1
fi

case "${ACTION}" in
    build)
        ensure_image
        ;;
    rebuild)
        build
        ;;
    run)
        run
        ;;
    upgrade)
        upgrade_assistants
        ;;
    *)
        error "Unknown action '${ACTION}'. Use 'build', 'rebuild', 'run' or 'upgrade'."
        ;;
esac
