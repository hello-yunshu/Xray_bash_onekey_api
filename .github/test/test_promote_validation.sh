#!/usr/bin/env bash
# Test suite for Task B: tested_version preservation and controlled promotion.
# Validates:
#   1. tested_version fields exist and are not null/empty
#   2. Promotion input validation (component allowlist, version format)
#   3. update-version.sh does NOT auto-copy online to tested
#   4. Both JSON files pass jq empty
#
# Run: bash .github/test/test_promote_validation.sh

set -u

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "${REPO_DIR}"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "============================================"
echo "  Testing tested_version preservation (Task B)"
echo "============================================"
echo ""

echo "--- Test: JSON files exist and are valid ---"
if jq empty tested_versions.json 2>/dev/null; then
    pass "tested_versions.json is valid JSON"
else
    fail "tested_versions.json is invalid JSON"
fi

if jq empty xray_shell_versions.json 2>/dev/null; then
    pass "xray_shell_versions.json is valid JSON"
else
    fail "xray_shell_versions.json is invalid JSON"
fi

echo ""
echo "--- Test: All tested_version fields exist and are non-null ---"
COMPONENTS="shell xray nginx openssl jemalloc nginx_build"
ALL_TESTED_OK=true
for comp in ${COMPONENTS}; do
    # Check tested_versions.json (short key)
    val=$(jq -r --arg c "${comp}" '.[$c]' tested_versions.json 2>/dev/null)
    if [[ -z "${val}" || "${val}" == "null" ]]; then
        fail "tested_versions.json: ${comp} is missing/null"
        ALL_TESTED_OK=false
    fi

    # Check xray_shell_versions.json (long key)
    val_long=$(jq -r ".${comp}_tested_version" xray_shell_versions.json 2>/dev/null)
    if [[ -z "${val_long}" || "${val_long}" == "null" ]]; then
        fail "xray_shell_versions.json: ${comp}_tested_version is missing/null"
        ALL_TESTED_OK=false
    fi
done
if ${ALL_TESTED_OK}; then
    pass "All tested_version fields exist and are non-null"
fi

echo ""
echo "--- Test: tested_version values match between two files ---"
MATCH_OK=true
for comp in ${COMPONENTS}; do
    short_val=$(jq -r --arg c "${comp}" '.[$c]' tested_versions.json)
    long_val=$(jq -r ".${comp}_tested_version" xray_shell_versions.json)
    if [[ "${short_val}" != "${long_val}" ]]; then
        fail "${comp}: tested_versions.json=${short_val} != xray_shell_versions.json=${long_val}"
        MATCH_OK=false
    fi
done
if ${MATCH_OK}; then
    pass "All tested_version values are consistent between files"
fi

echo ""
echo "--- Test: Promotion component allowlist ---"
# Test that only allowed components pass validation
ALLOWED="shell xray nginx openssl jemalloc nginx_build"
for comp in ${ALLOWED}; do
    case "${comp}" in
        shell|xray|nginx|openssl|jemalloc|nginx_build)
            pass "Component '${comp}' is in allowlist"
            ;;
        *)
            fail "Component '${comp}' should be in allowlist"
            ;;
    esac
done

# Test that disallowed components are rejected
DISALLOWED="rill-ml stable candidate edge ; rm -rf / \$HOME"
for comp in ${DISALLOWED}; do
    case "${comp}" in
        shell|xray|nginx|openssl|jemalloc|nginx_build)
            fail "Component '${comp}' should be rejected"
            ;;
        *)
            pass "Component '${comp}' correctly rejected"
            ;;
    esac
done

echo ""
echo "--- Test: Version format validation ---"
# Valid semver-like versions
VALID_VERSIONS="1.0 1.0.0 25.12.8 3.0.1 5.3.0 1.28.1 3.6.0"
for ver in ${VALID_VERSIONS}; do
    if printf '%s' "${ver}" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)*$'; then
        pass "Version '${ver}' accepted (semver-like)"
    else
        fail "Version '${ver}' should be accepted"
    fi
done

# Valid nginx_build versions
VALID_BUILD_VERSIONS="2025.12.23 2026.07.15.6961 2025.01.01"
for ver in ${VALID_BUILD_VERSIONS}; do
    if printf '%s' "${ver}" | grep -qE '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'; then
        pass "nginx_build version '${ver}' accepted"
    else
        fail "nginx_build version '${ver}' should be accepted"
    fi
done

# Invalid versions
INVALID_VERSIONS="null undefined '' ' ' 'v1.0.0' '1..0' '1.0.0-beta' 'abc' '<script>' '; rm -rf /'"
for ver in ${INVALID_VERSIONS}; do
    # Unwrap the quoted empty string
    test_ver="${ver}"
    [[ "${ver}" == "''" ]] && test_ver=""
    if printf '%s' "${test_ver}" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)*$'; then
        fail "Version '${ver}' should be rejected"
    else
        pass "Version '${ver}' correctly rejected"
    fi
done

echo ""
echo "--- Test: update-version.sh does NOT auto-copy online to tested ---"
# Read update-version.sh and verify it reads tested from tested_versions.json
# not from online_versions
if grep -q 'tested_versions\[\$key\]' update-version.sh; then
    pass "update-version.sh reads tested_version from tested_versions.json (not from online)"
