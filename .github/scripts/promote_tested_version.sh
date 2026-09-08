#!/usr/bin/env bash
# promote_tested_version.sh
#
# Single-component controlled promotion of tested_version.
#
# This script is intended to be SOURCED by the workflow and the test suite.
# It exposes pure functions for testability.
#
# Fail-closed principle: any upstream verification failure (network error,
# API rate limit, HTML response, missing tag/release, missing manifest,
# SHA mismatch, version mismatch) aborts the promotion.
#
# Online_version is NEVER auto-copied to tested_version. Only an explicit
# human-triggered promotion via this script updates tested_version.
#
# Each promotion updates exactly ONE component. All other tested fields,
# online fields, and metadata must remain unchanged.
#
# Requirements: bash 3.2+, jq
# Compatible with macOS (BSD sed, bash 3.2, no mapfile/readarray)

# Default config (overridable via env for testing)
CURL_BIN="${CURL_BIN:-curl}"
JQ_BIN="${JQ_BIN:-jq}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
SHELL_REPO="${SHELL_REPO:-hello-yunshu/Xray_bash_onekey}"
SHELL_RELEASE_API_BASE="${SHELL_RELEASE_API_BASE:-https://api.github.com/repos/${SHELL_REPO}}"
NGINX_BUILD_REPO="${NGINX_BUILD_REPO:-hello-yunshu/Xray_bash_onekey_Nginx}"
NOTE_MAX_LENGTH="${NOTE_MAX_LENGTH:-500}"

# Global: last HTTP fetch status code ("000" = network failure)
FETCH_HTTP_CODE=""

# ============================================================================
# HTTP helpers (overridable for tests)
# ============================================================================

# Fetch a URL via HTTP.
# Sets FETCH_HTTP_CODE ("000" = network failure, "200" = OK, etc.)
# Outputs body on stdout.
# Returns 0 on HTTP 200, 1 otherwise.
#
# WARNING: callers that capture via $(http_get ...) will lose trailing
# newlines due to shell command substitution. For resources whose SHA256
# must match the byte-exact Release asset (manifest, SHA256SUMS), use
# http_download_file instead.
http_get() {
  local url="$1"
  local tmp
  tmp=$(mktemp) || return 1
  FETCH_HTTP_CODE=$("$CURL_BIN" -sSL --max-time 30 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null) || {
    FETCH_HTTP_CODE="000"
    rm -f "$tmp"
    return 1
  }
  cat "$tmp"
  rm -f "$tmp"
  if [ "$FETCH_HTTP_CODE" = "200" ]; then
    return 0
  fi
  return 1
}

# Download a URL directly to a file, preserving exact bytes (including
# trailing newlines). Required for manifest and SHA256SUMS whose digest must
# match the byte-exact asset stored in the GitHub Release.
#
# Sets FETCH_HTTP_CODE ("000" = network failure, "200" = OK, etc.)
# Args: url, output_file_path
# Returns 0 on HTTP 200 and non-empty file, 1 otherwise (output removed).
http_download_file() {
  local url="$1"
  local output="$2"
  local code
  code=$("$CURL_BIN" -sSL --max-time 30 -o "$output" -w '%{http_code}' "$url" 2>/dev/null) || {
    FETCH_HTTP_CODE="000"
    rm -f "$output"
    return 1
  }
  FETCH_HTTP_CODE="$code"
  if [ "$code" != "200" ] || [ ! -s "$output" ]; then
    rm -f "$output"
    return 1
  fi
  return 0
}

# Check if stdin is valid JSON (not HTML, not empty, not truncated).
# Returns 0 if valid, 1 otherwise.
is_valid_json() {
  "$JQ_BIN" empty >/dev/null 2>&1
}

# ============================================================================
# Note sanitization
# ============================================================================

# Sanitize note: strip control characters (0x00-0x1F, 0x7F), limit length.
# Outputs sanitized note on stdout.
sanitize_note() {
  local note="$1"
  # Remove all control characters, keep printable + space
  note=$(printf '%s' "$note" | tr -d '\000-\037\177')
  # Limit length (bash 3.2 compatible substring)
  if [ "${#note}" -gt "$NOTE_MAX_LENGTH" ]; then
    note="${note:0:$NOTE_MAX_LENGTH}"
  fi
  printf '%s' "$note"
}

# ============================================================================
# Input validation
# ============================================================================

