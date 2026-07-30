#!/usr/bin/env bash
# Tests for promote_tested_version.sh
#
# Run: bash .github/test/test_promote_tested_version.sh
#
# Requirements: bash 3.2+, jq
# Compatible with macOS (BSD sed, bash 3.2, no mapfile/readarray)
#
# Tests use fixture data and mock http_get to simulate upstream API responses.
# No real GitHub API calls are made.
#
# Test coverage:
#   - Upstream network failure → reject
#   - Shell fetch failure → reject
#   - Tag not found → reject
#   - Nginx Release missing manifest → reject
#   - Manifest missing SHA → reject
#   - Manifest version mismatch → reject
#   - Only target component modified
#   - Note only modifies target metadata
#   - Note with newlines/control chars → sanitized
#   - Any step failure → both JSON restored
#   - Online fields never modified
#   - Old bulk-copy workflow not restored

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="$SCRIPT_DIR/../scripts/promote_tested_version.sh"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found. Install with: brew install jq" >&2
  exit 1
fi

if [ ! -f "$SOURCE_SCRIPT" ]; then
  echo "ERROR: source script not found: $SOURCE_SCRIPT" >&2
  exit 1
fi

# Colors (disable if not a TTY)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  printf "${GREEN}PASS${NC}: %s\n" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf "${RED}FAIL${NC}: %s\n" "$1"
  shift
  while [ $# -gt 0 ]; do
    printf "       %s\n" "$1"
    shift
  done
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name"
  else
    fail "$name" "expected: $expected" "actual:   $actual"
  fi
}

assert_ne() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    pass "$name"
  else
    fail "$name" "expected NOT: $expected" "actual:       $actual"
  fi
}

assert_contains() {
  local name="$1" needle="$2" haystack="$3"
  # Use case statement for literal matching (grep -F mishandles newlines)
  case "$haystack" in
    *"$needle"*)
      pass "$name"
      ;;
    *)
      fail "$name" "expected to contain: $needle" "actual: $haystack"
      ;;
  esac
}

assert_not_contains() {
  local name="$1" needle="$2" haystack="$3"
  # Use case statement for literal matching (grep -F mishandles newlines)
  case "$haystack" in
    *"$needle"*)
      fail "$name" "should NOT contain: $needle" "actual: $haystack"
      ;;
    *)
      pass "$name"
      ;;
  esac
}

# Assert that promotion was rejected (exit non-zero)
assert_rejected() {
  local name="$1" exit_code="$2"
  if [ "$exit_code" -ne 0 ]; then
    pass "$name (exit=$exit_code)"
  else
    fail "$name" "expected non-zero exit but got 0"
  fi
}

# Assert that promotion succeeded (exit 0)
assert_promoted() {
  local name="$1" exit_code="$2"
  if [ "$exit_code" -eq 0 ]; then
    pass "$name (exit=0)"
  else
    fail "$name" "expected exit 0 but got $exit_code"
  fi
}

# ============================================================================
# Source the script under test
# ============================================================================

# shellcheck source=../scripts/promote_tested_version.sh
source "$SOURCE_SCRIPT"

# ============================================================================
# Fixture data
# ============================================================================

FIXTURE_TESTED='{
  "shell": "2.8.3",
  "xray": "25.12.8",
  "nginx": "1.28.1",
  "openssl": "3.6.0",
  "jemalloc": "5.3.0",
  "nginx_build": "2025.12.23"
}'

FIXTURE_VERSIONS='{
  "update_date": "2026-07-15 20:56",
  "shell_online_version": "3.0.1",
  "shell_tested_version": "2.8.3",
  "shell_upgrade_details": "fix: polish adaptive menu boxes",
  "nginx_build_online_version": "2026.07.15.6961",
  "nginx_build_tested_version": "2025.12.23",
  "nginx_online_version": "1.30.4",
  "nginx_tested_version": "1.28.1",
  "xray_online_version": "26.3.27",
  "xray_tested_version": "25.12.8",
  "jemalloc_online_version": "5.3.1",
  "jemalloc_tested_version": "5.3.0",
  "openssl_online_version": "3.6.3",
  "openssl_tested_version": "3.6.0"
}'

FIXTURE_HTML='<html><head><title>404 Not Found</title></head><body>Not Found</body></html>'

# Shell install.sh content with shell_version
make_install_sh() {
  local ver="$1"
  printf '#!/bin/bash\nshell_version="%s"\necho "version: %s"\n' "$ver" "$ver"
}

# GitHub release JSON for a tag
make_release_json() {
  local tag="$1"
  printf '{"tag_name": "%s", "assets": []}' "$tag"
}

# nginx_build release JSON with manifest asset.
# Explicitly sets draft=false and prerelease=false so the release is a valid
# published stable release. Tests that need to verify draft/prerelease rejection
# use make_nginx_build_release_draft / make_nginx_build_release_prerelease.
make_nginx_build_release_json() {
  local version="$1"
  printf '{"tag_name": "v%s", "draft": false, "prerelease": false, "assets": [
    {"name": "release-manifest.json", "browser_download_url": "https://example.com/manifest_%s.json"},
    {"name": "SHA256SUMS", "browser_download_url": "https://example.com/SHA256SUMS"},
    {"name": "xray-nginx-custom-x86.tar.gz", "browser_download_url": "https://example.com/x86.tar.gz"},
    {"name": "xray-nginx-custom-arm.tar.gz", "browser_download_url": "https://example.com/arm.tar.gz"}
  ]}' "$version" "$version"
}

# nginx_build release JSON marked as DRAFT (must be rejected by promotion).
# Has all required assets but draft=true.
make_nginx_build_release_draft() {
  local version="$1"
  printf '{"tag_name": "v%s", "draft": true, "prerelease": false, "assets": [
    {"name": "release-manifest.json", "browser_download_url": "https://example.com/manifest_%s.json"},
    {"name": "SHA256SUMS", "browser_download_url": "https://example.com/SHA256SUMS"},
    {"name": "xray-nginx-custom-x86.tar.gz", "browser_download_url": "https://example.com/x86.tar.gz"},
    {"name": "xray-nginx-custom-arm.tar.gz", "browser_download_url": "https://example.com/arm.tar.gz"}
  ]}' "$version" "$version"
}

# nginx_build release JSON marked as PRERELEASE (must be rejected by promotion).
# Has all required assets but prerelease=true.
make_nginx_build_release_prerelease() {
  local version="$1"
  printf '{"tag_name": "v%s", "draft": false, "prerelease": true, "assets": [
    {"name": "release-manifest.json", "browser_download_url": "https://example.com/manifest_%s.json"},
    {"name": "SHA256SUMS", "browser_download_url": "https://example.com/SHA256SUMS"},
    {"name": "xray-nginx-custom-x86.tar.gz", "browser_download_url": "https://example.com/x86.tar.gz"},
    {"name": "xray-nginx-custom-arm.tar.gz", "browser_download_url": "https://example.com/arm.tar.gz"}
  ]}' "$version" "$version"
}

# nginx_build release JSON WITHOUT manifest asset
make_nginx_build_release_no_manifest() {
  local version="$1"
  printf '{"tag_name": "v%s", "assets": [{"name": "xray-nginx-custom-x86.tar.gz", "browser_download_url": "https://example.com/x86.tar.gz"}]}' "$version"
}

make_nginx_build_release_no_arm() {
  local version="$1"
  printf '{"tag_name": "v%s", "assets": [
    {"name": "release-manifest.json", "browser_download_url": "https://example.com/manifest_%s.json"},
    {"name": "SHA256SUMS", "browser_download_url": "https://example.com/SHA256SUMS"},
    {"name": "xray-nginx-custom-x86.tar.gz", "browser_download_url": "https://example.com/x86.tar.gz"}
  ]}' "$version" "$version"
}

