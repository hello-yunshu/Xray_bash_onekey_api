#!/usr/bin/env bash

set -euo pipefail

API_FILE="${API_FILE:-xray_shell_versions.json}"
CURL_BIN="${CURL_BIN:-curl}"
JQ_BIN="${JQ_BIN:-jq}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
MAIN_REPO="${MAIN_REPO:-hello-yunshu/Xray_bash_onekey}"
INSTALLER_REPO="${INSTALLER_REPO:-XTLS/Xray-install}"

emit() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT}"
    fi
    printf '%s=%s\n' "$1" "$2"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

json=$(mktemp)
installer_file=""
trap 'rm -f "${json}" "${installer_file}"' EXIT
http_code=$(${CURL_BIN} -fsSL --connect-timeout 15 --max-time 30 \
    -o "${json}" -w '%{http_code}' \
    "${GITHUB_API_BASE}/repos/XTLS/Xray-core/releases/latest") || fail "GitHub release request failed"
[[ "${http_code}" == 200 ]] || fail "latest Xray release returned HTTP ${http_code}"
${JQ_BIN} -e 'type == "object" and (.tag_name | type == "string")' "${json}" >/dev/null ||
    fail "latest Xray release response is malformed JSON"

tag=$(${JQ_BIN} -r '.tag_name // empty' "${json}")
draft=$(${JQ_BIN} -r '.draft // false' "${json}")
prerelease=$(${JQ_BIN} -r '.prerelease // false' "${json}")
[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "latest Xray release tag is not stable semver: ${tag}"
[[ "${draft}" == false && "${prerelease}" == false ]] || fail "latest Xray release is draft/prerelease"
candidate=${tag#v}
current=$(${JQ_BIN} -r '.xray_online_version // empty' "${API_FILE}")
[[ "${current}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "current xray_online_version is invalid"

main_sha=$(git ls-remote "https://github.com/${MAIN_REPO}.git" refs/heads/main | awk 'NR == 1 {print $1}')
[[ "${main_sha}" =~ ^[0-9a-f]{40}$ ]] || fail "unable to resolve exact main SHA"

current_installer_ref=$(${JQ_BIN} -r '.xray_installer_ref // empty' "${API_FILE}")
current_installer_sha=$(${JQ_BIN} -r '.xray_installer_sha256 // empty' "${API_FILE}")
[[ "${current_installer_ref}" =~ ^[0-9a-f]{40}$ ]] || fail "current installer ref is invalid"
[[ "${current_installer_sha}" =~ ^[0-9a-f]{64}$ ]] || fail "current installer SHA is invalid"

installer_head=$(git ls-remote "https://github.com/${INSTALLER_REPO}.git" refs/heads/main | awk 'NR == 1 {print $1}')
[[ "${installer_head}" =~ ^[0-9a-f]{40}$ ]] || fail "unable to resolve Xray-install main SHA"
installer_file=$(mktemp)
${CURL_BIN} -fsSL --connect-timeout 15 --max-time 30 \
    "https://raw.githubusercontent.com/${INSTALLER_REPO}/${installer_head}/install-release.sh" \
    -o "${installer_file}" || fail "unable to download exact installer candidate"
[[ -s "${installer_file}" ]] || fail "installer candidate is empty"
bash -n "${installer_file}" || fail "installer candidate has shell syntax errors"
installer_sha=$(sha256sum "${installer_file}" | awk '{print $1}')
[[ "${installer_sha}" =~ ^[0-9a-f]{64}$ ]] || fail "installer candidate SHA is invalid"

changed=0
if [[ "${candidate}" != "${current}" ]]; then
    if [[ "$(printf '%s\n%s\n' "${current}" "${candidate}" | sort -V | head -n1)" != "${current}" ]]; then
        fail "Xray candidate would downgrade production ${current} -> ${candidate}"
    fi
    changed=1
fi

installer_changed=0
[[ "${installer_head}" == "${current_installer_ref}" ]] || installer_changed=1

emit candidate_version "${candidate}"
emit current_xray_version "${current}"
emit xray_changed "${changed}"
emit main_sha "${main_sha}"
emit current_installer_ref "${current_installer_ref}"
emit current_installer_sha "${current_installer_sha}"
emit installer_candidate_ref "${installer_head}"
emit installer_candidate_sha "${installer_sha}"
emit installer_changed "${installer_changed}"