# Validate component name against allowlist.
# Returns 0 if valid, 1 otherwise.
validate_component() {
  local component="$1"
  case "$component" in
    shell|xray|nginx|openssl|jemalloc|nginx_build) return 0 ;;
    *) return 1 ;;
  esac
}

# Validate version format for a component.
# Returns 0 if valid, 1 otherwise.
validate_version_format() {
  local component="$1"
  local version="$2"

  # Reject null/empty/undefined
  if [ -z "$version" ] || [ "$version" = "null" ] || [ "$version" = "undefined" ]; then
    return 1
  fi

  case "$component" in
    shell|xray|nginx|openssl|jemalloc)
      printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)*$'
      ;;
    nginx_build)
      printf '%s' "$version" | grep -qE '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$'
      ;;
    *)
      return 1
      ;;
  esac
}

# ============================================================================
# Upstream verification (fail-closed)
# ============================================================================

# Verify upstream release/tag exists for the component+version.
# Returns 0 if verified, 1 if fail-closed.
# Outputs error/progress messages on stderr.
verify_upstream() {
  local component="$1"
  local version="$2"

  case "$component" in
    shell)     verify_shell_upstream "$version" ;;
    xray)      verify_github_tag "repos/XTLS/Xray-core/releases/tags/v${version}" ;;
    nginx)     verify_nginx_tag "$version" ;;
    openssl)   verify_github_tag "repos/openssl/openssl/releases/tags/openssl-${version}" ;;
    jemalloc)  verify_github_tag "repos/jemalloc/jemalloc/releases/tags/${version}" ;;
    nginx_build) verify_nginx_build_release "$version" ;;
    *)
      echo "ERROR: unknown component: $component" >&2
      return 1
      ;;
  esac
}

# Verify shell version exists in an immutable published Xray Release.
# Fail-closed: the Release must be stable, tagged correctly, and carry the
# install.sh, Rill bundle and SHA256SUMS assets with matching bytes.
verify_shell_upstream() {
  local version="$1"
  local tag="v${version}" release_json release_tag draft prerelease assets_url sums_url install_url bundle_url
  release_json=$(http_get "${SHELL_RELEASE_API_BASE}/releases/tags/${tag}") || {
    echo "ERROR: failed to fetch Xray Release ${tag} (HTTP ${FETCH_HTTP_CODE})" >&2
    return 1
  }
  printf '%s' "$release_json" | is_valid_json || { echo "ERROR: Xray Release response is not valid JSON" >&2; return 1; }
  release_tag=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.tag_name // empty')
  draft=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.draft // false')
  prerelease=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.prerelease // false')
  [[ "$release_tag" == "$tag" && "$draft" == false && "$prerelease" == false ]] || {
    echo "ERROR: Xray Release ${tag} is missing, draft, prerelease, or has the wrong tag" >&2
    return 1
  }
  install_url=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.assets[]? | select(.name == "install.sh") | .browser_download_url // empty')
  bundle_url=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.assets[]? | select(.name == "rill-xray-agent-xray-bundle.tar.gz") | .browser_download_url // empty')
  sums_url=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.assets[]? | select(.name == "SHA256SUMS") | .browser_download_url // empty')
  [[ -n "$install_url" && -n "$bundle_url" && -n "$sums_url" ]] || {
    echo "ERROR: Xray Release ${tag} is missing required assets" >&2
    return 1
  }
  local tmp install_file bundle_file sums_file install_sha bundle_sha actual version_in_asset
  tmp=$(mktemp -d) || return 1
  install_file="$tmp/install.sh"; bundle_file="$tmp/rill-xray-agent-xray-bundle.tar.gz"; sums_file="$tmp/SHA256SUMS"
  if ! http_download_file "$sums_url" "$sums_file" || ! http_download_file "$install_url" "$install_file" || ! http_download_file "$bundle_url" "$bundle_file"; then
    rm -rf "$tmp"; echo "ERROR: failed to download Xray Release assets" >&2; return 1
  fi
  install_sha=$(awk '$2 == "install.sh" || $2 == "*install.sh" {print $1; exit}' "$sums_file")
  bundle_sha=$(awk '$2 == "rill-xray-agent-xray-bundle.tar.gz" || $2 == "*rill-xray-agent-xray-bundle.tar.gz" {print $1; exit}' "$sums_file")
  actual=$(sha256sum "$install_file" | awk '{print $1}')
  [[ "$install_sha" =~ ^[0-9a-f]{64}$ && "$actual" == "$install_sha" ]] || { rm -rf "$tmp"; echo "ERROR: install.sh SHA256 mismatch" >&2; return 1; }
  actual=$(sha256sum "$bundle_file" | awk '{print $1}')
  [[ "$bundle_sha" =~ ^[0-9a-f]{64}$ && "$actual" == "$bundle_sha" ]] || { rm -rf "$tmp"; echo "ERROR: Rill bundle SHA256 mismatch" >&2; return 1; }
  version_in_asset=$(grep '^shell_version=' "$install_file" | head -1 | awk -F'=|"' '{print $3}')
  rm -rf "$tmp"
  [[ "$version_in_asset" == "$version" ]] || { echo "ERROR: Release install.sh shell_version=${version_in_asset:-empty} != ${version}" >&2; return 1; }
  echo "OK: verified immutable Xray Release ${tag} (install.sh + Rill bundle + SHA256SUMS)" >&2
}