# Manifest JSON with SHA256
make_manifest_valid() {
  local version="$1"
  printf '{
    "schema_version": 1,
    "tag": "v%s",
    "versions": {"nginx_build": "%s", "nginx": "1.28.1"},
    "assets": [
      {"arch": "x86", "filename": "xray-nginx-custom-x86.tar.gz", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size_bytes": 12345},
      {"arch": "arm", "filename": "xray-nginx-custom-arm.tar.gz", "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "size_bytes": 12346}
    ]
  }' "$version" "$version"
}

# Manifest JSON without SHA256 (empty sha256 field)
make_manifest_no_sha() {
  local version="$1"
  printf '{
    "schema_version": 1,
    "versions": {"nginx_build": "%s"},
    "assets": [
      {"arch": "x86", "filename": "xray-nginx-custom-x86.tar.gz", "sha256": "", "size_bytes": 12345},
      {"arch": "arm", "filename": "xray-nginx-custom-arm.tar.gz", "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "size_bytes": 12346}
    ]
  }' "$version"
}

# Manifest JSON with version mismatch
make_manifest_version_mismatch() {
  local version="$1"
  local wrong_version="$2"
  printf '{
    "schema_version": 1,
    "versions": {"nginx_build": "%s"},
    "assets": [
      {"arch": "x86", "filename": "xray-nginx-custom-x86.tar.gz", "sha256": "abc123", "size_bytes": 12345}
    ]
  }' "$wrong_version"
}

make_manifest_no_arm() {
  local version="$1"
  printf '{
    "schema_version": 1,
    "tag": "v%s",
    "versions": {"nginx_build": "%s"},
    "assets": [
      {"arch": "x86", "filename": "xray-nginx-custom-x86.tar.gz", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    ]
  }' "$version" "$version"
}

# Commit history JSON for shell
make_commits_json() {
  printf '['
  local first=1
  for sha in "$@"; do
    if [ $first -eq 1 ]; then
      first=0
    else
      printf ','
    fi
    printf '{"sha": "%s", "commit": {"message": "update install.sh"}}' "$sha"
  done
  printf ']'
}

# Compute SHA256 of a string (same method as the script under test).
# Uses shasum on macOS, falls back to sha256sum on Linux.
compute_sha256_str() {
  local content="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$content" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$content" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

# P0-5: Compute SHA256 of a file's exact bytes (byte-exact, including trailing
# newlines). Mirrors how the script under test computes the manifest digest via
# `shasum -a 256 "$manifest_file"`.
compute_sha256_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    return 1
  fi
}

# P0-5: Compute SHA256 of content as if written to a file with a specified
# trailing-newline policy. This mirrors how http_download_file writes bytes to
# disk (preserving exact bytes including any trailing newline), so the digest
# matches what the script under test will compute over the downloaded file.
# Args: content_string, trailing_newline ("yes" or "no")
compute_sha256_content_as_file() {
  local content="$1"
  local trailing="$2"
  local tmp
  tmp=$(mktemp) || return 1
  if [ "$trailing" = "yes" ]; then
    printf '%s\n' "$content" > "$tmp"
  else
    printf '%s' "$content" > "$tmp"
  fi
  compute_sha256_file "$tmp"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# Generate SHA256SUMS content.
# Args: x86_sha arm_sha manifest_sha
make_sha256sums() {
  printf '%s  xray-nginx-custom-x86.tar.gz\n' "$1"
  printf '%s  xray-nginx-custom-arm.tar.gz\n' "$2"
  printf '%s  release-manifest.json\n' "$3"
}

# nginx_build release JSON WITHOUT SHA256SUMS asset
make_nginx_build_release_no_sha256sums() {
  local version="$1"
  printf '{"tag_name": "v%s", "assets": [
    {"name": "release-manifest.json", "browser_download_url": "https://example.com/manifest_%s.json"},
    {"name": "xray-nginx-custom-x86.tar.gz", "browser_download_url": "https://example.com/x86.tar.gz"},
    {"name": "xray-nginx-custom-arm.tar.gz", "browser_download_url": "https://example.com/arm.tar.gz"}
  ]}' "$version" "$version"
}

# Manifest JSON with filename that does NOT match canonical contract.
make_manifest_filename_mismatch() {
  local version="$1"
  printf '{
    "schema_version": 1,
    "tag": "v%s",
    "versions": {"nginx_build": "%s", "nginx": "1.28.1"},
    "assets": [
      {"arch": "x86", "filename": "xray-nginx-custom-x86-MISMATCH.tar.gz", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "size_bytes": 12345},
      {"arch": "arm", "filename": "xray-nginx-custom-arm.tar.gz", "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "size_bytes": 12346}
    ]
  }' "$version" "$version"
}

# Release JSON listing the mismatched x86 filename so existing asset checks pass.
make_nginx_build_release_filename_mismatch() {
  local version="$1"
  printf '{"tag_name": "v%s", "assets": [
    {"name": "release-manifest.json", "browser_download_url": "https://example.com/manifest_%s.json"},
    {"name": "SHA256SUMS", "browser_download_url": "https://example.com/SHA256SUMS"},
    {"name": "xray-nginx-custom-x86-MISMATCH.tar.gz", "browser_download_url": "https://example.com/x86.tar.gz"},
    {"name": "xray-nginx-custom-arm.tar.gz", "browser_download_url": "https://example.com/arm.tar.gz"}
  ]}' "$version" "$version"
}

# ============================================================================
# Test helper: set up temp dir with fixture JSON files
# ============================================================================

setup_temp_repo() {
  TMPDIR_TEST=$(mktemp -d)
  cp "$REPO_DIR/tested_versions.json" "$TMPDIR_TEST/tested_versions.json" 2>/dev/null || \
    printf '%s\n' "$FIXTURE_TESTED" > "$TMPDIR_TEST/tested_versions.json"
  cp "$REPO_DIR/xray_shell_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null || \
    printf '%s\n' "$FIXTURE_VERSIONS" > "$TMPDIR_TEST/xray_shell_versions.json"
  echo "$TMPDIR_TEST"
}

cleanup_temp_repo() {
  local dir="$1"
  [ -d "$dir" ] && rm -rf "$dir"
}

# ============================================================================
# Mock http_get functions (override the script's http_get)
# ============================================================================

# Mock: all network requests fail (network failure)
mock_http_all_fail() {
  FETCH_HTTP_CODE="000"
  return 1
}

# Mock: returns HTML for all requests (HTML response)
mock_http_html() {
  FETCH_HTTP_CODE="200"
  printf '%s' "$FIXTURE_HTML"
  return 0
}

# Mock: shell install.sh fetch fails, other requests succeed
mock_http_shell_fetch_fail() {
  local url="$1"
  case "$url" in
    */install.sh)
      FETCH_HTTP_CODE="000"
      return 1
      ;;
    */commits*)
      FETCH_HTTP_CODE="000"
      return 1
      ;;
    *)
      FETCH_HTTP_CODE="200"
      printf '{"tag_name": "v1.0.0"}'
      return 0
      ;;
  esac
}

# Mock: xray tag not found (404)
mock_http_xray_tag_not_found() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v99.99.99"*)
      FETCH_HTTP_CODE="404"
      printf '{"message": "Not Found"}'
      return 1
      ;;
    *)
      FETCH_HTTP_CODE="200"
      printf '{"tag_name": "v25.12.8"}'
      return 0
      ;;
  esac
}

