#!/bin/bash
set -euo pipefail

# Maps CircleCI's build context onto the BITBUCKET_* variables real pipes read (verified against
# Atlassian's "Default variables" docs and cross-checked against real pipe source -- see the
# README's mapping table for the full picture and what is only a best-effort synthesis).
#
# Every value is exported into $BASH_ENV so it is present in the shell environment of the `run`
# command's step (CircleCI sources $BASH_ENV at the start of every `run` step), which is what
# lets `run` pass these through to the pipe's container with a bare `docker run -e VARNAME`
# (Docker fills that in from the *calling* shell's environment; it never touches the value).

export_kv() {
    local key="$1" value="$2"
    local escaped="${value//\'/\'\\\'\'}"
    echo "export ${key}='${escaped}'" >> "$BASH_ENV"
}

# Placeholder UUID for identity fields Bitbucket sets that CircleCI has no equivalent for
# (BITBUCKET_PIPELINE_UUID, BITBUCKET_STEP_UUID, etc). These exist purely so a pipe that merely
# checks *presence* (or uniqueness) of the variable does not crash -- they are not, and cannot
# be, real Bitbucket identifiers. Wrapped in curly braces to match the format Bitbucket's own
# REST API always renders UUIDs in (this specific formatting detail comes from Bitbucket's API
# conventions, not from the pipeline-variables doc, which does not show example values for these).
gen_uuid() {
    local raw=""
    if command -v uuidgen > /dev/null 2>&1; then
        raw="$(uuidgen)"
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        raw="$(cat /proc/sys/kernel/random/uuid)"
    elif command -v python3 > /dev/null 2>&1; then
        raw="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    else
        # Last-resort fallback with no external dependency at all. Not a real UUID (no version/
        # variant bits guaranteed), but only ever used as a crash-preventing placeholder value.
        raw="$(printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x' \
            "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM")"
    fi
    printf '{%s}' "$(tr '[:upper:]' '[:lower:]' <<< "$raw")"
}

# Bitbucket's PROJECT_KEY is a short, mnemonic, uppercase code with no CircleCI analog at all
# (it identifies a Bitbucket "project", a grouping above repository that CircleCI does not
# model). Synthesize a placeholder from the repo name purely so the variable is non-empty.
project_key_placeholder() {
    local raw="${CIRCLE_PROJECT_REPONAME:-PROJ}"
    local key
    key="$(tr -dc 'A-Za-z0-9' <<< "$raw" | tr '[:lower:]' '[:upper:]' | cut -c1-10)"
    if [[ -z "$key" ]]; then
        key="PROJ"
    fi
    printf '%s' "$key"
}

echo "Mapping CIRCLE_* build context onto BITBUCKET_* variables..."

# --- Identity / repository context -- confirmed real usage in pipe source (see README table) ---
export_kv BITBUCKET_WORKSPACE "${CIRCLE_PROJECT_USERNAME:-}"
export_kv BITBUCKET_REPO_OWNER "${CIRCLE_PROJECT_USERNAME:-}"
export_kv BITBUCKET_REPO_SLUG "${CIRCLE_PROJECT_REPONAME:-}"
export_kv BITBUCKET_REPO_FULL_NAME "${CIRCLE_PROJECT_USERNAME:-}/${CIRCLE_PROJECT_REPONAME:-}"
export_kv BITBUCKET_COMMIT "${CIRCLE_SHA1:-}"
export_kv BITBUCKET_BUILD_NUMBER "${CIRCLE_BUILD_NUM:-}"
export_kv BITBUCKET_CLONE_DIR "${ORB_VAL_CLONE_DIR}"

# --- Only set when CircleCI's own build is on a branch / tag, matching Bitbucket's own
#     "not set on the other kind of build" semantics ---
if [[ -n "${CIRCLE_BRANCH:-}" ]]; then
    export_kv BITBUCKET_BRANCH "${CIRCLE_BRANCH}"
fi
if [[ -n "${CIRCLE_TAG:-}" ]]; then
    export_kv BITBUCKET_TAG "${CIRCLE_TAG}"
fi

# --- Pull request id: format mismatch (Bitbucket wants a bare number, CIRCLE_PULL_REQUEST is a
#     full PR URL) -- parse the trailing number out; leave unset if that is not possible. ---
if [[ -n "${CIRCLE_PULL_REQUEST:-}" ]]; then
    PR_ID="$(grep -oE '[0-9]+$' <<< "${CIRCLE_PULL_REQUEST}" || true)"
    if [[ -n "${PR_ID}" ]]; then
        export_kv BITBUCKET_PR_ID "${PR_ID}"
    else
        echo "Warning: could not parse a numeric PR id out of CIRCLE_PULL_REQUEST='${CIRCLE_PULL_REQUEST}'; leaving BITBUCKET_PR_ID unset." >&2
    fi
