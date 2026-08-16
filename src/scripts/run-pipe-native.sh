#!/bin/bash
set -uo pipefail

# Runs the pipe's REAL entrypoint as an ordinary `run:` step inside the job's own primary
# container (the pipe's own image) -- no `docker run`, no bind mount, no `--user`, no
# fix-permissions chown. This is the mechanism the whole native-primary-container path rests on:
# CircleCI ignores a primary container's own ENTRYPOINT/CMD and runs `steps:` inside the
# already-live container, so exec'ing the pipe's documented entrypoint command directly IS the
# equivalent of "docker run <image>" here -- the image is already running, this just invokes what
# its Dockerfile would otherwise have run automatically.
#
# BITBUCKET_* identity/context vars are already present in this step's shell -- map-env (reused
# COMPLETELY UNMODIFIED from the docker-run path; it already exports into $BASH_ENV, and every
# `run:` step sources $BASH_ENV before its command runs) put them there. This script's own job is
# the piece that DOESN'T drop in unmodified: the real `run-pipe.sh` turns `variables:` into
# `docker run -e KEY=value` flags; there is no `docker run` here, so this exports each one
# directly into ITS OWN shell process instead, right before exec'ing the entrypoint as its child.
# Deliberately NOT written into $BASH_ENV: real Bitbucket's `variables:` only ever reach the
# pipe's own container, never a later native step, and this script preserves that exact scoping
# (see the README's "Bitbucket variables are literal" section) -- `variables:` set here die with
# this step, same as they'd die with the container in the docker-run path.
#
# `entrypoint` is a REQUIRED parameter with no default at the command/job level specifically so
# omitting it is a config-validation error, never a runtime guess: a pipe's real entrypoint is
# vendor-chosen and arbitrary (/pipe.sh, python3 /pipe.py, /usr/bin/pipe) and cannot be discovered
# from inside the container without a Docker daemon to `docker inspect` with -- which a
# docker-executor primary container does not have.

if [ -z "${ORB_VAL_ENTRYPOINT}" ]; then
    echo "Error: entrypoint parameter is required and must not be empty. A pipe's real entrypoint is vendor-chosen (e.g. '/pipe.sh', 'python3 /pipe.py') and cannot be auto-detected from inside a docker-executor primary container (there is no Docker daemon here to 'docker inspect' with). Find it in the pipe's own Dockerfile/documentation (or 'docker run --rm --entrypoint cat <image> /pipe.yml')." >&2
    exit 1
fi

# Names `run-pipe`/`create-output-file` own because they bind-mount/set the paths they point at in
# the docker-run path -- identical denylist to run-pipe.sh's ORB_RESERVED_CONTAINER_VARS, kept for
# parity even though there is no bind mount here: a `variables:` line naming one of these would
# otherwise silently desync this step's belief about the output-file/storage-dir paths from what
# create-output-file actually set up.
ORB_RESERVED_CONTAINER_VARS=(
    BITBUCKET_CLONE_DIR BITBUCKET_PIPELINES_VARIABLES_PATH
    BITBUCKET_PIPE_STORAGE_DIR BITBUCKET_PIPE_SHARED_STORAGE_DIR
)
is_orb_reserved_container_var() {
    local candidate="$1" reserved
    for reserved in "${ORB_RESERVED_CONTAINER_VARS[@]}"; do
        if [[ "${candidate}" == "${reserved}" ]]; then
            return 0
        fi
    done
    return 1
}

# Identical bracket-list parser to run-pipe.sh's parse_bracket_list -- see that script's own
# comment for the exact syntax/limitations (a comma inside a quoted item is still treated as an
# item separator; this is a plain split, not a full YAML/JSON parser).
parse_bracket_list() {
    local raw="$1" inner item trimmed
    inner="${raw#\[}"
    inner="${inner%\]}"
    ARRAY_ITEMS=()
    if [[ -z "${inner//[[:space:]]/}" ]]; then
        return 0
    fi
    local old_ifs="${IFS}"
    IFS=','
    read -ra RAW_ITEMS <<< "${inner}"
    IFS="${old_ifs}"
    for item in "${RAW_ITEMS[@]}"; do
        trimmed="${item#"${item%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        if [[ "${trimmed}" =~ ^\'(.*)\'$ ]]; then
            trimmed="${BASH_REMATCH[1]}"
        elif [[ "${trimmed}" =~ ^\"(.*)\"$ ]]; then
            trimmed="${BASH_REMATCH[1]}"
        fi
        ARRAY_ITEMS+=("${trimmed}")
    done
}

if [[ -n "${ORB_VAL_VARIABLES}" ]]; then
    if ! command -v circleci > /dev/null 2>&1; then
        echo "Error: the 'circleci' CLI is required to safely substitute \$VAR references in the 'variables' parameter (via 'circleci env subst') but was not found on PATH. If this pipe's own image doesn't ship it, install the CircleCI CLI first, or drop the \$VAR reference from 'variables'." >&2
        exit 1
    fi
    SUBST_VARIABLES="$(circleci env subst "${ORB_VAL_VARIABLES}")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        if [[ -z "${line}" || "${line}" == \#* ]]; then
            continue
        fi
        if [[ "${line}" != *=* ]]; then
            echo "Warning: skipping malformed 'variables' line (no '='): ${line}" >&2
            continue
        fi
        KEY="${line%%=*}"
        VALUE="${line#*=}"
        if [[ ! "${KEY}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Warning: skipping 'variables' line with an invalid variable name: ${line}" >&2
            continue
        fi
        if is_orb_reserved_container_var "${KEY}"; then
            echo "Warning: skipping 'variables' line naming the orb-managed variable '${KEY}'; this orb always sets it itself to match the output-file/storage-dir paths create-output-file just set up. No real Bitbucket pipe declares this as an input variable. See the README." >&2
            continue
        fi
        if [[ "${VALUE}" == \[*\] ]]; then
            parse_bracket_list "${VALUE}"
            export "${KEY}_COUNT=${#ARRAY_ITEMS[@]}"
            for i in "${!ARRAY_ITEMS[@]}"; do
                export "${KEY}_${i}=${ARRAY_ITEMS[${i}]}"
            done
        else
            export "${KEY}=${VALUE}"
        fi
    done <<< "${SUBST_VARIABLES}"
fi

echo "Running (native primary-container mode): ${ORB_VAL_ENTRYPOINT}"

# sh -c "<string>", not eval and not a bare word-split exec: this correctly runs both a
# single-binary entrypoint ('/pipe.sh') and a multi-word one ('python3 /pipe.py') exactly the way
# the image's own Dockerfile ENTRYPOINT/CMD would have been interpreted, with ordinary shell
# word-splitting/quoting rules applied once, not twice. Inherits every `export`ed variable set
# above, plus everything already in this step's environment (BITBUCKET_* from map-env,
# BITBUCKET_PIPELINES_VARIABLES_PATH/etc from create-output-file) automatically, since it's a
# plain child process.
sh -c "${ORB_VAL_ENTRYPOINT}"
exit $?
