#!/bin/bash
set -euo pipefail

# The actual `docker run` invocation. Image reference passes through verbatim -- zero
# version-resolution logic, Docker's own default (:latest when no tag) applies. No failure
# wrapping: the pipe's real exit code is this step's exit code, and its stderr reaches the
# console untouched. The only thing that can delay propagating that exit code is the optional
# fix-permissions cleanup below, which re-raises it unchanged once it's done.

is_true() {
    case "${1:-}" in
        1 | true | TRUE | True) return 0 ;;
        *) return 1 ;;
    esac
}

WORKDIR="$(pwd)"

# --- Ensure the bind-mount targets exist as the right kind of filesystem entry before Docker
#     ever sees them. If a bind-mount source path does not exist on the host, Docker silently
#     creates it as a *directory* -- which would turn the pipe's output file into a directory
#     and break the read-back in `collect-outputs`. `create-output-file` already does this when
#     it runs; this is defensive for `run` being composed on its own. ---
if [[ ! -e "${ORB_VAL_OUTPUT_FILE}" ]]; then
    mkdir -p "$(dirname "${ORB_VAL_OUTPUT_FILE}")"
    : > "${ORB_VAL_OUTPUT_FILE}"
fi
mkdir -p "${ORB_VAL_PIPE_STORAGE_DIR}" "${ORB_VAL_PIPE_SHARED_STORAGE_DIR}"

DOCKER_ARGS=(run --rm)
DOCKER_ARGS+=(-v "${WORKDIR}:${ORB_VAL_CLONE_DIR}")
DOCKER_ARGS+=(-w "${ORB_VAL_CLONE_DIR}")

# Scratch mounts are kept host-path == container-path, so the same value works on both sides of
# the mount (and inside the CIRCLE-side env vars we set below). Dedupe in case a caller pointed
# more than one of these parameters at the same directory. A plain array + linear scan (rather
# than an associative array) keeps this portable to bash 3.2, not just the bash 4+ that ships on
# the machine executor's own Linux images.
SEEN_MOUNTS=()
add_symmetric_mount() {
    local path="$1" seen
    for seen in "${SEEN_MOUNTS[@]-}"; do
        if [[ "${seen}" == "${path}" ]]; then
            return 0
        fi
    done
    DOCKER_ARGS+=(-v "${path}:${path}")
    SEEN_MOUNTS+=("${path}")
}
add_symmetric_mount "$(dirname "${ORB_VAL_OUTPUT_FILE}")"
add_symmetric_mount "${ORB_VAL_PIPE_STORAGE_DIR}"
add_symmetric_mount "${ORB_VAL_PIPE_SHARED_STORAGE_DIR}"

# Pass through the BITBUCKET_* identity/context variables `map-env` exported into $BASH_ENV
# (already sourced into this step's shell by the time this script runs). A bare `docker run -e
# NAME` (no `=value`) takes the value from the *calling* shell's environment -- if `map-env` was
# skipped or a variable legitimately has no value for this build (e.g. BITBUCKET_TAG off a
# branch build), it is simply omitted from the container, matching Bitbucket's own
# "not set on this kind of build" behavior rather than setting it empty.
BITBUCKET_CONTEXT_VARS=(
    BITBUCKET_WORKSPACE BITBUCKET_REPO_OWNER BITBUCKET_REPO_SLUG BITBUCKET_REPO_FULL_NAME
    BITBUCKET_COMMIT BITBUCKET_BUILD_NUMBER BITBUCKET_BRANCH BITBUCKET_TAG BITBUCKET_PR_ID
    BITBUCKET_GIT_HTTP_ORIGIN BITBUCKET_GIT_SSH_ORIGIN BITBUCKET_PIPELINE_UUID BITBUCKET_STEP_UUID
    BITBUCKET_WORKSPACE_UUID BITBUCKET_REPO_UUID BITBUCKET_PROJECT_UUID BITBUCKET_PROJECT_KEY
    BITBUCKET_STEP_TRIGGERER_UUID
)
for var_name in "${BITBUCKET_CONTEXT_VARS[@]}"; do
    if [[ -n "${!var_name:-}" ]]; then
        DOCKER_ARGS+=(-e "${var_name}")
    fi
done

