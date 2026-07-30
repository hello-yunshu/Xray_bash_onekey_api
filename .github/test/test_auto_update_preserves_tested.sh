#!/usr/bin/env bash
# Auto-update (update-version.sh) contract tests.
#
# Verifies the automatic online-version sync NEVER modifies tested fields or
# tested metadata (tested_at / tested_note), and that network failures do not
# pollute the JSON files.
#
# Covers prompt scenarios:
#   A — update online, tested unchanged (including tested_at / tested_note)
#   B — online already latest → no meaningless write
#   C — network/API failure → exit non-zero, JSON not polluted
#   D — tested drift between the two JSON files → fail closed, no write/commit
#
# Promotion scenarios D-I are covered by test_promote_tested_version.sh:
#   D — promote older-than-online real release (T14: nginx_build 2025.12.23 < online)
#   E — promote current online (promote_component has no online check; any valid
#        release is accepted, proven by T13/T14/T15 promoting arbitrary versions)
#   F — tag-only / no release (T06, T07, T10, T10b, T10c)
#   G — draft / prerelease (T10d, T10e)
#   H — missing asset / SHA mismatch (T07, T08, T09, T14b-T14j)
#   I — other components unaffected (T15, T16, T17, T25)
#
# Run: bash .github/test/test_auto_update_preserves_tested.sh
#
# NOTE: update-version.sh uses `declare -A` (associative arrays), which requires
# bash 4+. On macOS the system /bin/bash is 3.2 and cannot run update-version.sh.
# This test detects that and SKIPs (exit 77) with a clear message rather than
# reporting false passes. CI runs on ubuntu-latest (bash 5+) where it executes
# for real.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required" >&2
  exit 1
fi

# update-version.sh requires bash 4+ (declare -A associative arrays). Detect
# capability by testing whether `declare -A` works. On bash 3.2 (macOS system
# bash) it prints an error and returns non-zero, so we SKIP honestly.
if ! ( set +e; declare -A _t 2>/dev/null ) 2>/dev/null; then
  BASH_VER_OK=false
else
  BASH_VER_OK=true
fi
if ! ${BASH_VER_OK}; then
  echo "SKIP: update-version.sh requires bash 4+ (declare -A)."
  echo "SKIP: Current bash is $(bash --version 2>&1 | head -1)."
  echo "SKIP: This test runs for real on CI (ubuntu-latest, bash 5+)."
  echo "SKIP: Not reporting pass — run on bash 4+ or via CI to get real coverage."
  exit 77
fi

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); printf "PASS: %s\n" "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "FAIL: %s\n" "$1"
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

# Portable content hash: macOS has `shasum -a 256`, Linux has `sha256sum`.
# Used for byte-identical comparison of JSON files across platforms.
hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    echo "ERROR: no SHA256 tool available (shasum/sha256sum)" >&2
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Fixtures
# ----------------------------------------------------------------------------

# Scenario A/B initial state: online fields are OLDER than the mock "latest"
# values, so A triggers an update. tested fields + tested_at/note must survive.
INIT_TESTED='{
  "shell": "2.8.3",
  "xray": "25.12.8",
  "nginx": "1.28.1",
  "openssl": "3.6.0",
  "jemalloc": "5.3.0",
  "nginx_build": "2025.12.23"
}'

INIT_VERSIONS='{
  "update_date": "2026-07-15 20:56",
  "shell_online_version": "3.0.1",
  "shell_tested_version": "2.8.3",
  "shell_upgrade_details": "old details",
  "nginx_build_online_version": "2026.07.15.6960",
  "nginx_build_tested_version": "2025.12.23",
  "nginx_build_tested_at": "2026-07-20T00:00:00Z",
  "nginx_build_tested_note": "Promoted baseline",
  "nginx_online_version": "1.30.3",
  "nginx_tested_version": "1.28.1",
  "xray_online_version": "26.3.26",
  "xray_tested_version": "25.12.8",
  "jemalloc_online_version": "5.3.0",
  "jemalloc_tested_version": "5.3.0",
  "openssl_online_version": "3.6.2",
  "openssl_tested_version": "3.6.0"
}'