# Verify a GitHub release/tag exists. Fail-closed on any error.
# Args: $1 = API path (e.g., "repos/XTLS/Xray-core/releases/tags/v1.0.0")
verify_github_tag() {
  local api_path="$1"
  local body
  body=$(http_get "${GITHUB_API_BASE}/${api_path}") || {
    case "$FETCH_HTTP_CODE" in
      404) echo "ERROR: tag not found: $api_path (HTTP 404)" >&2 ;;
      403|429) echo "ERROR: API rate limited (HTTP $FETCH_HTTP_CODE)" >&2 ;;
      000) echo "ERROR: network failure fetching $api_path" >&2 ;;
      *) echo "ERROR: unexpected HTTP $FETCH_HTTP_CODE fetching $api_path" >&2 ;;
    esac
    return 1
  }

  # Validate response is JSON (not HTML)
  if ! printf '%s' "$body" | is_valid_json; then
    echo "ERROR: response is not valid JSON (possibly HTML): $api_path" >&2
    return 1
  fi

  echo "OK: verified $api_path" >&2
  return 0
}

# Verify nginx tag (may use releases endpoint or git refs endpoint).
verify_nginx_tag() {
  local version="$1"
  # Try releases first (suppress intermediate errors)
  if verify_github_tag "repos/nginx/nginx/releases/tags/release-${version}" 2>/dev/null; then
    return 0
  fi
  # Try git refs
  if verify_github_tag "repos/nginx/nginx/git/refs/tags/release-${version}" 2>/dev/null; then
    return 0
  fi
  echo "ERROR: nginx tag release-${version} not found" >&2
  return 1
}