# Mock: API rate limited (403)
mock_http_rate_limited() {
  FETCH_HTTP_CODE="403"
  printf '{"message": "API rate limit exceeded"}'
  return 1
}

# Mock: shell version found in main install.sh
mock_http_shell_in_main() {
  local url="$1"
  case "$url" in
    */main/install.sh)
      FETCH_HTTP_CODE="200"
      make_install_sh "2.8.3"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="200"
      printf '{"tag_name": "v1.0.0"}'
      return 0
      ;;
  esac
}

# Mock: shell version found in historical commit (not in main)
mock_http_shell_in_history() {
  local url="$1"
  case "$url" in
    */main/install.sh)
      FETCH_HTTP_CODE="200"
      make_install_sh "3.0.1"
      return 0
      ;;
    *"/commits?path=install.sh"*)
      FETCH_HTTP_CODE="200"
      make_commits_json "abc123" "def456"
      return 0
      ;;
    */abc123/install.sh)
      FETCH_HTTP_CODE="200"
      make_install_sh "2.8.3"
      return 0
      ;;
    */def456/install.sh)
      FETCH_HTTP_CODE="200"
      make_install_sh "3.0.0"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="200"
      printf '{"tag_name": "v1.0.0"}'
      return 0
      ;;
  esac
}

# Mock: shell version not found anywhere (main + history)
mock_http_shell_not_found() {
  local url="$1"
  case "$url" in
    */main/install.sh)
      FETCH_HTTP_CODE="200"
      make_install_sh "3.0.1"
      return 0
      ;;
    *"/commits?path=install.sh"*)
      FETCH_HTTP_CODE="200"
      make_commits_json "abc123" "def456"
      return 0
      ;;
    */abc123/install.sh)
      FETCH_HTTP_CODE="200"
      make_install_sh "3.0.0"
      return 0
      ;;
    */def456/install.sh)
      FETCH_HTTP_CODE="200"
      make_install_sh "2.9.0"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="200"
      printf '{"tag_name": "v1.0.0"}'
      return 0
      ;;
  esac
}

# Mock: history list succeeds but one historical install.sh fetch fails.
mock_http_shell_history_fetch_fail() {
  local url="$1"
  case "$url" in
    */main/install.sh)
      FETCH_HTTP_CODE="200"
      make_install_sh "3.0.1"
      return 0
      ;;
    *"/commits?path=install.sh"*)
      FETCH_HTTP_CODE="200"
      make_commits_json "abc123" "def456"
      return 0
      ;;
    */abc123/install.sh)
      FETCH_HTTP_CODE="000"
      return 1
      ;;
    *)
      FETCH_HTTP_CODE="200"
      make_install_sh "2.8.3"
      return 0
      ;;
  esac
}

# Mock: xray release exists (valid)
mock_http_xray_valid() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v25.12.8"*)
      FETCH_HTTP_CODE="200"
      printf '{"tag_name": "v25.12.8"}'
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: nginx_build release with valid manifest
mock_http_nginx_build_valid() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      local manifest_content manifest_sha
      manifest_content=$(make_manifest_valid "2025.12.23")
      manifest_sha=$(compute_sha256_str "$manifest_content")
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$manifest_sha"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: nginx_build release WITHOUT SHA256SUMS asset in release JSON
mock_http_nginx_build_no_sha256sums_asset() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_no_sha256sums "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: SHA256SUMS download fails (network failure)
mock_http_nginx_build_sha256sums_network_fail() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="000"
      return 1
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: SHA256SUMS returns HTML instead of checksum content
mock_http_nginx_build_sha256sums_html() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      printf '%s' "$FIXTURE_HTML"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: SHA256SUMS x86 SHA does not match manifest
mock_http_nginx_build_sha256sums_x86_mismatch() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      local manifest_content manifest_sha
      manifest_content=$(make_manifest_valid "2025.12.23")
      manifest_sha=$(compute_sha256_str "$manifest_content")
      # x86 SHA intentionally wrong (cccc... instead of aaaa...)
      make_sha256sums \
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$manifest_sha"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: SHA256SUMS arm SHA does not match manifest
mock_http_nginx_build_sha256sums_arm_mismatch() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      local manifest_content manifest_sha
      manifest_content=$(make_manifest_valid "2025.12.23")
      manifest_sha=$(compute_sha256_str "$manifest_content")
      # arm SHA intentionally wrong (cccc... instead of bbbb...)
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
        "$manifest_sha"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: SHA256SUMS has a duplicate entry for x86 tarball
mock_http_nginx_build_sha256sums_duplicate() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      local manifest_content manifest_sha
      manifest_content=$(make_manifest_valid "2025.12.23")
      manifest_sha=$(compute_sha256_str "$manifest_content")
      # Duplicate x86 entry
      printf '%s  xray-nginx-custom-x86.tar.gz\n' \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      printf '%s  xray-nginx-custom-x86.tar.gz\n' \
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      printf '%s  xray-nginx-custom-arm.tar.gz\n' \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      printf '%s  release-manifest.json\n' "$manifest_sha"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: SHA256SUMS missing the x86 architecture entry
mock_http_nginx_build_sha256sums_missing_x86() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      local manifest_content manifest_sha
      manifest_content=$(make_manifest_valid "2025.12.23")
      manifest_sha=$(compute_sha256_str "$manifest_content")
      # x86 entry intentionally omitted
      printf '%s  xray-nginx-custom-arm.tar.gz\n' \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      printf '%s  release-manifest.json\n' "$manifest_sha"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: manifest x86 filename does not match canonical SHA256SUMS filename
mock_http_nginx_build_sha256sums_filename_mismatch() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_filename_mismatch "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_filename_mismatch "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      local manifest_content manifest_sha
      # SHA256SUMS lists the canonical filename, manifest lists MISMATCH filename
      manifest_content=$(make_manifest_filename_mismatch "2025.12.23")
      manifest_sha=$(compute_sha256_str "$manifest_content")
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$manifest_sha"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: SHA256SUMS release-manifest.json SHA does not match actual manifest content
mock_http_nginx_build_sha256sums_manifest_sha_wrong() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      # manifest SHA intentionally wrong (cccc... instead of real hash)
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: nginx_build release WITHOUT manifest asset
mock_http_nginx_build_no_manifest() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_no_manifest "2025.12.23"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: nginx_build release with manifest missing SHA
mock_http_nginx_build_no_sha() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_no_sha "2025.12.23"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: nginx_build release with manifest version mismatch
mock_http_nginx_build_version_mismatch() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_version_mismatch "2025.12.23" "2025.12.24"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

mock_http_nginx_build_release_no_arm() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_no_arm "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

mock_http_nginx_build_manifest_no_arm() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_no_arm "2025.12.23"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: nginx_build release returns HTML (not JSON)
mock_http_nginx_build_html() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      printf '%s' "$FIXTURE_HTML"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: nginx_build release is a DRAFT (draft=true). Must be rejected.
mock_http_nginx_build_draft_release() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_draft "2025.12.23"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: nginx_build release is a PRERELEASE (prerelease=true). Must be rejected.
mock_http_nginx_build_prerelease_release() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_prerelease "2025.12.23"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# Mock: generic tag/release exists (for nginx, openssl, jemalloc)
mock_http_tag_exists() {
  local url="$1"
  # Any releases/tags or git/refs/tags URL returns 200
  case "$url" in
    *"/releases/tags/"*|*"/git/refs/tags/"*)
      FETCH_HTTP_CODE="200"
      printf '{"tag_name": "v1.0.0"}'
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}