# Mock curl: returns fixture data per URL. Non-shell "latest" values are NEWER
# than INIT_VERSIONS online fields. shell install.sh is kept EQUAL to the
# fixture so get_shell_upgrade_details (commit-history walk) is not invoked.
make_mock_curl() {
  cat > "$1" <<'MOCK'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done
case "$url" in
  */hello-yunshu/Xray_bash_onekey/main/install.sh)
    printf '#!/bin/bash\nshell_version="3.0.1"\n'
    ;;
  */XTLS/Xray-core/releases/latest)
    printf '{"tag_name":"v26.3.27"}'
    ;;
  */nginx/nginx/tags)
    printf '[{"name":"release-1.30.4"},{"name":"release-1.29.3"}]'
    ;;
  */openssl/openssl/tags)
    printf '[{"name":"openssl-3.6.3"},{"name":"openssl-3.6.2"}]'
    ;;
  */jemalloc/jemalloc/releases/latest)
    printf '{"tag_name":"5.3.1"}'
    ;;
  */hello-yunshu/Xray_bash_onekey_Nginx/releases/latest)
    printf '{"tag_name":"v2026.07.15.6961"}'
    ;;
  *)
    :
    ;;
esac
MOCK
  chmod +x "$1"
}

# Failing mock curl: every request fails (network failure). Outputs nothing.
make_failing_mock_curl() {
  cat > "$1" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
  chmod +x "$1"
}

setup_temp_repo() {
  local d
  d=$(mktemp -d)
  printf '%s\n' "$INIT_TESTED" > "$d/tested_versions.json"
  printf '%s\n' "$INIT_VERSIONS" > "$d/xray_shell_versions.json"
  cp "$REPO_DIR/update-version.sh" "$d/update-version.sh"
  # Isolate git global config by pointing HOME at the temp dir.
  git -C "$d" init -q
  git -C "$d" config user.email "test@test.example"
  git -C "$d" config user.name "test"
  git -C "$d" add -A
  git -C "$d" commit -q -m init 2>/dev/null || true
  echo "$d"
}

cleanup_temp_repo() { [ -d "$1" ] && rm -rf "$1"; }

# ============================================================================
echo ""
echo "=============================================="
echo "  Scenario A: update online, keep tested + metadata"
echo "=============================================="
echo ""
# ============================================================================

TMP_A=$(setup_temp_repo)
make_mock_curl "$TMP_A/curl"
# HOME isolation prevents `git config --global` inside update-version.sh from
# polluting the user's real ~/.gitconfig.
( cd "$TMP_A" && HOME="$TMP_A" PATH="$TMP_A:$PATH" bash update-version.sh ) >/dev/null 2>&1
A_RC=$?

if [ "$A_RC" -eq 0 ]; then pass "A: update-version.sh exited 0"; else fail "A: update-version.sh exited $A_RC"; fi

# Online fields updated to mock "latest" values.
assert_eq "A: shell_online unchanged (already latest)" \
  "3.0.1" "$(jq -r '.shell_online_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: xray_online updated" \
  "26.3.27" "$(jq -r '.xray_online_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: nginx_online updated" \
  "1.30.4" "$(jq -r '.nginx_online_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: openssl_online updated" \
  "3.6.3" "$(jq -r '.openssl_online_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: jemalloc_online updated" \
  "5.3.1" "$(jq -r '.jemalloc_online_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: nginx_build_online updated" \
  "2026.07.15.6961" "$(jq -r '.nginx_build_online_version' "$TMP_A/xray_shell_versions.json")"

# tested_version fields UNCHANGED for every component.
assert_eq "A: shell_tested unchanged" \
  "2.8.3" "$(jq -r '.shell_tested_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: xray_tested unchanged" \
  "25.12.8" "$(jq -r '.xray_tested_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: nginx_tested unchanged" \
  "1.28.1" "$(jq -r '.nginx_tested_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: openssl_tested unchanged" \
  "3.6.0" "$(jq -r '.openssl_tested_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: jemalloc_tested unchanged" \
  "5.3.0" "$(jq -r '.jemalloc_tested_version' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: nginx_build_tested unchanged" \
  "2025.12.23" "$(jq -r '.nginx_build_tested_version' "$TMP_A/xray_shell_versions.json")"

