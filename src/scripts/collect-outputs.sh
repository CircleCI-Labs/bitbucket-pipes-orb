#!/bin/bash
set -euo pipefail

# Reads back whatever KEY=value lines the pipe appended to $BITBUCKET_PIPELINES_VARIABLES_PATH
# and exports each one, verbatim, into $BASH_ENV. Real Bitbucket only exports the subset of keys
# the pipeline author lists in the step's `output-variables:` -- since we are not going through
# Bitbucket's own scheduler, that declaration does not exist for us to read, so every line in the
# file is exported unconditionally. Most official pipes never write to this file at all (see the
# README); when they don't, this is a no-op against an empty file.

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
    ESCAPED_VALUE="${VALUE//\'/\'\\\'\'}"
    echo "export ${KEY}='${ESCAPED_VALUE}'" >> "${BASH_ENV}"
    echo "Exported ${KEY} from the pipe's output-variables file into \$BASH_ENV for later native steps."
    FOUND_ANY=1
done < "${OUTPUT_FILE}"

if [[ "${FOUND_ANY}" -eq 0 ]]; then
    echo "The pipe's output-variables file at ${OUTPUT_FILE} was empty; nothing to export. This is normal -- most official Bitbucket pipes never write to it (see the README)."
fi