# Verify nginx_build release has: release/tag, release-manifest.json asset,
# architecture assets, SHA256 fields, and version match.
# Fail-closed on any missing requirement.
#
# Manifest and SHA256SUMS are downloaded to files (via http_download_file)
# rather than captured via shell command substitution, so the SHA256 is computed
# over the exact bytes stored in the GitHub Release asset (including any
# trailing newline). This prevents false negatives where a legitimate Release
# with a trailing newline in release-manifest.json fails promotion.
#
# File lifecycle is managed by the outer wrapper (verify_nginx_build_release),
# which creates temp files before the call and removes them after. The inner
# core function does NOT use trap RETURN (which would fire on every nested
# function return and delete the files prematurely).
_verify_nginx_build_release_core() {
  local version="$1"
  local tag="v${version}"
  local manifest_file="$2"
  local sha256sums_file="$3"

  # 1. Release must exist
  local release_json
  release_json=$(http_get "${GITHUB_API_BASE}/repos/${NGINX_BUILD_REPO}/releases/tags/${tag}") || {
    case "$FETCH_HTTP_CODE" in
      404) echo "ERROR: nginx_build release $tag not found (HTTP 404)" >&2 ;;
      403|429) echo "ERROR: API rate limited (HTTP $FETCH_HTTP_CODE)" >&2 ;;
      000) echo "ERROR: network failure fetching release $tag" >&2 ;;
      *) echo "ERROR: unexpected HTTP $FETCH_HTTP_CODE fetching release $tag" >&2 ;;
    esac
    return 1
  }

  # Validate JSON
  if ! printf '%s' "$release_json" | is_valid_json; then
    echo "ERROR: release response is not valid JSON for $tag" >&2
    return 1
  fi

  # 2. Require the release tag, manifest, checksum list, and both architecture assets.
  local release_tag manifest_url release_asset_names sha256sums_url
  release_tag=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.tag_name // empty' 2>/dev/null)
  if [ "$release_tag" != "$tag" ]; then
    echo "ERROR: release tag ($release_tag) does not match expected $tag" >&2
    return 1
  fi

  # Reject draft and prerelease releases. GitHub's /releases/tags/<tag> endpoint
  # returns the release regardless of draft/prerelease status, so we must enforce
  # explicitly that only stable published releases may be promoted to
  # tested_version (fail-closed).
  local is_draft is_prerelease
  is_draft=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.draft // false' 2>/dev/null)
  is_prerelease=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.prerelease // false' 2>/dev/null)
  if [ "$is_draft" = "true" ]; then
    echo "ERROR: release $tag is a draft — only published releases may be promoted" >&2
    return 1
  fi
  if [ "$is_prerelease" = "true" ]; then
    echo "ERROR: release $tag is a prerelease — only stable releases may be promoted" >&2
    return 1
  fi

  release_asset_names=$(printf '%s' "$release_json" | "$JQ_BIN" -r '.assets[]?.name // empty' 2>/dev/null)
  manifest_url=$(printf '%s' "$release_json" | "$JQ_BIN" -r \
    '.assets[]? | select(.name == "release-manifest.json") | .browser_download_url // empty' 2>/dev/null)
  sha256sums_url=$(printf '%s' "$release_json" | "$JQ_BIN" -r \
    '.assets[]? | select(.name == "SHA256SUMS") | .browser_download_url // empty' 2>/dev/null)

  if [ -z "$manifest_url" ] || [ "$manifest_url" = "null" ]; then
    echo "ERROR: release-manifest.json asset not found in release $tag" >&2
    return 1
  fi
  if [ -z "$sha256sums_url" ] || [ "$sha256sums_url" = "null" ]; then
    echo "ERROR: SHA256SUMS asset URL not found in release $tag" >&2
    return 1
  fi
  if ! printf '%s\n' "$release_asset_names" | grep -qx 'SHA256SUMS'; then
    echo "ERROR: SHA256SUMS asset not found in release $tag" >&2
    return 1
  fi

  # 3. Download manifest to file (fail-closed), byte-exact download.
  if ! http_download_file "$manifest_url" "$manifest_file"; then
    echo "ERROR: failed to download release-manifest.json (HTTP $FETCH_HTTP_CODE)" >&2
    return 1
  fi

  # Validate manifest is JSON
  if ! is_valid_json < "$manifest_file"; then
    echo "ERROR: release-manifest.json is not valid JSON" >&2
    return 1
  fi

  # 4. Verify manifest build/version matches input
  local manifest_build
  manifest_build=$("$JQ_BIN" -r \
    '.versions.nginx_build // .build // .version // empty' "$manifest_file" 2>/dev/null)

  if [ -z "$manifest_build" ] || [ "$manifest_build" = "null" ]; then
    echo "ERROR: manifest has no build/version field" >&2
    return 1
  fi

  if [ "$manifest_build" != "$version" ]; then
    echo "ERROR: manifest build version ($manifest_build) does not match input ($version)" >&2
    return 1
  fi

  # 5. Require exactly the x86 and arm contracts used by the installer.
  local arch manifest_filename
  for arch in x86 arm; do
    manifest_filename=$("$JQ_BIN" -r \
      --arg arch "$arch" '.assets[]? | select(.arch == $arch) | .filename // empty' "$manifest_file" 2>/dev/null)
    if [ -z "$manifest_filename" ]; then
      echo "ERROR: manifest is missing $arch architecture asset" >&2
      return 1
    fi
    if ! printf '%s\n' "$release_asset_names" | grep -Fqx "$manifest_filename"; then
      echo "ERROR: manifest $arch asset is absent from release: $manifest_filename" >&2
      return 1
    fi
  done

  # 6. Every manifest asset needs a canonical SHA-256 digest.
  local assets_without_sha
  assets_without_sha=$("$JQ_BIN" -r \
    '.assets[]? | select((.sha256 // "") | test("^[0-9a-fA-F]{64}$") | not) |
     .arch // .filename // "unknown"' "$manifest_file" 2>/dev/null)

  if [ -n "$assets_without_sha" ]; then
    echo "ERROR: manifest assets missing sha256: $assets_without_sha" >&2
    return 1
  fi

  # 7. Download SHA256SUMS to file (fail-closed), byte-exact download.
  if ! http_download_file "$sha256sums_url" "$sha256sums_file"; then
    echo "ERROR: failed to download SHA256SUMS (HTTP $FETCH_HTTP_CODE)" >&2
    return 1
  fi

  # 8. Reject HTML or empty SHA256SUMS content.
  if [ ! -s "$sha256sums_file" ]; then
    echo "ERROR: SHA256SUMS content is empty" >&2
    return 1
  fi
  if grep -qi '^<html\|^<!DOCTYPE' "$sha256sums_file"; then
    echo "ERROR: SHA256SUMS response is HTML, not checksum file" >&2
    return 1
  fi

  # 9. Verify each required file has exactly one entry with valid SHA format.
  #    Format: <sha256>  <filename>  (whitespace-separated)
  local required_files="xray-nginx-custom-x86.tar.gz xray-nginx-custom-arm.tar.gz release-manifest.json"
  local req_file
  for req_file in $required_files; do
    local sum_count sum_entry_sha
    sum_count=$(awk -v f="$req_file" '$NF == f {c++} END {print c+0}' "$sha256sums_file")
    if [ "$sum_count" -eq 0 ]; then
      echo "ERROR: SHA256SUMS missing entry for $req_file" >&2
      return 1
    fi
    if [ "$sum_count" -gt 1 ]; then
      echo "ERROR: SHA256SUMS has $sum_count entries for $req_file (expected exactly 1)" >&2
      return 1
    fi
    sum_entry_sha=$(awk -v f="$req_file" '$NF == f {print $1; exit}' "$sha256sums_file")
    if ! printf '%s' "$sum_entry_sha" | grep -qE '^[0-9a-fA-F]{64}$'; then
      echo "ERROR: SHA256SUMS entry for $req_file has invalid sha256 format: $sum_entry_sha" >&2
      return 1
    fi
  done

  # 10. Verify manifest x86/arm filename and SHA match SHA256SUMS exactly.
  local manifest_sha sum_sha canonical
  for arch in x86 arm; do
    manifest_filename=$("$JQ_BIN" -r \
      --arg arch "$arch" '.assets[]? | select(.arch == $arch) | .filename // empty' "$manifest_file" 2>/dev/null)
    manifest_sha=$("$JQ_BIN" -r \
      --arg arch "$arch" '.assets[]? | select(.arch == $arch) | .sha256 // empty' "$manifest_file" 2>/dev/null)

    case "$arch" in
      x86) canonical="xray-nginx-custom-x86.tar.gz" ;;
      arm) canonical="xray-nginx-custom-arm.tar.gz" ;;
    esac
    if [ "$manifest_filename" != "$canonical" ]; then
      echo "ERROR: manifest $arch filename ($manifest_filename) does not match canonical ($canonical)" >&2
      return 1
    fi

    sum_sha=$(awk -v f="$manifest_filename" '$NF == f {print $1; exit}' "$sha256sums_file")
    if [ -z "$sum_sha" ]; then
      echo "ERROR: SHA256SUMS missing entry for $arch ($manifest_filename)" >&2
      return 1
    fi
    if [ "$(printf '%s' "$manifest_sha" | tr 'A-F' 'a-f')" != "$(printf '%s' "$sum_sha" | tr 'A-F' 'a-f')" ]; then
      echo "ERROR: manifest $arch SHA ($manifest_sha) does not match SHA256SUMS ($sum_sha)" >&2
      return 1
    fi
  done

  # 11. Verify release-manifest.json SHA matches actual manifest FILE bytes.
  #     Digest is computed over the downloaded file (byte-exact, including
  #     any trailing newline), not over a shell variable that lost its newline.
  local manifest_recorded_sha manifest_actual_sha
  manifest_recorded_sha=$(awk -v f="release-manifest.json" '$NF == f {print $1; exit}' "$sha256sums_file")
  if command -v shasum >/dev/null 2>&1; then
    manifest_actual_sha=$(shasum -a 256 "$manifest_file" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    manifest_actual_sha=$(sha256sum "$manifest_file" | awk '{print $1}')
  else
    echo "ERROR: no SHA256 tool available (shasum/sha256sum)" >&2
    return 1
  fi
  if [ "$(printf '%s' "$manifest_recorded_sha" | tr 'A-F' 'a-f')" != "$(printf '%s' "$manifest_actual_sha" | tr 'A-F' 'a-f')" ]; then
    echo "ERROR: SHA256SUMS release-manifest.json SHA ($manifest_recorded_sha) does not match actual manifest file bytes ($manifest_actual_sha)" >&2
    return 1
  fi

  echo "OK: nginx_build release $tag verified (manifest, assets, sha256, version, SHA256SUMS consistency)" >&2
  return 0
}