# ============================================================================
# P0-5: Default http_download_file mock.
# Delegates to the current http_get mock, capturing stdout to a temp file so
# that FETCH_HTTP_CODE (set in the current shell, not a subshell) is preserved.
# Writes the captured body to the requested output file.
# Individual test cases may override http_download_file for byte-exact scenarios
# (e.g., trailing-newline checksum tests).
# ============================================================================
http_download_file() {
  local url="$1"
  local output="$2"
  local tmp_capture
  tmp_capture=$(mktemp) || return 1
  http_get "$url" > "$tmp_capture"
  local rc=$?
  if [ $rc -ne 0 ] || [ ! -s "$tmp_capture" ]; then
    rm -f "$tmp_capture" "$output"
    return 1
  fi
  cp "$tmp_capture" "$output"
  rm -f "$tmp_capture"
  return 0
}

# ============================================================================
# Tests: Upstream verification (fail-closed)
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing upstream verification (fail-closed)"
echo "=============================================="
echo ""

# T01: Network failure → reject promotion
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_all_fail "$@"; }
OUTPUT=$(promote_component "xray" "25.12.8" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T01: network failure rejects promotion" "$EXIT_CODE"
# Verify files unchanged
assert_eq "T01: tested_versions.json unchanged" \
  "$(jq -S . "$REPO_DIR/tested_versions.json")" \
  "$(jq -S . "$TMPDIR_TEST/tested_versions.json")"
cleanup_temp_repo "$TMPDIR_TEST"

# T02: API rate limited (403) → reject promotion
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_rate_limited "$@"; }
OUTPUT=$(promote_component "xray" "25.12.8" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T02: API rate limit (403) rejects promotion" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T03: HTML response instead of JSON → reject promotion
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_html "$@"; }
OUTPUT=$(promote_component "xray" "25.12.8" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T03: HTML response rejects promotion" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T04: Shell install.sh fetch failure → reject promotion
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_shell_fetch_fail "$@"; }
OUTPUT=$(promote_component "shell" "2.8.3" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T04: shell fetch failure rejects promotion" "$EXIT_CODE"
assert_contains "T04: error mentions fetch failure" "fetch" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T05: Shell version not found (not in main, not in history) → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_shell_not_found "$@"; }
OUTPUT=$(promote_component "shell" "2.8.3" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T05: shell version not found rejects promotion" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T06: Tag not found (404) → reject promotion
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_tag_not_found "$@"; }
OUTPUT=$(promote_component "xray" "99.99.99" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T06: tag not found (404) rejects promotion" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T06b: Any historical shell fetch failure makes verification inconclusive.
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_shell_history_fetch_fail "$@"; }
OUTPUT=$(promote_component "shell" "2.8.3" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T06b: historical shell fetch failure rejects promotion" "$EXIT_CODE"
assert_contains "T06b: error mentions failed historical fetch" "could not fetch" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T07: nginx_build release missing manifest → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_no_manifest "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T07: nginx_build missing manifest rejects" "$EXIT_CODE"
assert_contains "T07: error mentions manifest" "manifest" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T08: nginx_build manifest missing SHA → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_no_sha "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T08: manifest missing SHA rejects" "$EXIT_CODE"
assert_contains "T08: error mentions sha256" "sha256" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T09: nginx_build manifest version mismatch → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_version_mismatch "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T09: manifest version mismatch rejects" "$EXIT_CODE"
assert_contains "T09: error mentions version" "version" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T10: nginx_build release returns HTML → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_html "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T10: nginx_build HTML response rejects" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_release_no_arm "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T10b: release missing arm asset rejects" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_manifest_no_arm "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T10c: manifest missing arm contract rejects" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T10d: nginx_build release marked as DRAFT → reject
# Even with all required assets present, a draft release must never be promoted
# to tested_version. GitHub's /releases/tags/<tag> endpoint returns drafts, so
# the promotion script must explicitly reject them (fail-closed).
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_draft_release "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T10d: draft release rejects" "$EXIT_CODE"
assert_contains "T10d: error mentions draft" "draft" "$OUTPUT"
# Verify files unchanged
assert_eq "T10d: tested_versions.json unchanged" \
  "$(jq -S . "$REPO_DIR/tested_versions.json")" \
  "$(jq -S . "$TMPDIR_TEST/tested_versions.json")"
cleanup_temp_repo "$TMPDIR_TEST"

# T10e: nginx_build release marked as PRERELEASE → reject
# A prerelease is not a stable published release and must not be promoted.
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_prerelease_release "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T10e: prerelease release rejects" "$EXIT_CODE"
assert_contains "T10e: error mentions prerelease" "prerelease" "$OUTPUT"
# Verify files unchanged
assert_eq "T10e: tested_versions.json unchanged" \
  "$(jq -S . "$REPO_DIR/tested_versions.json")" \
  "$(jq -S . "$TMPDIR_TEST/tested_versions.json")"
cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: Successful promotions (verify correct behavior)
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing successful promotions"
echo "=============================================="
echo ""

# T11: Shell version found in main → promote successfully
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_shell_in_main "$@"; }
OUTPUT=$(promote_component "shell" "2.8.3" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T11: shell in main promotes successfully" "$EXIT_CODE"
# Verify tested_version updated
SHELL_TESTED=$(jq -r '.shell' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T11: shell tested_versions.json updated" "2.8.3" "$SHELL_TESTED"
SHELL_LONG=$(jq -r '.shell_tested_version' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T11: shell xray_shell_versions.json updated" "2.8.3" "$SHELL_LONG"
cleanup_temp_repo "$TMPDIR_TEST"

# T12: Shell version found in historical commit → promote successfully
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_shell_in_history "$@"; }
OUTPUT=$(promote_component "shell" "2.8.3" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T12: shell in history promotes successfully" "$EXIT_CODE"
SHELL_TESTED=$(jq -r '.shell' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T12: shell tested_versions.json updated" "2.8.3" "$SHELL_TESTED"
cleanup_temp_repo "$TMPDIR_TEST"

# T13: Xray tag exists → promote successfully
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_valid "$@"; }
OUTPUT=$(promote_component "xray" "25.12.8" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T13: xray tag exists promotes successfully" "$EXIT_CODE"
XRAY_TESTED=$(jq -r '.xray' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T13: xray tested_versions.json updated" "25.12.8" "$XRAY_TESTED"
cleanup_temp_repo "$TMPDIR_TEST"

# T14: nginx_build with valid manifest → promote successfully
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_valid "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T14: nginx_build valid manifest promotes" "$EXIT_CODE"
NGINX_BUILD_TESTED=$(jq -r '.nginx_build' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T14: nginx_build tested updated" "2025.12.23" "$NGINX_BUILD_TESTED"
cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: SHA256SUMS consistency verification (P1-A)
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing SHA256SUMS consistency (P1-A)"
echo "=============================================="
echo ""

# T14a: nginx_build with valid SHA256SUMS (matches manifest) → promotes
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_valid "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T14a: valid SHA256SUMS promotes" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T14b: SHA256SUMS asset missing from release JSON → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_no_sha256sums_asset "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14b: SHA256SUMS asset missing rejects" "$EXIT_CODE"
assert_contains "T14b: error mentions SHA256SUMS" "SHA256SUMS" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14c: SHA256SUMS download network failure → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_sha256sums_network_fail "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14c: SHA256SUMS network failure rejects" "$EXIT_CODE"
assert_contains "T14c: error mentions SHA256SUMS download" "SHA256SUMS" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14d: SHA256SUMS returns HTML → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_sha256sums_html "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14d: SHA256SUMS HTML rejects" "$EXIT_CODE"
assert_contains "T14d: error mentions HTML" "HTML" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14e: SHA256SUMS x86 SHA mismatch → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_sha256sums_x86_mismatch "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14e: SHA256SUMS x86 SHA mismatch rejects" "$EXIT_CODE"
assert_contains "T14e: error mentions x86 SHA mismatch" "x86" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14f: SHA256SUMS arm SHA mismatch → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_sha256sums_arm_mismatch "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14f: SHA256SUMS arm SHA mismatch rejects" "$EXIT_CODE"
assert_contains "T14f: error mentions arm SHA mismatch" "arm" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14g: SHA256SUMS duplicate entry → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_sha256sums_duplicate "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14g: SHA256SUMS duplicate entry rejects" "$EXIT_CODE"
assert_contains "T14g: error mentions entries" "entries" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14h: SHA256SUMS missing x86 architecture entry → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_sha256sums_missing_x86 "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14h: SHA256SUMS missing x86 entry rejects" "$EXIT_CODE"
assert_contains "T14h: error mentions missing entry" "missing" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14i: manifest filename does not match SHA256SUMS canonical filename → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_sha256sums_filename_mismatch "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14i: filename mismatch with manifest rejects" "$EXIT_CODE"
assert_contains "T14i: error mentions filename" "filename" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14j: SHA256SUMS release-manifest.json SHA record wrong → reject
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_sha256sums_manifest_sha_wrong "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14j: manifest SHA record wrong rejects" "$EXIT_CODE"
assert_contains "T14j: error mentions release-manifest.json SHA" "release-manifest.json" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# P0-5: Byte-exact manifest file SHA tests (trailing newline scenarios)
# Tests that the script computes SHA over the actual downloaded file bytes,
# NOT over a shell variable that lost its trailing newline via $(...).
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing P0-5 byte-exact manifest SHA"
echo "=============================================="
echo ""

# T14k: manifest file WITH trailing newline, SHA256SUMS SHA over WITH-newline → promotes
# Proves that a real Release asset ending in \n (common) passes when SHA is
# computed over file bytes (not shell-stripped variable).
TMPDIR_TEST=$(setup_temp_repo)
T14K_CONTENT=$(make_manifest_valid "2025.12.23")
T14K_SHA=$(compute_sha256_content_as_file "$T14K_CONTENT" "yes")
http_get() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      printf '\n'
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$T14K_SHA"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T14k: manifest with trailing newline promotes (byte-exact SHA)" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T14l: manifest file WITHOUT trailing newline, SHA256SUMS SHA over NO-newline → promotes
# Proves that a Release asset with no trailing \n also passes.
TMPDIR_TEST=$(setup_temp_repo)
T14L_CONTENT=$(make_manifest_valid "2025.12.23")
T14L_SHA=$(compute_sha256_content_as_file "$T14L_CONTENT" "no")
http_get() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$T14L_SHA"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T14l: manifest without trailing newline promotes (byte-exact SHA)" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T14m: SHA256SUMS file itself WITH trailing newline → promotes
# Proves that a trailing newline in SHA256SUMS (common) doesn't break awk parsing.
TMPDIR_TEST=$(setup_temp_repo)
T14M_CONTENT=$(make_manifest_valid "2025.12.23")
T14M_SHA=$(compute_sha256_content_as_file "$T14M_CONTENT" "no")
http_get() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$T14M_SHA"
      printf '\n'
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T14m: SHA256SUMS with trailing newline promotes" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T14n: manifest file WITH trailing newline, SHA256SUMS SHA over NO-newline → reject
# P0-5 core bug scenario: if SHA were computed via $(http_get) (which strips \n),
# the digest would match SHA256SUMS (also stripped). But the file on disk STILL
# has the \n, so file-based SHA correctly detects the mismatch and rejects.
TMPDIR_TEST=$(setup_temp_repo)
T14N_CONTENT=$(make_manifest_valid "2025.12.23")
T14N_STRIPPED_SHA=$(compute_sha256_content_as_file "$T14N_CONTENT" "no")
http_get() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      printf '\n'
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$T14N_STRIPPED_SHA"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14n: manifest WITH newline + SHA256SUMS stripped SHA rejects" "$EXIT_CODE"
assert_contains "T14n: error mentions manifest file bytes" "manifest file bytes" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14o: manifest file WITHOUT trailing newline, SHA256SUMS SHA over WITH-newline → reject
# Mirror of T14n: file has no \n, but SHA256SUMS has SHA of content WITH \n.
TMPDIR_TEST=$(setup_temp_repo)
T14O_CONTENT=$(make_manifest_valid "2025.12.23")
T14O_WITH_NL_SHA=$(compute_sha256_content_as_file "$T14O_CONTENT" "yes")
http_get() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$T14O_WITH_NL_SHA"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14o: manifest WITHOUT newline + SHA256SUMS with-newline SHA rejects" "$EXIT_CODE"
assert_contains "T14o: error mentions manifest file bytes" "manifest file bytes" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14p: manifest file with TWO trailing newlines, SHA256SUMS SHA over ONE-newline → reject
# Proves that ANY byte difference (even an extra \n) is detected.
TMPDIR_TEST=$(setup_temp_repo)
T14P_CONTENT=$(make_manifest_valid "2025.12.23")
T14P_ONE_NL_SHA=$(compute_sha256_content_as_file "$T14P_CONTENT" "yes")
http_get() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      make_manifest_valid "2025.12.23"
      printf '\n\n'
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "$T14P_ONE_NL_SHA"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14p: manifest with two newlines + SHA256SUMS one-newline SHA rejects" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T14q: manifest download returns HTML → reject
# Proves that HTML content written to manifest_file is caught by is_valid_json.
TMPDIR_TEST=$(setup_temp_repo)
http_get() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      printf '%s' "$FIXTURE_HTML"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14q: manifest download HTML rejects" "$EXIT_CODE"
assert_contains "T14q: error mentions not valid JSON" "not valid JSON" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14r: manifest download returns empty file → reject
# Proves that empty manifest content is caught by http_download_file's non-empty check.
TMPDIR_TEST=$(setup_temp_repo)
http_get() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="200"
      return 0
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14r: manifest download empty file rejects" "$EXIT_CODE"
assert_contains "T14r: error mentions manifest download" "manifest" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# T14s: manifest download network failure → reject
# Proves that manifest download failure (HTTP 000) is caught and rejected.
TMPDIR_TEST=$(setup_temp_repo)
http_get() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v2025.12.23"*)
      FETCH_HTTP_CODE="200"
      make_nginx_build_release_json "2025.12.23"
      return 0
      ;;
    *"/manifest_2025.12.23.json"*)
      FETCH_HTTP_CODE="000"
      return 1
      ;;
    *"/SHA256SUMS"*)
      FETCH_HTTP_CODE="200"
      make_sha256sums \
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T14s: manifest download network failure rejects" "$EXIT_CODE"
assert_contains "T14s: error mentions manifest download" "manifest" "$OUTPUT"
cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: Only target component modified
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing only target component modified"
echo "=============================================="
echo ""

# T15: Promote xray → only xray fields change, all others unchanged
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_valid "$@"; }

# Save original state
OLD_TESTED_SNAPSHOT=$(jq -S . "$TMPDIR_TEST/tested_versions.json")
OLD_VERSIONS_SNAPSHOT=$(jq -S . "$TMPDIR_TEST/xray_shell_versions.json")

# Promote xray to a NEW version (99.99.99) — need mock that accepts it
mock_http_xray_new_version() {
  local url="$1"
  case "$url" in
    *"/releases/tags/v99.99.99"*)
      FETCH_HTTP_CODE="200"
      printf '{"tag_name": "v99.99.99"}'
      return 0
      ;;
    *)
      FETCH_HTTP_CODE="404"
      return 1
      ;;
  esac
}
http_get() { mock_http_xray_new_version "$@"; }

OUTPUT=$(promote_component "xray" "99.99.99" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T15: xray promoted to 99.99.99" "$EXIT_CODE"

# Check tested_versions.json: only xray changed
NEW_XRAY=$(jq -r '.xray' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T15: xray in tested_versions.json is 99.99.99" "99.99.99" "$NEW_XRAY"

OLD_SHELL=$(printf '%s' "$OLD_TESTED_SNAPSHOT" | jq -r '.shell')
NEW_SHELL=$(jq -r '.shell' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T15: shell unchanged in tested_versions.json" "$OLD_SHELL" "$NEW_SHELL"

OLD_NGINX=$(printf '%s' "$OLD_TESTED_SNAPSHOT" | jq -r '.nginx')
NEW_NGINX=$(jq -r '.nginx' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T15: nginx unchanged in tested_versions.json" "$OLD_NGINX" "$NEW_NGINX"

OLD_OPENSSL=$(printf '%s' "$OLD_TESTED_SNAPSHOT" | jq -r '.openssl')
NEW_OPENSSL=$(jq -r '.openssl' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T15: openssl unchanged in tested_versions.json" "$OLD_OPENSSL" "$NEW_OPENSSL"

OLD_JEMALLOC=$(printf '%s' "$OLD_TESTED_SNAPSHOT" | jq -r '.jemalloc')
NEW_JEMALLOC=$(jq -r '.jemalloc' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T15: jemalloc unchanged in tested_versions.json" "$OLD_JEMALLOC" "$NEW_JEMALLOC"

OLD_NGINX_BUILD=$(printf '%s' "$OLD_TESTED_SNAPSHOT" | jq -r '.nginx_build')
NEW_NGINX_BUILD=$(jq -r '.nginx_build' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T15: nginx_build unchanged in tested_versions.json" "$OLD_NGINX_BUILD" "$NEW_NGINX_BUILD"

# Check xray_shell_versions.json: only xray_tested_version/at changed
NEW_XRAY_LONG=$(jq -r '.xray_tested_version' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T15: xray_tested_version updated in versions" "99.99.99" "$NEW_XRAY_LONG"

OLD_SHELL_TESTED=$(printf '%s' "$OLD_VERSIONS_SNAPSHOT" | jq -r '.shell_tested_version')
NEW_SHELL_TESTED=$(jq -r '.shell_tested_version' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T15: shell_tested_version unchanged in versions" "$OLD_SHELL_TESTED" "$NEW_SHELL_TESTED"

OLD_NGINX_TESTED=$(printf '%s' "$OLD_VERSIONS_SNAPSHOT" | jq -r '.nginx_tested_version')
NEW_NGINX_TESTED=$(jq -r '.nginx_tested_version' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T15: nginx_tested_version unchanged in versions" "$OLD_NGINX_TESTED" "$NEW_NGINX_TESTED"

cleanup_temp_repo "$TMPDIR_TEST"

# T16: Full snapshot comparison — filtered (non-target) fields must be identical
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }

OLD_FILTERED=$(jq -S --arg c "xray" 'del(.[$c])' "$TMPDIR_TEST/tested_versions.json")
promote_component "xray" "99.99.99" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null
EXIT_CODE=$?
NEW_FILTERED=$(jq -S --arg c "xray" 'del(.[$c])' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T16: non-target fields in tested_versions.json unchanged" "$OLD_FILTERED" "$NEW_FILTERED"

# Same check for xray_shell_versions.json
OLD_VF=$(jq -S --arg tv "xray_tested_version" --arg ta "xray_tested_at" --arg tn "xray_tested_note" \
  'del(.[$tv], .[$ta], .[$tn])' "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null)
# We need to get the old snapshot BEFORE promotion for this to be meaningful
# Let's redo this test properly
cleanup_temp_repo "$TMPDIR_TEST"

TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }

# Save snapshots before promotion
SNAP_TESTED=$(mktemp)
SNAP_VERSIONS=$(mktemp)
cp "$TMPDIR_TEST/tested_versions.json" "$SNAP_TESTED"
cp "$TMPDIR_TEST/xray_shell_versions.json" "$SNAP_VERSIONS"

promote_component "xray" "99.99.99" "test note" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null

# Compare non-target fields in tested_versions.json
OLD_F=$(jq -S --arg c "xray" 'del(.[$c])' "$SNAP_TESTED")
NEW_F=$(jq -S --arg c "xray" 'del(.[$c])' "$TMPDIR_TEST/tested_versions.json")
assert_eq "T16: tested_versions.json non-target fields unchanged" "$OLD_F" "$NEW_F"

# Compare non-target fields in xray_shell_versions.json
OLD_VF=$(jq -S \
  --arg tv "xray_tested_version" --arg ta "xray_tested_at" --arg tn "xray_tested_note" \
  'del(.[$tv], .[$ta], .[$tn])' "$SNAP_VERSIONS")
NEW_VF=$(jq -S \
  --arg tv "xray_tested_version" --arg ta "xray_tested_at" --arg tn "xray_tested_note" \
  'del(.[$tv], .[$ta], .[$tn])' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T16: versions.json non-target fields unchanged" "$OLD_VF" "$NEW_VF"

rm -f "$SNAP_TESTED" "$SNAP_VERSIONS"
cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: Online fields never modified
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing online fields never modified"
echo "=============================================="
echo ""

# T17: After successful promotion, ALL online_version fields are unchanged
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }

# Save all online version values
OLD_ONLINE_SHELL=$(jq -r '.shell_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
OLD_ONLINE_XRAY=$(jq -r '.xray_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
OLD_ONLINE_NGINX=$(jq -r '.nginx_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
OLD_ONLINE_OPENSSL=$(jq -r '.openssl_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
OLD_ONLINE_JEMALLOC=$(jq -r '.jemalloc_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
OLD_ONLINE_NGINX_BUILD=$(jq -r '.nginx_build_online_version' "$TMPDIR_TEST/xray_shell_versions.json")

promote_component "xray" "99.99.99" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null
EXIT_CODE=$?
assert_promoted "T17: promotion succeeded" "$EXIT_CODE"

NEW_ONLINE_SHELL=$(jq -r '.shell_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
NEW_ONLINE_XRAY=$(jq -r '.xray_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
NEW_ONLINE_NGINX=$(jq -r '.nginx_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
NEW_ONLINE_OPENSSL=$(jq -r '.openssl_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
NEW_ONLINE_JEMALLOC=$(jq -r '.jemalloc_online_version' "$TMPDIR_TEST/xray_shell_versions.json")
NEW_ONLINE_NGINX_BUILD=$(jq -r '.nginx_build_online_version' "$TMPDIR_TEST/xray_shell_versions.json")

assert_eq "T17: shell_online_version unchanged" "$OLD_ONLINE_SHELL" "$NEW_ONLINE_SHELL"
assert_eq "T17: xray_online_version unchanged" "$OLD_ONLINE_XRAY" "$NEW_ONLINE_XRAY"
assert_eq "T17: nginx_online_version unchanged" "$OLD_ONLINE_NGINX" "$NEW_ONLINE_NGINX"
assert_eq "T17: openssl_online_version unchanged" "$OLD_ONLINE_OPENSSL" "$NEW_ONLINE_OPENSSL"
assert_eq "T17: jemalloc_online_version unchanged" "$OLD_ONLINE_JEMALLOC" "$NEW_ONLINE_JEMALLOC"
assert_eq "T17: nginx_build_online_version unchanged" "$OLD_ONLINE_NGINX_BUILD" "$NEW_ONLINE_NGINX_BUILD"

cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: Note handling
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing note handling"
echo "=============================================="
echo ""

# T18: Note is stored in the correct component's note field only
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }

promote_component "xray" "99.99.99" "verified in CI" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null
EXIT_CODE=$?
assert_promoted "T18: promotion with note succeeded" "$EXIT_CODE"

XRAY_NOTE=$(jq -r '.xray_tested_note // empty' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T18: xray_tested_note set correctly" "verified in CI" "$XRAY_NOTE"

# Verify other components' note fields are NOT set (or unchanged)
SHELL_NOTE=$(jq -r '.shell_tested_note // empty' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T18: shell_tested_note not set" "" "$SHELL_NOTE"

NGINX_NOTE=$(jq -r '.nginx_tested_note // empty' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T18: nginx_tested_note not set" "" "$NGINX_NOTE"

cleanup_temp_repo "$TMPDIR_TEST"

# T19: Note with newlines and control characters → sanitized
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }

# Note with newline, tab, and other control characters
DIRTY_NOTE=$(printf 'line1\nline2\ttab\x01\x02control')
promote_component "xray" "99.99.99" "$DIRTY_NOTE" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null
EXIT_CODE=$?
assert_promoted "T19: promotion with dirty note succeeded" "$EXIT_CODE"

XRAY_NOTE=$(jq -r '.xray_tested_note // empty' "$TMPDIR_TEST/xray_shell_versions.json")
# Control chars should be stripped (newline, tab, 0x01, 0x02 removed)
assert_not_contains "T19: note has no newline" $'\n' "$XRAY_NOTE"
assert_not_contains "T19: note has no tab" $'\t' "$XRAY_NOTE"
assert_not_contains "T19: note has no 0x01" $'\x01' "$XRAY_NOTE"
assert_not_contains "T19: note has no 0x02" $'\x02' "$XRAY_NOTE"
# Content should be preserved (stripped)
assert_contains "T19: note preserves line1" "line1" "$XRAY_NOTE"
assert_contains "T19: note preserves line2tab" "line2tab" "$XRAY_NOTE"
assert_contains "T19: note preserves control" "control" "$XRAY_NOTE"

cleanup_temp_repo "$TMPDIR_TEST"

# T20: Note length is limited (over 500 chars → truncated)
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }

# Create a note longer than 500 chars
LONG_NOTE=$(printf 'a%.0s' {1..600})
promote_component "xray" "99.99.99" "$LONG_NOTE" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null
EXIT_CODE=$?
assert_promoted "T20: promotion with long note succeeded" "$EXIT_CODE"

XRAY_NOTE=$(jq -r '.xray_tested_note // empty' "$TMPDIR_TEST/xray_shell_versions.json")
NOTE_LEN=${#XRAY_NOTE}
if [ "$NOTE_LEN" -le 500 ]; then
  pass "T20: note length limited to 500 (actual: $NOTE_LEN)"
else
  fail "T20: note length should be <= 500 but is $NOTE_LEN"
fi

cleanup_temp_repo "$TMPDIR_TEST"

# T21: Empty note → no note field set
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }

promote_component "xray" "99.99.99" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null
EXIT_CODE=$?
assert_promoted "T21: promotion with empty note succeeded" "$EXIT_CODE"

XRAY_NOTE=$(jq -r '.xray_tested_note // empty' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T21: no note field set" "" "$XRAY_NOTE"

# But tested_at should still be set
XRAY_AT=$(jq -r '.xray_tested_at // empty' "$TMPDIR_TEST/xray_shell_versions.json")
if [ -n "$XRAY_AT" ]; then
  pass "T21: xray_tested_at is set"
else
  fail "T21: xray_tested_at should be set"
fi

cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: Rollback on failure (both JSON files restored)
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing rollback on failure"
echo "=============================================="
echo ""

# T22: Failed upstream verification → both files unchanged (pre-modification)
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_all_fail "$@"; }

# Save original checksums
OLD_TESTED_HASH=$(jq -S . "$TMPDIR_TEST/tested_versions.json" | md5)
OLD_VERSIONS_HASH=$(jq -S . "$TMPDIR_TEST/xray_shell_versions.json" | md5)

promote_component "xray" "25.12.8" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null
EXIT_CODE=$?
assert_rejected "T22: promotion rejected" "$EXIT_CODE"

NEW_TESTED_HASH=$(jq -S . "$TMPDIR_TEST/tested_versions.json" | md5)
NEW_VERSIONS_HASH=$(jq -S . "$TMPDIR_TEST/xray_shell_versions.json" | md5)
assert_eq "T22: tested_versions.json restored" "$OLD_TESTED_HASH" "$NEW_TESTED_HASH"
assert_eq "T22: xray_shell_versions.json restored" "$OLD_VERSIONS_HASH" "$NEW_VERSIONS_HASH"

cleanup_temp_repo "$TMPDIR_TEST"

# T23: Inconsistent files → consistency check fails → both files restored
# Create inconsistent fixture: tested_versions.json has xray=25.12.8
# but xray_shell_versions.json has xray_tested_version=25.12.7
TMPDIR_TEST=$(setup_temp_repo)

# Make the files inconsistent
jq '.xray_tested_version = "25.12.7"' "$TMPDIR_TEST/xray_shell_versions.json" > "$TMPDIR_TEST/xray_shell_versions.json.tmp"
mv "$TMPDIR_TEST/xray_shell_versions.json.tmp" "$TMPDIR_TEST/xray_shell_versions.json"

http_get() { mock_http_tag_exists "$@"; }

# Save original (inconsistent) state
OLD_TESTED_HASH=$(jq -S . "$TMPDIR_TEST/tested_versions.json" | md5)
OLD_VERSIONS_HASH=$(jq -S . "$TMPDIR_TEST/xray_shell_versions.json" | md5)

# Promote nginx — should fail at consistency check because xray is inconsistent
OUTPUT=$(promote_component "nginx" "1.28.1" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T23: inconsistent files rejected" "$EXIT_CODE"
assert_contains "T23: error mentions consistency" "consistency" "$OUTPUT"

# Verify both files restored to original (inconsistent) state
NEW_TESTED_HASH=$(jq -S . "$TMPDIR_TEST/tested_versions.json" | md5)
NEW_VERSIONS_HASH=$(jq -S . "$TMPDIR_TEST/xray_shell_versions.json" | md5)
assert_eq "T23: tested_versions.json restored after consistency fail" "$OLD_TESTED_HASH" "$NEW_TESTED_HASH"
assert_eq "T23: xray_shell_versions.json restored after consistency fail" "$OLD_VERSIONS_HASH" "$NEW_VERSIONS_HASH"

cleanup_temp_repo "$TMPDIR_TEST"

# T24: Promote same version as current → succeeds (idempotent, no change to tested)
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_valid "$@"; }

OLD_TESTED_HASH=$(jq -S . "$TMPDIR_TEST/tested_versions.json" | md5)
promote_component "xray" "25.12.8" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null
EXIT_CODE=$?
assert_promoted "T24: promote same version succeeds" "$EXIT_CODE"

# tested_versions.json should be unchanged (same version)
NEW_TESTED_HASH=$(jq -S . "$TMPDIR_TEST/tested_versions.json" | md5)
# Note: xray_shell_versions.json WILL change (tested_at is updated)
# but tested_versions.json should be byte-identical
assert_eq "T24: tested_versions.json unchanged (same version)" "$OLD_TESTED_HASH" "$NEW_TESTED_HASH"

cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: Two JSON files consistency
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing two JSON files consistency"
echo "=============================================="
echo ""

# T25: After promotion, both files agree on tested_version for ALL components
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }

promote_component "xray" "99.99.99" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null

ALL_CONSISTENT=true
for comp in shell xray nginx openssl jemalloc nginx_build; do
  short_val=$(jq -r --arg c "$comp" '.[$c]' "$TMPDIR_TEST/tested_versions.json")
  long_val=$(jq -r ".${comp}_tested_version" "$TMPDIR_TEST/xray_shell_versions.json")
  if [ "$short_val" != "$long_val" ]; then
    fail "T25: $comp inconsistent: tested_versions.json=$short_val != versions=${comp}_tested_version=$long_val"
    ALL_CONSISTENT=false
  fi
done
if $ALL_CONSISTENT; then
  pass "T25: all components consistent between both files"
fi

cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: Input validation
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing input validation"
echo "=============================================="
echo ""

# T26: Invalid component → reject
TMPDIR_TEST=$(setup_temp_repo)
OUTPUT=$(promote_component "invalid_component" "1.0.0" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T26: invalid component rejected" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T27: Invalid version format → reject
TMPDIR_TEST=$(setup_temp_repo)
OUTPUT=$(promote_component "xray" "not-a-version" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T27: invalid version format rejected" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T28: Empty version → reject
TMPDIR_TEST=$(setup_temp_repo)
OUTPUT=$(promote_component "xray" "" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T28: empty version rejected" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T29: null version → reject
TMPDIR_TEST=$(setup_temp_repo)
OUTPUT=$(promote_component "xray" "null" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T29: null version rejected" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T30: undefined version → reject
TMPDIR_TEST=$(setup_temp_repo)
OUTPUT=$(promote_component "xray" "undefined" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T30: undefined version rejected" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T31: Version with injection attempt → reject
TMPDIR_TEST=$(setup_temp_repo)
OUTPUT=$(promote_component "xray" "1.0.0; rm -rf /" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_rejected "T31: version with injection rejected" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# T32: nginx_build version format (date-based) → valid
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_nginx_build_valid "$@"; }
OUTPUT=$(promote_component "nginx_build" "2025.12.23" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>&1)
EXIT_CODE=$?
assert_promoted "T32: nginx_build date version valid" "$EXIT_CODE"
cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: tested_version field preservation
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing tested_version field preservation"
echo "=============================================="
echo ""

# T33: tested_version field exists and is non-null for all components
TMPDIR_TEST=$(setup_temp_repo)
ALL_OK=true
for comp in shell xray nginx openssl jemalloc nginx_build; do
  val=$(jq -r --arg c "$comp" '.[$c] // empty' "$TMPDIR_TEST/tested_versions.json")
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    fail "T33: tested_versions.json: $comp is missing/null"
    ALL_OK=false
  fi
  val_long=$(jq -r ".${comp}_tested_version // empty" "$TMPDIR_TEST/xray_shell_versions.json")
  if [ -z "$val_long" ] || [ "$val_long" = "null" ]; then
    fail "T33: xray_shell_versions.json: ${comp}_tested_version is missing/null"
    ALL_OK=false
  fi
done
if $ALL_OK; then
  pass "T33: all tested_version fields exist and are non-null"
fi
cleanup_temp_repo "$TMPDIR_TEST"

# T34: tested_version field NOT renamed or deleted after promotion
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }
promote_component "xray" "99.99.99" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null

# Verify all expected keys still exist
KEYS_OK=true
for comp in shell xray nginx openssl jemalloc nginx_build; do
  if ! jq -e --arg c "$comp" 'has($c)' "$TMPDIR_TEST/tested_versions.json" >/dev/null 2>&1; then
    fail "T34: tested_versions.json missing key: $comp"
    KEYS_OK=false
  fi
  if ! jq -e --arg k "${comp}_tested_version" 'has($k)' "$TMPDIR_TEST/xray_shell_versions.json" >/dev/null 2>&1; then
    fail "T34: xray_shell_versions.json missing key: ${comp}_tested_version"
    KEYS_OK=false
  fi
done
if $KEYS_OK; then
  pass "T34: all tested_version keys preserved after promotion"
fi
cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: Old bulk-copy workflow not restored
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing old bulk-copy workflow not restored"
echo "=============================================="
echo ""

# T35: Old update_tested_versions.yml must NOT exist
if [ ! -f "$REPO_DIR/.github/workflows/update_tested_versions.yml" ]; then
  pass "T35: old bulk-copy workflow (update_tested_versions.yml) does not exist"
else
  fail "T35: update_tested_versions.yml still exists (should be removed)"
fi

# T36: promote_tested_version.yml exists (single-component promotion)
if [ -f "$REPO_DIR/.github/workflows/promote_tested_version.yml" ]; then
  pass "T36: promote_tested_version.yml exists"
else
  fail "T36: promote_tested_version.yml is missing"
fi

# T37: promote_tested_version.sh script exists
if [ -f "$REPO_DIR/.github/scripts/promote_tested_version.sh" ]; then
  pass "T37: promote_tested_version.sh script exists"
else
  fail "T37: promote_tested_version.sh script is missing"
fi

# T38: Workflow does NOT use @main or @master for third-party actions
if grep -qE 'uses:.*@main\b' "$REPO_DIR/.github/workflows/promote_tested_version.yml" 2>/dev/null; then
  fail "T38: workflow still uses @main for actions"
else
  pass "T38: workflow does not use @main for actions"
fi

if grep -qE 'uses:.*@master\b' "$REPO_DIR/.github/workflows/promote_tested_version.yml" 2>/dev/null; then
  fail "T38b: workflow uses @master for actions"
else
  pass "T38b: workflow does not use @master for actions"
fi

# ============================================================================
# Tests: jq empty validation
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing jq empty validation"
echo "=============================================="
echo ""

# T39: Both JSON files pass jq empty after successful promotion
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }
promote_component "xray" "99.99.99" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null

if jq empty "$TMPDIR_TEST/tested_versions.json" 2>/dev/null; then
  pass "T39: tested_versions.json passes jq empty after promotion"
else
  fail "T39: tested_versions.json fails jq empty after promotion"
fi

if jq empty "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null; then
  pass "T39b: xray_shell_versions.json passes jq empty after promotion"
else
  fail "T39b: xray_shell_versions.json fails jq empty after promotion"
fi

cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Tests: tested_at field
# ============================================================================

echo ""
echo "=============================================="
echo "  Testing tested_at field"
echo "=============================================="
echo ""

# T40: tested_at is set for the promoted component only
TMPDIR_TEST=$(setup_temp_repo)
http_get() { mock_http_xray_new_version "$@"; }
promote_component "xray" "99.99.99" "" "$TMPDIR_TEST/tested_versions.json" "$TMPDIR_TEST/xray_shell_versions.json" 2>/dev/null

XRAY_AT=$(jq -r '.xray_tested_at // empty' "$TMPDIR_TEST/xray_shell_versions.json")
if [ -n "$XRAY_AT" ]; then
  pass "T40: xray_tested_at is set"
else
  fail "T40: xray_tested_at should be set"
fi

# Verify tested_at is not set for other components (or unchanged)
SHELL_AT=$(jq -r '.shell_tested_at // empty' "$TMPDIR_TEST/xray_shell_versions.json")
assert_eq "T40b: shell_tested_at not set by xray promotion" "" "$SHELL_AT"

cleanup_temp_repo "$TMPDIR_TEST"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "=========================================="
printf "Total: %d, ${GREEN}Pass: %d${NC}, ${RED}Fail: %d${NC}\n" $((PASS + FAIL)) "$PASS" "$FAIL"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
