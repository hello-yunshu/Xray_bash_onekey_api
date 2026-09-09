#!/usr/bin/env bash

set -euo pipefail

kind=${1:?candidate kind is required: xray|installer}
value=${2:?candidate value is required}
gate=${CANDIDATE_GATE:-FAIL}
api_file=${API_FILE:-xray_shell_versions.json}
main_sha=${MAIN_REPO_SHA:?exact qualified main SHA is required}
expected_main_sha=${EXPECTED_MAIN_SHA:-${main_sha}}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "${gate}" == PASS ]] || fail "candidate gate did not pass; production metadata remains unchanged"
[[ "${main_sha}" =~ ^[0-9a-f]{40}$ && "${main_sha}" == "${expected_main_sha}" ]] ||
    fail "qualification is not bound to the expected exact main SHA"

case "${kind}" in
    xray)
        [[ "${value}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid Xray candidate version"
        current=$(jq -r '.xray_online_version // empty' "${api_file}")
        [[ "${current}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid current Xray version"
        if [[ "${value}" == "${current}" ]]; then
            echo "No Xray promotion required: ${value} is already production"
            exit 0
        fi
        [[ "$(printf '%s\n%s\n' "${current}" "${value}" | sort -V | head -n1)" == "${current}" ]] ||
            fail "downgrade rejected: ${current} -> ${value}"
        jq --arg value "${value}" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '.xray_online_version = $value | .xray_verified_at = $now' \
            "${api_file}" >"${api_file}.tmp"
        ;;
    installer)
        [[ "${value}" =~ ^[0-9a-f]{40}$ ]] || fail "invalid installer ref"
        installer_sha=${INSTALLER_SHA256:?installer SHA is required}
        [[ "${installer_sha}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid installer SHA"
        current=$(jq -r '.xray_installer_ref // empty' "${api_file}")
        if [[ "${value}" == "${current}" ]]; then
            echo "No installer promotion required: ${value} is already production"
            exit 0
        fi
        jq --arg ref "${value}" --arg sha "${installer_sha}" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '.xray_installer_ref = $ref | .xray_installer_sha256 = $sha | .xray_installer_verified_at = $now' \
            "${api_file}" >"${api_file}.tmp"
        ;;
    *) fail "unknown candidate kind: ${kind}" ;;
esac

jq empty "${api_file}.tmp" || fail "promotion generated invalid JSON"
mv "${api_file}.tmp" "${api_file}"
bash "$(dirname "$0")/../../validate-json.sh"
echo "Promoted verified ${kind} candidate ${value} for main ${main_sha}"