# Names `run` owns because it just bind-mounted the paths they point at -- a `variables:` line
# naming one of these is silently ignored (warn-and-skip, same style as a malformed line) rather
# than allowed to reach `docker run`, since Docker's own last-`-e`-wins behavior would otherwise
# let it desync the container's belief about these paths from the actual bind-mount target (see
# the README's "Bitbucket variables are literal" section for the documented tradeoff). This costs
# nothing against the real contract: none of these four is a pipe-author-facing input variable on
# real Bitbucket -- they're platform-set constants a pipe *reads*, never a `variables:` key a
# pipeline author sets, so no real pipe example collides with this.
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

# Parses a Bitbucket-style bracket-delimited list value (e.g. "['CAPABILITY_IAM',
# 'CAPABILITY_AUTO_EXPAND']" or "[a, b]") -- the exact syntax a Bitbucket pipeline author already
# writes for an array-typed `variables:` entry -- into the ARRAY_ITEMS global array. This lets
# `run-pipe` do the _COUNT/_0/_1/... flattening real Bitbucket's own scheduler does invisibly,
# instead of pushing that pipe-*author*-facing convention (documented for people writing a pipe's
# entrypoint, not people using one) onto the CircleCI config author. Limitation, documented in
# the README: a comma inside a quoted item is not supported -- it is still treated as an item
# separator, since this is a plain split, not a full YAML/JSON parser.
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

# --- The pipe's own `variables:` -- literal Bitbucket names, no prefix, no case change. A value
#     can either be plain (KEY=value), one leg of Bitbucket's own flat _COUNT/_0/_1/... array
#     convention typed out by hand, or -- for convenience -- a bracket list (KEY=['a', 'b']),
#     which this script flattens into _COUNT/_0/_1/... itself. Either array spelling produces the
#     identical container-side result. ---
if [[ -n "${ORB_VAL_VARIABLES}" ]]; then
    if ! command -v circleci > /dev/null 2>&1; then
        echo "Error: the 'circleci' CLI is required to safely substitute \$VAR references in the 'variables' parameter (via 'circleci env subst') but was not found on PATH. CircleCI's machine executor images ship it preinstalled; if you're on a custom image, install the CircleCI CLI first." >&2
        exit 1
    fi
    # https://circleci.com/changelog/new-cli-command-env-subst -- the documented safe
    # alternative to eval for resolving $VAR/${VAR} references in a parameter's value against
    # the job's real environment, so users can write $MY_SECRET in `variables` without the
    # secret's value ever entering the orb's config or being re-interpreted by a shell.
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
            echo "Warning: skipping 'variables' line naming the orb-managed variable '${KEY}'; this orb always sets it itself to match the workspace/output-file paths it just bind-mounted. No real Bitbucket pipe declares this as an input variable. See the README." >&2
            continue
        fi
        if [[ "${VALUE}" == \[*\] ]]; then
            parse_bracket_list "${VALUE}"
            DOCKER_ARGS+=(-e "${KEY}_COUNT=${#ARRAY_ITEMS[@]}")
            for i in "${!ARRAY_ITEMS[@]}"; do
                DOCKER_ARGS+=(-e "${KEY}_${i}=${ARRAY_ITEMS[${i}]}")
            done
        else
            DOCKER_ARGS+=(-e "${line}")
        fi
    done <<< "${SUBST_VARIABLES}"
fi

# These four are always set explicitly (rather than relying on passthrough), and deliberately
# *after* the `variables:` loop above so they always win Docker's last-`-e`-wins semantics for a
# duplicate key (verified: `docker run --rm -e FOO=first -e FOO=second busybox sh -c 'echo $FOO'`
# prints "second") -- `run` owns the paths it just bind-mounted and must guarantee the container
# sees the matching values even if `map-env` was skipped or a `variables:` line collides. The
# denylist above already rejects a colliding `variables:` line outright; this ordering is the
# structural backstop for the same guarantee.
DOCKER_ARGS+=(-e "BITBUCKET_CLONE_DIR=${ORB_VAL_CLONE_DIR}")
DOCKER_ARGS+=(-e "BITBUCKET_PIPELINES_VARIABLES_PATH=${ORB_VAL_OUTPUT_FILE}")
DOCKER_ARGS+=(-e "BITBUCKET_PIPE_STORAGE_DIR=${ORB_VAL_PIPE_STORAGE_DIR}")
DOCKER_ARGS+=(-e "BITBUCKET_PIPE_SHARED_STORAGE_DIR=${ORB_VAL_PIPE_SHARED_STORAGE_DIR}")

