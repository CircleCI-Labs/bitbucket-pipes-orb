#!/bin/bash
set -euo pipefail

# Reads back whatever KEY=value lines the pipe appended to $BITBUCKET_PIPELINES_VARIABLES_PATH
# and exports each one, verbatim, into $BASH_ENV. Real Bitbucket only exports the subset of keys
# the pipeline author lists in the step's `output-variables:` -- since we are not going through
# Bitbucket's own scheduler, that declaration does not exist for us to read, so every line in the
# file is exported unconditionally. Most official pipes never write to this file at all (see the
# README); when they don't, this is a no-op against an empty file.

# Shell-control variable names this script must never export from the output file, no matter
# how the pipe's container behaved. The identifier-syntax check below (`^[A-Za-z_][A-Za-z0-9_]*$`)
# alone admits PATH/BASH_ENV/IFS/etc, and this file's *content* is written entirely by the pipe's
# own (third-party, potentially untrusted) Docker container -- a compromised or malicious pipe
# image writing a bare `PATH=` or `BASH_ENV=...` line here would otherwise get that value sourced
# into every later native step in the job via $BASH_ENV. No real Bitbucket pipe declares an
# output-variable literally named PATH or BASH_ENV, so this costs nothing against the real
# contract. See the README's "Bitbucket variables are literal" section for the documented
# tradeoff.
RESERVED_SHELL_VAR_NAMES=(
    PATH IFS BASH_ENV ENV SHELL SHELLOPTS PS4
    LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH
    NODE_OPTIONS GIT_SSH_COMMAND PERL5LIB PYTHONPATH RUBYOPT CDPATH
)
is_reserved_shell_var_name() {
    local candidate="$1" reserved
    for reserved in "${RESERVED_SHELL_VAR_NAMES[@]}"; do
        if [[ "${candidate}" == "${reserved}" ]]; then
            return 0
        fi
    done
    return 1
}

OUTPUT_FILE="${ORB_VAL_OUTPUT_FILE}"

if [[ ! -f "${OUTPUT_FILE}" ]]; then
    echo "No output-variables file found at ${OUTPUT_FILE}; nothing to export."
    exit 0
fi

FOUND_ANY=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    if [[ -z "${line}" || "${line}" == \#* ]]; then
        continue
    fi
    if [[ "${line}" != *=* ]]; then
        echo "Warning: skipping malformed output line (no '='): ${line}" >&2
        continue
    fi
    KEY="${line%%=*}"
    VALUE="${line#*=}"
    if [[ ! "${KEY}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Warning: skipping output line with an invalid variable name: ${line}" >&2
        continue
    fi
    if is_reserved_shell_var_name "${KEY}"; then
        echo "Warning: skipping output line naming the reserved shell-control variable '${KEY}'; a pipe's output-variables file can never set PATH/BASH_ENV/IFS/etc, since that would rewrite the shell environment for every later step in the job. No real Bitbucket pipe declares an output variable named '${KEY}'. See the README." >&2
        continue
    fi
    ESCAPED_VALUE="${VALUE//\'/\'\\\'\'}"
    echo "export ${KEY}='${ESCAPED_VALUE}'" >> "${BASH_ENV}"
    echo "Exported ${KEY} from the pipe's output-variables file into \$BASH_ENV for later native steps."
    FOUND_ANY=1
done < "${OUTPUT_FILE}"

if [[ "${FOUND_ANY}" -eq 0 ]]; then
    echo "The pipe's output-variables file at ${OUTPUT_FILE} was empty; nothing to export. This is normal -- most official Bitbucket pipes never write to it (see the README)."
fi