# Outer wrapper: manages temp file lifecycle for _verify_nginx_build_release_core.
# This avoids trap RETURN (which would fire on every nested function return and
# delete the temp files prematurely during http_download_file / http_get calls).
verify_nginx_build_release() {
  local version="$1"
  local manifest_file sha256sums_file
  manifest_file=$(mktemp) || return 1
  sha256sums_file=$(mktemp) || { rm -f "$manifest_file"; return 1; }

  _verify_nginx_build_release_core "$version" "$manifest_file" "$sha256sums_file"
  local rc=$?

  rm -f "$manifest_file" "$sha256sums_file"
  return $rc
}

# ============================================================================
# Snapshot comparison
# ============================================================================

# Compare two JSON snapshots excluding specific keys.
# Args:
#   $1 = old snapshot file
#   $2 = new file
#   $3 = component name (key to exclude in tested_versions.json)
# Returns: 0 if identical (excluding target key), 1 if different.
# Outputs diff details on stdout.
compare_tested_versions_excluding() {
  local old_file="$1"
  local new_file="$2"
  local component="$3"

  local old_filtered new_filtered
  old_filtered=$("$JQ_BIN" -S --arg c "$component" 'del(.[$c])' "$old_file" 2>/dev/null)
  new_filtered=$("$JQ_BIN" -S --arg c "$component" 'del(.[$c])' "$new_file" 2>/dev/null)

  if [ "$old_filtered" = "$new_filtered" ]; then
    return 0
  fi
  return 1
}