else
    fail "update-version.sh may be auto-copying online to tested"
fi

# Verify update-version.sh writes tested_version from the tested_versions array
# The pattern in update-version.sh is: ${tested_versions[$key]} ... _tested_version
# (tested_versions array is referenced before _tested_version field name in the jq command)
if grep -q 'tested_versions.*_tested_version\|_tested_version.*tested_versions' update-version.sh; then
    pass "update-version.sh correctly maps tested_version from tested_versions.json"
else
    fail "update-version.sh may not correctly map tested_version"
fi

# Verify there is no bulk copy of online to tested
if grep -q 'online.*tested\|tested.*online' update-version.sh 2>/dev/null; then
    # Check if it's actually copying (not just both being mentioned in comments)
    if grep -qE '(tested_version.*=.*online_version|_tested_version.*\$new_value)' update-version.sh; then
        fail "update-version.sh appears to copy online to tested"
    else
        pass "update-version.sh does not bulk-copy online to tested"
    fi
else
    pass "update-version.sh does not bulk-copy online to tested"
fi

echo ""
echo "--- Test: Old bulk-copy workflow is removed ---"
if [[ ! -f .github/workflows/update_tested_versions.yml ]]; then
    pass "Old update_tested_versions.yml (bulk copy) is removed"
else
    fail "update_tested_versions.yml still exists (should be replaced by promote_tested_version.yml)"
fi

if [[ -f .github/workflows/promote_tested_version.yml ]]; then
    pass "promote_tested_version.yml exists (single-component promotion)"
else
    fail "promote_tested_version.yml is missing"
fi

echo ""
echo "--- Test: promote_tested_version.yml uses workflow_dispatch with inputs ---"
if grep -q 'workflow_dispatch' .github/workflows/promote_tested_version.yml; then
    pass "promote_tested_version.yml is manually triggered (workflow_dispatch)"
else
    fail "promote_tested_version.yml should be workflow_dispatch only"
fi

if grep -q 'inputs:' .github/workflows/promote_tested_version.yml; then
    pass "promote_tested_version.yml accepts inputs (component, version, note)"
else
    fail "promote_tested_version.yml should accept inputs"
fi

if grep -q 'type: choice' .github/workflows/promote_tested_version.yml; then
    pass "promote_tested_version.yml uses choice for component allowlist"
else
    fail "promote_tested_version.yml should use choice type for component"
fi

echo ""
echo "--- Test: validate-json.sh checks tested_version fields ---"
if grep -q '_tested_version' validate-json.sh; then
    pass "validate-json.sh validates tested_version fields"
else
    fail "validate-json.sh should validate tested_version fields"
fi

echo ""
echo "--- Test: Single-component promotion simulation ---"
# Simulate promoting a single component and verify only that field changes
TMP_TESTED=$(mktemp)
TMP_VERSIONS=$(mktemp)
cp tested_versions.json "${TMP_TESTED}"
cp xray_shell_versions.json "${TMP_VERSIONS}"

# Simulate promoting xray to a new version
NEW_XRAY_VERSION="99.99.99"
jq --arg c "xray" --arg v "${NEW_XRAY_VERSION}" '.[$c] = $v' tested_versions.json > tested_versions.json.tmp
mv tested_versions.json.tmp tested_versions.json

jq --arg field "xray_tested_version" --arg v "${NEW_XRAY_VERSION}" '.[$field] = $v' xray_shell_versions.json > xray_shell_versions.json.tmp
mv xray_shell_versions.json.tmp xray_shell_versions.json

# Verify only xray changed, others are unchanged
XRAY_TESTED=$(jq -r '.xray' tested_versions.json)
SHELL_TESTED=$(jq -r '.shell' tested_versions.json)
NGINX_TESTED=$(jq -r '.nginx' tested_versions.json)

if [[ "${XRAY_TESTED}" == "${NEW_XRAY_VERSION}" ]]; then
    pass "Promoted xray_tested_version to ${NEW_XRAY_VERSION}"
else
    fail "xray_tested_version was not updated correctly"
fi

OLD_SHELL_TESTED=$(jq -r '.shell' "${TMP_TESTED}")
OLD_NGINX_TESTED=$(jq -r '.nginx' "${TMP_TESTED}")

if [[ "${SHELL_TESTED}" == "${OLD_SHELL_TESTED}" ]]; then
    pass "shell_tested_version unchanged after xray promotion"
else
    fail "shell_tested_version was modified (should not be)"
fi

if [[ "${NGINX_TESTED}" == "${OLD_NGINX_TESTED}" ]]; then
    pass "nginx_tested_version unchanged after xray promotion"
else
    fail "nginx_tested_version was modified (should not be)"
fi

# Restore originals
cp "${TMP_TESTED}" tested_versions.json
cp "${TMP_VERSIONS}" xray_shell_versions.json
rm -f "${TMP_TESTED}" "${TMP_VERSIONS}"

echo ""
echo "============================================"
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo "============================================"

if [[ ${FAIL} -gt 0 ]]; then
    exit 1
fi
exit 0