fi

# --- Git origin URLs: best-effort synthesis from CIRCLE_REPOSITORY_URL. Atlassian's docs show
#     these pointing at bitbucket.org, but the repo genuinely is not hosted there -- preserving
#     the real host/path is more useful to a pipe than a fabricated bitbucket.org URL that does
#     not resolve, so that is the deliberate deviation from the docs' literal example domain. ---
REPO_URL="${CIRCLE_REPOSITORY_URL:-}"
if [[ "${REPO_URL}" =~ ^git@([^:]+):(.+)$ ]]; then
    GIT_HOST="${BASH_REMATCH[1]}"
    GIT_PATH="${BASH_REMATCH[2]%.git}"
    export_kv BITBUCKET_GIT_SSH_ORIGIN "git@${GIT_HOST}:${GIT_PATH}.git"
    export_kv BITBUCKET_GIT_HTTP_ORIGIN "https://${GIT_HOST}/${GIT_PATH}"
elif [[ "${REPO_URL}" =~ ^https?://([^/]+)/(.+)$ ]]; then
    GIT_HOST="${BASH_REMATCH[1]}"
    GIT_PATH="${BASH_REMATCH[2]%.git}"
    export_kv BITBUCKET_GIT_HTTP_ORIGIN "https://${GIT_HOST}/${GIT_PATH}"
    export_kv BITBUCKET_GIT_SSH_ORIGIN "git@${GIT_HOST}:${GIT_PATH}.git"
elif [[ -n "${REPO_URL}" ]]; then
    echo "Warning: could not parse CIRCLE_REPOSITORY_URL='${REPO_URL}' into a git origin; leaving BITBUCKET_GIT_HTTP_ORIGIN/BITBUCKET_GIT_SSH_ORIGIN unset." >&2
fi

# --- Synthesized placeholder identifiers -- no CircleCI equivalent exists at all; see gen_uuid's
#     comment above. Deliberately NOT synthesizing BITBUCKET_STEP_OIDC_TOKEN or
#     BITBUCKET_DEPLOYMENT_ENVIRONMENT*: those carry real semantics a pipe may branch on, and a
#     fabricated value could actively mislead it, unlike a bare identity UUID. ---
export_kv BITBUCKET_PIPELINE_UUID "$(gen_uuid)"
export_kv BITBUCKET_STEP_UUID "$(gen_uuid)"
export_kv BITBUCKET_WORKSPACE_UUID "$(gen_uuid)"
export_kv BITBUCKET_REPO_UUID "$(gen_uuid)"
export_kv BITBUCKET_PROJECT_UUID "$(gen_uuid)"
export_kv BITBUCKET_STEP_TRIGGERER_UUID "$(gen_uuid)"
export_kv BITBUCKET_PROJECT_KEY "$(project_key_placeholder)"

# --- User overrides/additions, applied last so they win over everything above. ---
if [[ -n "${ORB_VAL_EXTRA_ENV_MAPPING}" ]]; then
    if ! command -v circleci > /dev/null 2>&1; then
        echo "Error: the 'circleci' CLI is required to safely substitute \$VAR references in 'extra-env-mapping' (via 'circleci env subst') but was not found on PATH. CircleCI's machine executor images ship it preinstalled." >&2
        exit 1
    fi
    # `circleci env subst "$STRING"` is the CLI's documented safe alternative to eval for
    # resolving $VAR/${VAR} references inside a parameter value against the job's real
    # environment, without ever letting a secret's value pass through orb config
    # (https://circleci.com/changelog/new-cli-command-env-subst).
    SUBST_EXTRA="$(circleci env subst "${ORB_VAL_EXTRA_ENV_MAPPING}")"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        if [[ -z "${line}" || "${line}" == \#* ]]; then
            continue
        fi
        if [[ "${line}" != *=* ]]; then
            echo "Warning: skipping malformed extra-env-mapping line (no '='): ${line}" >&2
            continue
        fi
        KEY="${line%%=*}"
        VALUE="${line#*=}"
        if [[ ! "${KEY}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            echo "Warning: skipping extra-env-mapping line with an invalid variable name: ${line}" >&2
            continue
        fi
        export_kv "${KEY}" "${VALUE}"
        echo "Mapped (override): ${KEY}"
    done <<< "${SUBST_EXTRA}"
fi

echo "Done mapping CIRCLE_* build context onto BITBUCKET_* variables."
