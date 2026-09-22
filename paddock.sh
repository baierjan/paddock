#!/bin/bash
set -eo pipefail

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

# resolved_containerfile -- the Containerfile paddock builds, rejecting a
# missing file; see AGENTS.md, "The Containerfile is personally overridable".
resolved_containerfile() {
    local cf="${DATA_HOME}/Containerfile"
    [ -f "${cf}" ] || cf="${ROOT_DIR}/profile/Containerfile"
    [ -f "${cf}" ] || error "Containerfile not found at ${cf}"
    echo "${cf}"
}

# run_label -- the `podman run ...` string baked into the image via
# `podman build --label run=...`; see AGENTS.md, "The run label lives in
# paddock.sh", for why it isn't a static Containerfile LABEL.
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
    # $HOME/$PWD must stay spelled `$${}HOME`/`$${}PWD`, not plain or
    # `\$`-escaped; see AGENTS.md, "The run label lives in paddock.sh", for why.
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

# build -- unconditional build of the image.
build() {
    require_podman
    local cf
    cf="$(resolved_containerfile)"

    info "Building image '${IMAGE}'..."
    podman build -t "${IMAGE}" -f "${cf}" --label "run=$(run_label)" "${ROOT_DIR}"
}

# ensure_image -- builds when the image is missing, or when its baked-in
# `run` label no longer matches run_label(); see AGENTS.md, "The run label
# lives in paddock.sh", for why this doesn't use the image's `Created` time,
# and why a plain Containerfile/entrypoint.sh edit needs an explicit `build`.
ensure_image() {
    require_podman
    # Validates even when no rebuild is needed; see AGENTS.md, "The
    # Containerfile is personally overridable".
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

    # Pre-created so it's owned by the invoking user, not by podman.
    local home_host="${DATA_HOME}/home"
    mkdir -p "${home_host}"

    # Listed in mount order: the home volume lands on /home/ai first, then the
    # workspace is mounted at /home/ai/sandbox inside it.
    info "Launching sandbox via 'podman container runlabel'..."
    info "Home directory: ${home_host} -> /home/ai"
    info "Workspace: $(pwd) -> /home/ai/sandbox"

    podman container runlabel run "${IMAGE}"
}

# Main routing
usage() {
    echo "Usage: $0 {build|run}"
    echo "Examples:"
    echo "  $0 build            # Build (or rebuild) the image"
    echo "  $0 run              # Build if needed, then launch the sandbox"
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
        run
        ;;
    *)
        error "Unknown action '${ACTION}'. Use 'build' or 'run'."
        ;;
esac
