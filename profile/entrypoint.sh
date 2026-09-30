#!/bin/bash
set -eo pipefail

# Drop privileges from root (UID 0) to ai (UID 1000) if running inside VM/microVM (e.g. krun)
if [ "$(id -u)" = "0" ] && id ai >/dev/null 2>&1; then
    _uid="$(id -u ai)"
    _gid="$(id -g ai)"
    _home="/home/ai"
    export HOME="$_home"
    export USER="ai"
    export LOGNAME="ai"
    export TERM="${TERM:-xterm-256color}"
    # The guest's /tmp lacks the --tmpfs noexec,nosuid,nodev flags; reapply them.
    mount -o remount,bind,noexec,nosuid,nodev /tmp
    exec setpriv --reuid="${_uid}" --regid="${_gid}" --init-groups \
        --inh-caps=-all --bounding-set=-all --nnp \
        "$0" "$@"
fi

# Sourcing /etc/profile and dotfiles requires a login shell for both default and custom commands.
# shellcheck disable=SC2016
exec bash --login -c 'exec "$@"' paddock "$@"
