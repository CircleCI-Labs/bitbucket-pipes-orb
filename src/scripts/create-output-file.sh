#!/bin/bash
set -euo pipefail

# Creates the file a pipe appends KEY=value output lines to (the real Bitbucket
# BITBUCKET_PIPELINES_VARIABLES_PATH mechanism -- see the README for how rarely pipes actually
# use it) plus the two pipe-to-pipe scratch directories some pipes read directly
# (BITBUCKET_PIPE_STORAGE_DIR / BITBUCKET_PIPE_SHARED_STORAGE_DIR). All three live under a
# scratch root kept outside the checkout so they never show up as untracked repo files.
#
# The paths are exported into $BASH_ENV so later native steps (and the `map-env`/`run`/
# `collect-outputs` commands, if composed without re-passing the same parameter values) can see
# them without every caller having to thread the parameter through again.

# Bash-safe truthiness / export helpers shared by this orb's scripts. CircleCI's docs do not
# commit to a single stringified form of a boolean parameter reaching a step's `environment:`
# block, so accept both the historical "0"/"1" and the literal "true"/"false" spellings.
export_kv() {
    local key="$1" value="$2"
    local escaped="${value//\'/\'\\\'\'}"
    echo "export ${key}='${escaped}'" >> "$BASH_ENV"
}

OUTPUT_FILE="${ORB_VAL_OUTPUT_FILE}"
PIPE_STORAGE_DIR="${ORB_VAL_PIPE_STORAGE_DIR}"
PIPE_SHARED_STORAGE_DIR="${ORB_VAL_PIPE_SHARED_STORAGE_DIR}"

mkdir -p "$(dirname "${OUTPUT_FILE}")" "${PIPE_STORAGE_DIR}" "${PIPE_SHARED_STORAGE_DIR}"

# Truncate/create the output file fresh. A pre-existing empty file at this path is all a pipe
# needs -- it just appends to it, per Atlassian's step-options reference.
: > "${OUTPUT_FILE}"

echo "Created output-variables file at ${OUTPUT_FILE}"
echo "Created pipe storage dirs at ${PIPE_STORAGE_DIR} and ${PIPE_SHARED_STORAGE_DIR}"

export_kv BITBUCKET_PIPELINES_VARIABLES_PATH "${OUTPUT_FILE}"
export_kv BITBUCKET_PIPE_STORAGE_DIR "${PIPE_STORAGE_DIR}"
export_kv BITBUCKET_PIPE_SHARED_STORAGE_DIR "${PIPE_SHARED_STORAGE_DIR}"