# tested metadata (tested_at / tested_note) preserved — the core regression
# this test guards against. Without the update-version.sh fix, regeneration
# from {} would silently drop these fields.
assert_eq "A: nginx_build_tested_at preserved" \
  "2026-07-20T00:00:00Z" "$(jq -r '.nginx_build_tested_at // empty' "$TMP_A/xray_shell_versions.json")"
assert_eq "A: nginx_build_tested_note preserved" \
  "Promoted baseline" "$(jq -r '.nginx_build_tested_note // empty' "$TMP_A/xray_shell_versions.json")"

# tested_versions.json byte-identical (auto-flow must never touch it).
assert_eq "A: tested_versions.json unchanged" \
  "$(printf '%s\n' "$INIT_TESTED" | jq -S .)" \
  "$(jq -S . "$TMP_A/tested_versions.json")"

cleanup_temp_repo "$TMP_A"

# ============================================================================
echo ""
echo "=============================================="
echo "  Scenario B: online already latest → no write"
echo "=============================================="
echo ""
# ============================================================================

# Build a fixture whose online fields already equal the mock "latest" values.
B_VERSIONS=$(printf '%s\n' "$INIT_VERSIONS" | jq '
  .shell_online_version="3.0.1"
  | .xray_online_version="26.3.27"
  | .nginx_online_version="1.30.4"
  | .openssl_online_version="3.6.3"
  | .jemalloc_online_version="5.3.1"
  | .nginx_build_online_version="2026.07.15.6961"
')

TMP_B=$(mktemp -d)
printf '%s\n' "$INIT_TESTED" > "$TMP_B/tested_versions.json"
printf '%s\n' "$B_VERSIONS" > "$TMP_B/xray_shell_versions.json"
cp "$REPO_DIR/update-version.sh" "$TMP_B/update-version.sh"
git -C "$TMP_B" init -q
git -C "$TMP_B" config user.email "test@test.example"
git -C "$TMP_B" config user.name "test"
git -C "$TMP_B" add -A
git -C "$TMP_B" commit -q -m init 2>/dev/null || true
make_mock_curl "$TMP_B/curl"

B_HASH_BEFORE=$(jq -S . "$TMP_B/xray_shell_versions.json" | hash_stdin)

( cd "$TMP_B" && HOME="$TMP_B" PATH="$TMP_B:$PATH" bash update-version.sh ) >/dev/null 2>&1
B_RC=$?

if [ "$B_RC" -eq 0 ]; then pass "B: update-version.sh exited 0 (no update needed)"; else fail "B: update-version.sh exited $B_RC"; fi

B_HASH_AFTER=$(jq -S . "$TMP_B/xray_shell_versions.json" | hash_stdin)
assert_eq "B: xray_shell_versions.json byte-identical (no meaningless write)" "$B_HASH_BEFORE" "$B_HASH_AFTER"

cleanup_temp_repo "$TMP_B"

# ============================================================================
echo ""
echo "=============================================="
echo "  Scenario C: network/API failure → no pollution"
echo "=============================================="
echo ""
# ============================================================================

TMP_C=$(setup_temp_repo)
make_failing_mock_curl "$TMP_C/curl"

C_HASH_BEFORE=$(jq -S . "$TMP_C/xray_shell_versions.json" | hash_stdin)

( cd "$TMP_C" && HOME="$TMP_C" PATH="$TMP_C:$PATH" bash update-version.sh ) >/dev/null 2>&1
C_RC=$?

if [ "$C_RC" -ne 0 ]; then pass "C: update-version.sh exited non-zero on network failure ($C_RC)"; else fail "C: update-version.sh should exit non-zero on network failure"; fi

C_HASH_AFTER=$(jq -S . "$TMP_C/xray_shell_versions.json" | hash_stdin)
assert_eq "C: xray_shell_versions.json not polluted (unchanged)" "$C_HASH_BEFORE" "$C_HASH_AFTER"

# No empty/null online value written.
C_SHELL_ONLINE=$(jq -r '.shell_online_version // empty' "$TMP_C/xray_shell_versions.json")
if [ -n "$C_SHELL_ONLINE" ] && [ "$C_SHELL_ONLINE" != "null" ]; then
  pass "C: no empty/null written to shell_online_version"
else
  fail "C: shell_online_version was polluted with empty/null"
fi

cleanup_temp_repo "$TMP_C"

# ============================================================================
echo ""
echo "=============================================="
echo "  Scenario D: tested drift → fail closed, no write"
echo "=============================================="
echo ""
# ============================================================================
# Prompt requirement: when xray_shell_versions.json.nginx_build_tested_version
# and tested_versions.json.nginx_build disagree, auto-update must:
#   - return non-zero;
#   - leave both JSON files byte-identical (unchanged);
#   - produce no commit;
#   - NOT overwrite either tested value to the other file (no auto-repair).
#
# validate-json.sh checks consistency BEFORE format, so "90" vs "91" triggers
# the drift branch (not the format branch), proving the test exercises drift.

DRIFT_TESTED=$(printf '%s\n' "$INIT_TESTED" | jq '.nginx_build = "91"')
DRIFT_VERSIONS=$(printf '%s\n' "$INIT_VERSIONS" | jq '.nginx_build_tested_version = "90"')

TMP_D=$(mktemp -d)
printf '%s\n' "$DRIFT_TESTED" > "$TMP_D/tested_versions.json"
printf '%s\n' "$DRIFT_VERSIONS" > "$TMP_D/xray_shell_versions.json"
cp "$REPO_DIR/update-version.sh" "$TMP_D/update-version.sh"
cp "$REPO_DIR/validate-json.sh" "$TMP_D/validate-json.sh"
git -C "$TMP_D" init -q
git -C "$TMP_D" config user.email "test@test.example"
git -C "$TMP_D" config user.name "test"
git -C "$TMP_D" add -A
git -C "$TMP_D" commit -q -m init 2>/dev/null || true
make_mock_curl "$TMP_D/curl"

# Record byte-exact hashes and commit count BEFORE running auto-update.
D_TESTED_HASH_BEFORE=$(hash_stdin < "$TMP_D/tested_versions.json")
D_VERSIONS_HASH_BEFORE=$(hash_stdin < "$TMP_D/xray_shell_versions.json")
D_COMMITS_BEFORE=$(git -C "$TMP_D" rev-list --count HEAD 2>/dev/null || echo 0)

( cd "$TMP_D" && HOME="$TMP_D" PATH="$TMP_D:$PATH" bash update-version.sh ) >/dev/null 2>&1
D_RC=$?

if [ "$D_RC" -ne 0 ]; then
  pass "D: update-version.sh exited non-zero on tested drift ($D_RC)"
else
  fail "D: update-version.sh should exit non-zero on tested drift"
fi

D_TESTED_HASH_AFTER=$(hash_stdin < "$TMP_D/tested_versions.json")
D_VERSIONS_HASH_AFTER=$(hash_stdin < "$TMP_D/xray_shell_versions.json")
D_COMMITS_AFTER=$(git -C "$TMP_D" rev-list --count HEAD 2>/dev/null || echo 0)

assert_eq "D: tested_versions.json byte-identical (unchanged)" \
  "$D_TESTED_HASH_BEFORE" "$D_TESTED_HASH_AFTER"
assert_eq "D: xray_shell_versions.json byte-identical (unchanged)" \
  "$D_VERSIONS_HASH_BEFORE" "$D_VERSIONS_HASH_AFTER"
assert_eq "D: no commit produced" "$D_COMMITS_BEFORE" "$D_COMMITS_AFTER"

# Neither tested value may be overwritten to the other file (no auto-repair).
assert_eq "D: xray_shell_versions.json.nginx_build_tested_version still 90" \
  "90" "$(jq -r '.nginx_build_tested_version' "$TMP_D/xray_shell_versions.json")"
assert_eq "D: tested_versions.json.nginx_build still 91" \
  "91" "$(jq -r '.nginx_build' "$TMP_D/tested_versions.json")"

cleanup_temp_repo "$TMP_D"

# ============================================================================
echo ""
echo "=========================================="
printf "Total: %d, Pass: %d, Fail: %d\n" $((PASS + FAIL)) "$PASS" "$FAIL"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