# Compare xray_shell_versions.json snapshots excluding target metadata fields.
# Args:
#   $1 = old snapshot file
#   $2 = new file
#   $3 = component name (used to build field names: {comp}_tested_version, etc.)
# Returns: 0 if identical (excluding target fields), 1 if different.
compare_versions_excluding() {
  local old_file="$1"
  local new_file="$2"
  local component="$3"

  local tested_field="${component}_tested_version"
  local at_field="${component}_tested_at"
  local note_field="${component}_tested_note"

  local old_filtered new_filtered
  old_filtered=$("$JQ_BIN" -S \
    --arg tv "$tested_field" \
    --arg ta "$at_field" \
    --arg tn "$note_field" \
    'del(.[$tv], .[$ta], .[$tn])' "$old_file" 2>/dev/null)
  new_filtered=$("$JQ_BIN" -S \
    --arg tv "$tested_field" \
    --arg ta "$at_field" \
    --arg tn "$note_field" \
    'del(.[$tv], .[$ta], .[$tn])' "$new_file" 2>/dev/null)

  if [ "$old_filtered" = "$new_filtered" ]; then
    return 0
  fi
  return 1
}

# Check consistency between tested_versions.json and xray_shell_versions.json.
# All components' tested_version must match between the two files.
# Args:
#   $1 = tested_versions.json path
#   $2 = xray_shell_versions.json path
# Returns: 0 if consistent, 1 otherwise.
check_consistency() {
  local tested_file="$1"
  local versions_file="$2"

  local comp short_val long_val
  for comp in shell xray nginx openssl jemalloc nginx_build; do
    short_val=$("$JQ_BIN" -r --arg c "$comp" '.[$c] // empty' "$tested_file" 2>/dev/null)
    long_val=$("$JQ_BIN" -r ".${comp}_tested_version // empty" "$versions_file" 2>/dev/null)
    if [ -z "$short_val" ] || [ -z "$long_val" ]; then
      echo "ERROR: consistency field missing for $comp" >&2
      return 1
    fi
    if [ "$short_val" != "$long_val" ]; then
      echo "ERROR: consistency mismatch for $comp: $tested_file=$short_val != $versions_file=${comp}_tested_version=$long_val" >&2
      return 1
    fi
  done
  return 0
}

