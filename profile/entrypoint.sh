#!/bin/bash
set -eo pipefail

# Drop privileges from root (UID 0) to ai (UID 1000) if running inside VM/microVM (e.g. krun)
if [ "$(id -u)" = "0" ] && id ai >/dev/null 2>&1; then
    _uid="$(id -u ai)"
    _gid="$(id -g ai)"
    _home="$(getent passwd ai | cut -d: -f6)"
    export HOME="$_home"
    export USER="ai"
    export LOGNAME="ai"
    export TERM="${TERM:-xterm-256color}"
    exec setpriv --reuid="${_uid}" --regid="${_gid}" --init-groups "$0" "$@"
fi

exec "$@"
