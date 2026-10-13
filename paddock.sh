#!/bin/bash
set -eo pipefail

unset CDPATH

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Paddock's own persistent, machine-local state: the sandbox home and a
# personal Containerfile override.
DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/paddock"

IMAGE="paddock:latest"

HOME_DIR="${DATA_HOME}/home"
# Bare repo versioning the sandbox home; outside the home so the guest cannot reach it.
HOME_GIT="${DATA_HOME}/home.git"

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
# Args from $4 on (publish flags) are per-invocation, so run_label() passes none.
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
        "${@:4}"
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

# build -- unconditional build of the image; args are forwarded to `podman build`.
build() {
    require_podman
    local cf
    cf="$(resolved_containerfile)"

    info "Building image '${IMAGE}'..."
    podman build -t "${IMAGE}" -f "${cf}" --label "run=$(run_label)" "$@" "${ROOT_DIR}"
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

require_git() {
    command -v git >/dev/null 2>&1 || error "Git is required but not installed."
}

# In the repo config so plain git behaves like `paddock.sh git`; attributes come from HEAD, not the home.
configure_home_git() {
    local config=(git --git-dir="${HOME_GIT}" config)
    # shortcut: a single quote in the install path breaks these commands, escape it if that matters.
    local f="'${ROOT_DIR}/sops-filter.sh'"
    "${config[@]}" status.showUntrackedFiles no
    "${config[@]}" attr.tree HEAD
    "${config[@]}" filter.sops.required true
    "${config[@]}" filter.sops.clean "${f} clean %f"
    "${config[@]}" filter.sops.smudge "${f} smudge %f"
    "${config[@]}" diff.sops.textconv "${f} diff"
    "${config[@]}" hook.paddock-sops-check.event pre-commit
    "${config[@]}" hook.paddock-sops-check.command "${f} check"
    "${config[@]}" hook.paddock-sops-merge.event post-merge
    "${config[@]}" hook.paddock-sops-merge.command "${f} refresh"
    "${config[@]}" hook.paddock-sops-checkout.event post-checkout
    "${config[@]}" hook.paddock-sops-checkout.command "${f} refresh"
}

# No side effects: `init` does all setup.
home_git() {
    require_git
    [ -d "${HOME_GIT}" ] || error "No home repository at ${HOME_GIT}; run '$0 init [URL]' first."
    [ -d "${HOME_DIR}" ] || error "${HOME_DIR} is missing; run '$0 init' to create it."
    (cd "${HOME_DIR}" && git --git-dir="${HOME_GIT}" --work-tree="${HOME_DIR}" "$@")
}

# init [URL]: create or clone the home repo and home dir; rerun after moving the checkout to refresh the config.
init() {
    require_git
    local url="${1:-}" branch
    local git=(git --git-dir="${HOME_GIT}")
    if [ -d "${HOME_GIT}" ]; then
        [ -z "${url}" ] || error "${HOME_GIT} already exists; remove it to clone '${url}'."
    else
        mkdir -p "${DATA_HOME}"
        if [ -n "${url}" ]; then
            git clone --bare -- "${url}" "${HOME_GIT}"
            "${git[@]}" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
            # A bare clone sets no upstream, which plain push and pull need.
            branch="$("${git[@]}" symbolic-ref --short HEAD)"
            "${git[@]}" config "branch.${branch}.remote" origin
            "${git[@]}" config "branch.${branch}.merge" "refs/heads/${branch}"
            # A bare clone has an empty index, so the first commit would delete every file.
            ! "${git[@]}" rev-parse --quiet --verify HEAD >/dev/null || "${git[@]}" read-tree HEAD
        else
            git init --bare -- "${HOME_GIT}"
        fi
    fi
    configure_home_git
    mkdir -p "${HOME_DIR}"
    info "Home repository: ${HOME_GIT} (work tree ${HOME_DIR})"
    info "Restore the tracked files into the home with '$0 git checkout -f'."
}

run() {
    local folder=""
    local publish=()
    local OPTIND=1 opt OPTARG
    while getopts ":hpP:w:" opt; do
        case "${opt}" in
            h)
                usage
                exit 0
                ;;
            p)
                publish+=(--publish 127.0.0.1:4096:4096)
                ;;
            P)
                publish+=(--publish "${OPTARG}")
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
    local home_host="${HOME_DIR}"
    mkdir -p "${home_host}"

    # Listed in mount order: the home volume lands on /home/ai first, then the
    # workspace is mounted at /home/ai/sandbox inside it.
    info "Launching sandbox..."
    info "Home directory: ${home_host} -> /home/ai"
    info "Workspace: ${cwd} -> /home/ai/sandbox"

    if [ -z "${folder}" ] && [ $# -eq 0 ] && [ ${#publish[@]} -eq 0 ]; then
        podman container runlabel run "${IMAGE}"
    else
        sandbox_flags "${home_host}" "${cwd}" "/home/ai/sandbox${folder:+/${folder}}" "${publish[@]}"
        "${SANDBOX_FLAGS[@]}" "$@"
    fi
}

# Main routing
usage() {
    echo "Usage: $0 {build [podman build args...]|run [-p] [-P publish]... [-w folder] [--] [command...]|init [URL]|git [git args...]}"
    echo "Examples:"
    echo "  $0 build                        # Build (or rebuild) the image"
    echo "  $0 build --no-cache             # Rebuild from scratch; extra args go to 'podman build'"
    echo "  $0 run                          # Build if needed, then launch the sandbox"
    echo "  $0 run -w myproject             # Launch inside a workspace subdirectory"
    echo "  $0 run opencode -c              # Run a command directly instead of an interactive shell"
    echo "  $0 run -w myproject opencode -c # Run a command inside a workspace subdirectory"
    echo "  $0 run -p                       # Publish 127.0.0.1:4096 to the sandbox shell"
    echo "  $0 run -P 127.0.0.1:18080:8080 python3 -m http.server 8080 --bind 0.0.0.0"
    echo "  $0 run -- ls -l                 # Pass commands starting with a hyphen"
    echo "  $0 init                         # Create the home repository (see docs/setup.md)"
    echo "  $0 init git@host:me/home.git    # Clone an existing home repository"
    echo "  $0 git checkout -f              # Restore the tracked files into the home"
    echo "  $0 git add .bashrc              # Run git on the home repository"
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
        shift
        build "$@"
        ;;
    run)
        shift
        run "$@"
        ;;
    init)
        shift
        init "$@"
        ;;
    git)
        shift
        home_git "$@"
        ;;
    *)
        error "Unknown action '${ACTION}'. Use 'build', 'run', 'init' or 'git'."
        ;;
esac
