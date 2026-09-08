#!/usr/bin/env bash

set -u

tested_versions_file="./tested_versions.json"
online_version_file="./xray_shell_versions.json"
components="shell xray nginx openssl jemalloc nginx_build"

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ -f "${tested_versions_file}" ]] || fail "${tested_versions_file} does not exist"
[[ -f "${online_version_file}" ]] || fail "${online_version_file} does not exist"

jq empty "${tested_versions_file}" >/dev/null 2>&1 ||
    fail "${tested_versions_file} contains invalid JSON"
jq empty "${online_version_file}" >/dev/null 2>&1 ||
    fail "${online_version_file} contains invalid JSON"

[[ "$(jq -r 'type' "${tested_versions_file}")" == "object" ]] ||
    fail "${tested_versions_file} must contain a JSON object"
[[ "$(jq -r 'type' "${online_version_file}")" == "object" ]] ||
    fail "${online_version_file} must contain a JSON object"

if jq -e '.. | select(. == null or . == "undefined")' \
    "${tested_versions_file}" "${online_version_file}" >/dev/null 2>&1; then
    fail "version JSON contains null or undefined values"
fi

for component in ${components}; do
    jq -e --arg c "${component}" '.[$c] | type == "string"' "${tested_versions_file}" >/dev/null ||
        fail "${tested_versions_file}: ${component} must be a string"
    jq -e --arg online "${component}_online_version" --arg tested "${component}_tested_version" \
        '(.[$online] | type == "string") and (.[$tested] | type == "string")' \
        "${online_version_file}" >/dev/null ||
        fail "${online_version_file}: ${component} online/tested fields must be strings"

    short_value=$(jq -r --arg c "${component}" '.[$c] // empty' "${tested_versions_file}")
    online_value=$(jq -r --arg f "${component}_online_version" '.[$f] // empty' "${online_version_file}")
    tested_value=$(jq -r --arg f "${component}_tested_version" '.[$f] // empty' "${online_version_file}")

    [[ -n "${short_value}" ]] ||
        fail "${tested_versions_file}: ${component} is missing or empty"
    [[ -n "${online_value}" ]] ||
        fail "${online_version_file}: ${component}_online_version is missing or empty"
    [[ -n "${tested_value}" ]] ||
        fail "${online_version_file}: ${component}_tested_version is missing or empty"
    [[ "${short_value}" == "${tested_value}" ]] ||
        fail "${component} tested version differs between the two JSON files"

    for version_value in "${short_value}" "${online_value}" "${tested_value}"; do
        if ! printf '%s' "${version_value}" | grep -qE '^[0-9]+(\.[0-9]+)+$'; then
            fail "${component} contains an invalid version string: ${version_value}"
        fi
    done
done

shell_upgrade_details=$(jq -r '.shell_upgrade_details // empty' "${online_version_file}")
[[ -n "${shell_upgrade_details}" ]] ||
    fail "shell_upgrade_details is missing or empty"

shell_release_sha256=$(jq -r '.shell_release_sha256 // empty' "${online_version_file}")
if [[ -n "${shell_release_sha256}" ]] && ! printf '%s' "${shell_release_sha256}" | grep -qE '^[0-9a-f]{64}$'; then
    fail "shell_release_sha256 must be 64 lowercase hex characters when present"
fi

printf '%s\n' "JSON validation successful."
