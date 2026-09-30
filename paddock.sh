#!/bin/bash
set -eo pipefail

unset CDPATH

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Paddock's own persistent, machine-local state: the sandbox home and a
# personal Containerfile override.
DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/paddock"

IMAGE="paddock:latest"

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

require_podman() {
    command -v podman >/dev/null 2>&1 || error "Podman is required but not installed."
}

resolved_containerfile() {
    local cf="${DATA_HOME}/Containerfile"
    [ -f "${cf}" ] || cf="${ROOT_DIR}/profile/Containerfile"
    [ -f "${cf}" ] || error "Containerfile not found at ${cf}"
    echo "${cf}"
}

# An array, not stdout, so paths with newlines cannot split argv tokens; callers must
# re-invoke per use since run_label() leaves placeholder mount paths behind.
sandbox_flags() {
    local ram="${PADDOCK_RAM_MIB:-8192}"
    local cpus="${PADDOCK_CPUS:-4}"
    local pids="${PADDOCK_PIDS_LIMIT:-1024}"
    local tmp_size="${PADDOCK_TMP_SIZE:-2048m}"
    # Unvalidated values here get shlex-split into podman's argv via --label.
    [[ "${ram}" =~ ^[0-9]+$ ]] || error "PADDOCK_RAM_MIB must be a positive integer (MiB): '${ram}'"
    [[ "${cpus}" =~ ^[0-9]+$ ]] || error "PADDOCK_CPUS must be a positive integer: '${cpus}'"
    [[ "${pids}" =~ ^[0-9]+$ ]] || error "PADDOCK_PIDS_LIMIT must be a positive integer: '${pids}'"
    [[ "${tmp_size}" =~ ^[0-9]+[kKmMgG]?$ ]] || error "PADDOCK_TMP_SIZE must be an integer optionally suffixed with k/m/g: '${tmp_size}'"

    SANDBOX_FLAGS=(
        podman run --rm --interactive --tty
        --runtime krun
        --network pasta
        --annotation krun.use_passt=1
        --annotation "krun.ram_mib=${ram}"
        --annotation "krun.cpus=${cpus}"
        --cap-drop ALL
        --security-opt no-new-privileges
        --read-only
        --tmpfs "/tmp:rw,noexec,nosuid,nodev,size=${tmp_size}"
        --pids-limit "${pids}"
        --hostname paddock-latest
        --user ai
        --userns "keep-id:uid=1000,gid=1000"
        --volume "$1:/home/ai:z"
        --volume "$2:/home/ai/sandbox:z"
        --workdir "$3"
        "${IMAGE}"
    )
}

run_label() {
    # Escaped as $${} so Dockerfile variable substitution preserves literal $HOME/$PWD tokens.
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

    sandbox_flags "${home_volume}" "${pwd_volume}" "/home/ai/sandbox"
    echo "${SANDBOX_FLAGS[*]}"
}

# build -- unconditional build of the image.
build() {
    require_podman
    local cf
    cf="$(resolved_containerfile)"

    info "Building image '${IMAGE}'..."
    podman build -t "${IMAGE}" -f "${cf}" --label "run=$(run_label)" "${ROOT_DIR}"
}

# Builds when image is missing or when resource limits in the baked run label changed.
ensure_image() {
    require_podman
    # Fail early if the Containerfile is missing even when the image already exists.
    resolved_containerfile > /dev/null

    if ! podman image exists "${IMAGE}"; then
        info "Image '${IMAGE}' is missing; building..."
        build
        return
    fi

    local baked current
    baked="$(podman image inspect --format '{{index .Config.Labels "run"}}' "${IMAGE}" 2>/dev/null || echo "")"
    current="$(run_label)"
    current="${current//\$\${\}/\$}"
    if [ "${baked}" != "${current}" ]; then
        info "Image '${IMAGE}' run label is out of date; rebuilding..."
        build
    fi
}

run() {
    local folder=""
    local OPTIND=1 opt OPTARG
    while getopts ":hw:" opt; do
        case "${opt}" in
            h)
                usage
                exit 0
                ;;
            w)
                folder="${OPTARG}"
                ;;
            :)
                error "Option '-${OPTARG}' requires an argument."
                ;;
            \?)
                error "Unknown option '-${OPTARG}' for 'run' (use '--' before commands starting with a hyphen)."
                ;;
        esac
    done
    shift $((OPTIND - 1))

    # $PWD is mounted with a recursive SELinux relabel (:z) -- refuse anywhere too broad.
    local cwd; cwd="$(pwd -P)"
    local real_home; real_home="$(realpath -m -- "${HOME}")"
    local real_data_home; real_data_home="$(realpath -m -- "${DATA_HOME}")"
    case "${cwd}" in
        "/" | "${real_home}")
            error "Refusing to run from '${cwd}': mounting it recursively SELinux-relabels your entire home or root filesystem. cd into a project directory first." ;;
    esac
    case "${real_data_home}" in
        "${cwd}"/*)
            error "Refusing to run from '${cwd}': it contains paddock's own state (${DATA_HOME}). cd into a project directory first." ;;
    esac

    if [ -n "${folder}" ]; then
        [ -d "${folder}" ] || error "Directory '${folder}' is not an accessible directory in ${cwd}."
        folder="$(realpath --relative-to="${cwd}" -- "${folder}")"
        case "${folder}" in
            .) folder="" ;;
            .. | ../*) error "Directory '${folder}' is outside the workspace (${cwd})." ;;
        esac
    fi

    ensure_image

    # Pre-created so it's owned by the invoking user, not by podman.
    local home_host="${DATA_HOME}/home"
    mkdir -p "${home_host}"

    # Listed in mount order: the home volume lands on /home/ai first, then the
    # workspace is mounted at /home/ai/sandbox inside it.
    info "Launching sandbox..."
    info "Home directory: ${home_host} -> /home/ai"
    info "Workspace: ${cwd} -> /home/ai/sandbox"

    if [ -z "${folder}" ] && [ $# -eq 0 ]; then
        podman container runlabel run "${IMAGE}"
    else
        sandbox_flags "${home_host}" "${cwd}" "/home/ai/sandbox${folder:+/${folder}}"
        "${SANDBOX_FLAGS[@]}" "$@"
    fi
}

# Main routing
usage() {
    echo "Usage: $0 {build|run [-w folder] [--] [command...]}"
    echo "Examples:"
    echo "  $0 build                        # Build (or rebuild) the image"
    echo "  $0 run                          # Build if needed, then launch the sandbox"
    echo "  $0 run -w myproject             # Launch inside a workspace subdirectory"
    echo "  $0 run opencode -c              # Run a command directly instead of an interactive shell"
    echo "  $0 run -w myproject opencode -c # Run a command inside a workspace subdirectory"
    echo "  $0 run -- ls -l                 # Pass commands starting with a hyphen"
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
        build
        ;;
    run)
        shift
        run "$@"
        ;;
    *)
        error "Unknown action '${ACTION}'. Use 'build' or 'run'."
        ;;
esac
