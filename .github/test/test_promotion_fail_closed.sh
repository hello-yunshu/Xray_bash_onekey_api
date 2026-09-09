#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
cp "${repo}/xray_shell_versions.json" "${tmp}/versions.json"
before=$(sha256sum "${tmp}/versions.json" | awk '{print $1}')

if API_FILE="${tmp}/versions.json" MAIN_REPO_SHA=0123456789012345678901234567890123456789 \
    EXPECTED_MAIN_SHA=0123456789012345678901234567890123456789 \
    CANDIDATE_GATE=FAIL bash "${repo}/.github/scripts/promote_verified_candidate.sh" xray 99.99.99; then
    echo 'FAIL: rejected candidate unexpectedly promoted'
    exit 1
fi
after=$(sha256sum "${tmp}/versions.json" | awk '{print $1}')
[[ "${before}" == "${after}" ]] || { echo 'FAIL: rejected candidate mutated API metadata'; exit 1; }

if API_FILE="${tmp}/versions.json" MAIN_REPO_SHA=0123456789012345678901234567890123456789 \
    EXPECTED_MAIN_SHA=0123456789012345678901234567890123456789 \
    CANDIDATE_GATE=PASS bash "${repo}/.github/scripts/promote_verified_candidate.sh" xray 25.12.8; then
    echo 'FAIL: downgrade unexpectedly promoted'
    exit 1
fi
after=$(sha256sum "${tmp}/versions.json" | awk '{print $1}')
[[ "${before}" == "${after}" ]] || { echo 'FAIL: downgrade mutated API metadata'; exit 1; }
echo 'Promotion fail-closed regression passed'