# Verify that no online_version fields changed between snapshot and current.
# Args:
#   $1 = old snapshot file
#   $2 = new file
# Returns: 0 if all online fields unchanged, 1 otherwise.
check_online_unchanged() {
  local old_file="$1"
  local new_file="$2"

  local comp old_online new_online
  for comp in shell xray nginx openssl jemalloc nginx_build; do
    old_online=$("$JQ_BIN" -r ".${comp}_online_version // empty" "$old_file" 2>/dev/null)
    new_online=$("$JQ_BIN" -r ".${comp}_online_version // empty" "$new_file" 2>/dev/null)
    if [ -z "$old_online" ] || [ -z "$new_online" ]; then
      echo "ERROR: ${comp}_online_version is missing" >&2
      return 1
    fi
    if [ "$old_online" != "$new_online" ]; then
      echo "ERROR: ${comp}_online_version changed: $old_online -> $new_online" >&2
      return 1
    fi
  done
  return 0
}

# ============================================================================
# Main promotion logic
# ============================================================================

# Promote a single component to a new tested_version.
#
# Args:
#   $1: component (shell|xray|nginx|openssl|jemalloc|nginx_build)
#   $2: version string
#   $3: note (optional, will be sanitized)
#   $4: tested_versions.json path (optional, default: tested_versions.json)
#   $5: xray_shell_versions.json path (optional, default: xray_shell_versions.json)
#
# Returns: 0 on success, 1 on failure.
# On failure, both JSON files are restored to their pre-modification state.
promote_component() {
  local component="$1"
  local version="$2"
  local note="${3:-}"
  local tested_file="${4:-tested_versions.json}"
  local versions_file="${5:-xray_shell_versions.json}"

  # --- Input validation ---
  if ! validate_component "$component"; then
    echo "ERROR: invalid component: $component" >&2
    return 1
  fi

  if ! validate_version_format "$component" "$version"; then
    echo "ERROR: invalid version format for $component: $version" >&2
    return 1
  fi

  # Sanitize note (strip control chars, limit length)
  local sanitized_note=""
  if [ -n "$note" ]; then
    sanitized_note=$(sanitize_note "$note")
  fi

  # --- Check files exist ---
  if [ ! -f "$tested_file" ]; then
    echo "ERROR: $tested_file not found" >&2
    return 1
  fi
  if [ ! -f "$versions_file" ]; then
    echo "ERROR: $versions_file not found" >&2
    return 1
  fi

  # --- Save snapshots (for rollback and comparison) ---
  local snap_tested snap_versions
  snap_tested=$(mktemp) || return 1
  snap_versions=$(mktemp) || { rm -f "$snap_tested"; return 1; }

  if ! cp "$tested_file" "$snap_tested"; then
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi
  if ! cp "$versions_file" "$snap_versions"; then
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi

  # --- Verify upstream (fail-closed: no modification before this passes) ---
  if ! verify_upstream "$component" "$version" >&2; then
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi

  # --- Update tested_versions.json (single component only) ---
  local updated_at
  updated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  if ! "$JQ_BIN" --arg c "$component" --arg v "$version" \
     '.[$c] = $v' "$tested_file" > "${tested_file}.tmp" 2>/dev/null; then
    echo "ERROR: failed to update $tested_file" >&2
    rm -f "$snap_tested" "$snap_versions" "${tested_file}.tmp"
    return 1
  fi

  if ! "$JQ_BIN" empty "${tested_file}.tmp" >/dev/null 2>&1; then
    echo "ERROR: generated $tested_file is invalid JSON" >&2
    rm -f "$snap_tested" "$snap_versions" "${tested_file}.tmp"
    return 1
  fi

  if ! mv "${tested_file}.tmp" "$tested_file"; then
    echo "ERROR: failed to atomically replace $tested_file" >&2
    rm -f "$snap_tested" "$snap_versions" "${tested_file}.tmp"
    return 1
  fi

  # --- Update xray_shell_versions.json (tested_version + metadata) ---
  local tested_field="${component}_tested_version"
  local at_field="${component}_tested_at"
  local note_field="${component}_tested_note"

  if [ -n "$sanitized_note" ]; then
    "$JQ_BIN" --arg field "$tested_field" \
       --arg v "$version" \
       --arg at_field "$at_field" \
       --arg at_v "$updated_at" \
       --arg note_field "$note_field" \
       --arg note_v "$sanitized_note" \
       '.[$field] = $v | .[$at_field] = $at_v | .[$note_field] = $note_v' \
       "$versions_file" > "${versions_file}.tmp" 2>/dev/null
  else
    "$JQ_BIN" --arg field "$tested_field" \
       --arg v "$version" \
       --arg at_field "$at_field" \
       --arg at_v "$updated_at" \
       '.[$field] = $v | .[$at_field] = $at_v' \
       "$versions_file" > "${versions_file}.tmp" 2>/dev/null
  fi

  if ! "$JQ_BIN" empty "${versions_file}.tmp" >/dev/null 2>&1; then
    echo "ERROR: generated $versions_file is invalid JSON" >&2
    rm -f "${versions_file}.tmp"
    # Rollback tested_versions.json
    cp "$snap_tested" "$tested_file"
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi

  if ! mv "${versions_file}.tmp" "$versions_file"; then
    echo "ERROR: failed to atomically replace $versions_file" >&2
    cp "$snap_tested" "$tested_file"
    rm -f "$snap_tested" "$snap_versions" "${versions_file}.tmp"
    return 1
  fi

  # --- Snapshot comparison: only target fields changed ---

  # tested_versions.json: only target component key should differ
  if ! compare_tested_versions_excluding "$snap_tested" "$tested_file" "$component"; then
    echo "ERROR: non-target fields changed in $tested_file" >&2
    echo "--- Expected (non-target fields) ---" >&2
    "$JQ_BIN" -S --arg c "$component" 'del(.[$c])' "$snap_tested" >&2 2>/dev/null
    echo "--- Actual (non-target fields) ---" >&2
    "$JQ_BIN" -S --arg c "$component" 'del(.[$c])' "$tested_file" >&2 2>/dev/null
    # Rollback both files
    cp "$snap_tested" "$tested_file"
    cp "$snap_versions" "$versions_file"
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi

  # xray_shell_versions.json: only target tested/at/note fields should differ
  if ! compare_versions_excluding "$snap_versions" "$versions_file" "$component"; then
    echo "ERROR: non-target fields changed in $versions_file" >&2
    echo "--- Expected (non-target fields) ---" >&2
    "$JQ_BIN" -S \
      --arg tv "$tested_field" --arg ta "$at_field" --arg tn "$note_field" \
      'del(.[$tv], .[$ta], .[$tn])' "$snap_versions" >&2 2>/dev/null
    echo "--- Actual (non-target fields) ---" >&2
    "$JQ_BIN" -S \
      --arg tv "$tested_field" --arg ta "$at_field" --arg tn "$note_field" \
      'del(.[$tv], .[$ta], .[$tn])' "$versions_file" >&2 2>/dev/null
    # Rollback both files
    cp "$snap_tested" "$tested_file"
    cp "$snap_versions" "$versions_file"
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi

  # --- Verify online_version fields are unchanged ---
  if ! check_online_unchanged "$snap_versions" "$versions_file" >&2; then
    cp "$snap_tested" "$tested_file"
    cp "$snap_versions" "$versions_file"
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi

  # --- Consistency check: both files agree on ALL tested_version values ---
  if ! check_consistency "$tested_file" "$versions_file" >&2; then
    cp "$snap_tested" "$tested_file"
    cp "$snap_versions" "$versions_file"
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi

  # --- Final jq validation ---
  if ! "$JQ_BIN" empty "$tested_file" >/dev/null 2>&1; then
    echo "ERROR: $tested_file fails jq empty" >&2
    cp "$snap_tested" "$tested_file"
    cp "$snap_versions" "$versions_file"
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi
  if ! "$JQ_BIN" empty "$versions_file" >/dev/null 2>&1; then
    echo "ERROR: $versions_file fails jq empty" >&2
    cp "$snap_tested" "$tested_file"
    cp "$snap_versions" "$versions_file"
    rm -f "$snap_tested" "$snap_versions"
    return 1
  fi

  # Success
  rm -f "$snap_tested" "$snap_versions"
  echo "OK: promoted $component to $version" >&2
  return 0
}

# ============================================================================
# Main entry point (when executed directly, not sourced)
# ============================================================================

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail

  component="${1:-}"
  version="${2:-}"
  note="${3:-}"

  if [ -z "$component" ] || [ -z "$version" ]; then
    echo "Usage: $0 <component> <version> [note]" >&2
    echo "Components: shell | xray | nginx | openssl | jemalloc | nginx_build" >&2
    exit 1
  fi

  if promote_component "$component" "$version" "$note"; then
    exit 0
  else
    exit 1
  fi
fi