# --- Optional registry auth for private images. registry-username/registry-password are
#     env_var_name parameters: their *value* is the NAME of an env var already present in the
#     job (project/context env var), never the secret itself -- resolved here via bash indirect
#     expansion so the actual credential never appears in orb config or this step's
#     `environment:` block. Both parameters always have some (non-empty, valid-identifier)
#     value -- CircleCI's env_var_name type rejects an empty default -- so whether login
#     actually happens hinges entirely on whether the *named* env vars resolve to anything. ---
REGISTRY_USERNAME_VALUE="${!ORB_VAL_REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD_VALUE="${!ORB_VAL_REGISTRY_PASSWORD:-}"
if [[ -n "${REGISTRY_USERNAME_VALUE}" && -n "${REGISTRY_PASSWORD_VALUE}" ]]; then
    echo "Logging in to ${ORB_VAL_REGISTRY_SERVER:-Docker Hub} as ${REGISTRY_USERNAME_VALUE}..."
    if [[ -n "${ORB_VAL_REGISTRY_SERVER:-}" ]]; then
        printf '%s' "${REGISTRY_PASSWORD_VALUE}" | docker login "${ORB_VAL_REGISTRY_SERVER}" --username "${REGISTRY_USERNAME_VALUE}" --password-stdin
    else
        printf '%s' "${REGISTRY_PASSWORD_VALUE}" | docker login --username "${REGISTRY_USERNAME_VALUE}" --password-stdin
    fi
else
    echo "registry-username/registry-password name env vars (${ORB_VAL_REGISTRY_USERNAME}/${ORB_VAL_REGISTRY_PASSWORD}) with no value set; skipping registry login."
fi

# --- Optional --user. Left empty by default: pipe containers run as root by default (matching
#     Bitbucket's own real-world behavior -- Bitbucket Pipelines containers are root too, this
#     is not a CircleCI-specific problem), and forcing non-root is not verified-safe across the
#     pipe catalog (pipes that apt-get/apk install or write to /root at container start would
#     break). Opt in explicitly if you know a given pipe tolerates it. ---
if [[ -n "${ORB_VAL_USER}" ]]; then
    DOCKER_ARGS+=(--user "${ORB_VAL_USER}")
fi

# --- Free-form escape hatch for anything not covered above (--network, --cap-add, extra -v
#     mounts, --entrypoint overrides, ...). Simple whitespace-split, no quoting support for
#     values containing spaces -- documented in the parameter description and README. ---
if [[ -n "${ORB_VAL_EXTRA_DOCKER_ARGS}" ]]; then
    read -ra EXTRA_DOCKER_ARGS_ARRAY <<< "${ORB_VAL_EXTRA_DOCKER_ARGS}"
    DOCKER_ARGS+=("${EXTRA_DOCKER_ARGS_ARRAY[@]}")
fi

DOCKER_ARGS+=("${ORB_VAL_IMAGE}")

echo "Running: docker ${DOCKER_ARGS[*]}"
set +e
docker "${DOCKER_ARGS[@]}"
PIPE_EXIT_CODE=$?
set -e

if is_true "${ORB_VAL_FIX_PERMISSIONS:-}"; then
    echo "fix-permissions: reclaiming ownership of ${WORKDIR} (pipe containers run as root by default, which leaves root-owned files behind on a real Linux machine executor -- this does not reproduce under Docker Desktop's macOS bind-mount UID remapping, only on real Linux)."
    if command -v sudo > /dev/null 2>&1; then
        sudo chown -R "$(id -u):$(id -g)" "${WORKDIR}" || echo "Warning: fix-permissions chown failed; continuing." >&2
    else
        chown -R "$(id -u):$(id -g)" "${WORKDIR}" || echo "Warning: fix-permissions chown failed (no sudo available and non-root chown cannot reclaim root-owned files); continuing." >&2
    fi
fi

# Re-raise the pipe's real exit code last, after cleanup -- never masked, never retried.
exit "${PIPE_EXIT_CODE}"
