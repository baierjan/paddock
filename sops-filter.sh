#!/bin/bash
# Git filter (clean/smudge/diff) and hook helper (check/refresh) that keep files sops-encrypted in the repo.
set -eo pipefail

op="${1:-}"
f="${2:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Rules come from the last commit, so edits in the guest-writable home apply only once committed.
git cat-file blob HEAD:.sops.yaml > "${tmp}/rules" 2>/dev/null || : > "${tmp}/rules"
sops() { command sops --config "${tmp}/rules" "$@"; }

encrypted='mac[^A-Za-z]*ENC\[AES256_GCM'

# $1: optional check-attr flag (--cached to read the index).
sops_paths() {
    xargs -0r git check-attr -z "$@" filter -- \
        | while IFS= read -r -d '' path && IFS= read -r -d '' _ && IFS= read -r -d '' value; do
            [ "${value}" != sops ] || printf '%s\0' "${path}"
        done
}

case "${op}" in
    smudge)
        sops decrypt --filename-override "${f}"
        ;;
    diff)
        # shortcut: JSON only (textconv gets a nameless temp file), widen when tracking other formats.
        sops decrypt --input-type json --output-type json "${f}" 2>/dev/null || cat "${f}"
        ;;
    clean)
        [ -s "${tmp}/rules" ] || { echo "Commit .sops.yaml before adding ${f}." >&2; exit 1; }
        cat > "${tmp}/plain"
        sops encrypt --filename-override "${f}" < "${tmp}/plain" > "${tmp}/new"
        # sops output is non-deterministic: reuse the staged ciphertext if the content is unchanged.
        if git cat-file blob ":${f}" > "${tmp}/old" 2>/dev/null \
            && sops decrypt --filename-override "${f}" < "${tmp}/old" > "${tmp}/old.plain" 2>/dev/null \
            && sops decrypt --filename-override "${f}" < "${tmp}/new" 2>/dev/null | cmp -s - "${tmp}/old.plain"; then
            cat "${tmp}/old"
        else
            cat "${tmp}/new"
        fi
        ;;
    check)
        # Attributes come from HEAD, so a secret committed together with its new rule skips the filter.
        git diff --cached --no-renames --name-only -z --diff-filter=AM | sops_paths --cached \
            | while IFS= read -r -d '' path; do
                if ! git cat-file blob ":${path}" | grep -q "${encrypted}"; then
                    echo "${path} is staged unencrypted. Make sure .sops.yaml and .gitattributes are committed, then 'git add ${path}' again." >&2
                    exit 1
                fi
            done
        ;;
    refresh)
        # A pull uses the old HEAD's rules, so a file whose rule just arrived is still ciphertext.
        git ls-files -z | sops_paths \
            | while IFS= read -r -d '' path; do
                if grep -q "${encrypted}" "${path}" 2>/dev/null; then
                    rm -f -- "${path}"
                    git checkout -- "${path}"
                fi
            done
        ;;
    *)
        echo "Usage: $0 {clean|smudge|diff} FILE | check | refresh" >&2
        exit 2
        ;;
esac
