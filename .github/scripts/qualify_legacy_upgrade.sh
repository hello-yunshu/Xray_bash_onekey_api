#!/usr/bin/env bash
# Run only on a disposable Linux systemd runner. Never patch the legacy script.
set -euo pipefail
legacy=${LEGACY_REPO:?}
base=${BASE_XRAY_VERSION:?}
candidate=${XRAY_CANDIDATE_VERSION:?}
base_ref=${BASE_INSTALLER_REF:?}
base_sha=${BASE_INSTALLER_SHA256:?}
candidate_ref=${XRAY_CANDIDATE_INSTALLER_REF:?}
candidate_sha=${XRAY_CANDIDATE_INSTALLER_SHA256:?}
expected_sha=${LEGACY_INSTALL_SHA256:?}
scenario=${UPGRADE_SCENARIO:-direct}
[[ $scenario == user-recovery ]]
[[ $base =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $candidate =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ $base_ref =~ ^[0-9a-f]{40}$ && $candidate_ref =~ ^[0-9a-f]{40}$ ]]
[[ $base_sha =~ ^[0-9a-f]{64}$ && $candidate_sha =~ ^[0-9a-f]{64}$ && $expected_sha =~ ^[0-9a-f]{64}$ ]]
[[ $(sha256sum "$legacy/install.sh" | awk '{print $1}') == "$expected_sha" ]]
log=$(mktemp)
trap 'rm -f "$log"' EXIT
record_binary() {
    [[ -n ${QUALIFICATION_BINARY_EVIDENCE:-} ]] || return 0
    local installed digest arch asset temp archive_sha extracted_sha ID VERSION_ID
    installed=$(/usr/local/bin/xray version | awk 'NR==1 {sub(/^v/, "", $2); print $2}')
    digest=$(sha256sum /usr/local/bin/xray | awk '{print $1}')
    arch=$(uname -m)
    # shellcheck disable=SC1091 # runner's operating-system metadata
    . /etc/os-release
    [[ ${ID:-} =~ ^[a-z0-9._-]+$ && ${VERSION_ID:-} =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
    case "$arch" in
        x86_64) asset=Xray-linux-64.zip ;;
        aarch64) asset=Xray-linux-arm64-v8a.zip ;;
        *) echo 'Unsupported qualification architecture' >&2; return 1 ;;
    esac
    temp=$(mktemp -d)
    if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
        "https://github.com/XTLS/Xray-core/releases/download/v${installed}/${asset}" -o "$temp/$asset"; then
        rm -rf "$temp"
        return 1
    fi
    archive_sha=$(sha256sum "$temp/$asset" | awk '{print $1}')
    if ! unzip -p "$temp/$asset" xray > "$temp/xray"; then
        rm -rf "$temp"
        return 1
    fi
    extracted_sha=$(sha256sum "$temp/xray" | awk '{print $1}')
    rm -rf "$temp"
    [[ "$extracted_sha" == "$digest" ]] || { echo 'Installed binary differs from the published reference archive' >&2; return 1; }
    jq -n --arg version "$installed" --arg sha256 "$digest" --arg arch "$arch" \
        --arg asset "$asset" --arg asset_sha "$archive_sha" --arg os "$ID" --arg os_version "$VERSION_ID" \
        '{version:$version,sha256:$sha256,arch:$arch,referenceArchive:{name:$asset,sha256:$asset_sha},os:{id:$os,version:$os_version}}' > "$QUALIFICATION_BINARY_EVIDENCE"
}
diagnose() {
    # Only print fixed classifications; raw installer logs can contain secrets.
    if grep -qi 'permission denied' "$log" || journalctl -u xray --no-pager -n 40 2>/dev/null | grep -qi 'permission denied'; then
        echo 'diagnostic: permission denied observed'
    else
        echo 'diagnostic: no permission-denied message observed'
    fi
    if systemctl is-active --quiet xray; then
        echo 'diagnostic: Xray service active'
    else
        echo 'diagnostic: Xray service inactive'
    fi
}
install_version=$base
install_ref=$base_ref
install_sha=$base_sha
if [[ $scenario == fresh ]]; then
    install_version=$candidate
    install_ref=$candidate_ref
    install_sha=$candidate_sha
elif [[ $scenario == reinstall ]]; then
    # Seed the same Xray version with the previous installer, then require the
    # historical update entry to exercise its same-version reinstall branch.
    install_version=$candidate
fi
echo "Installing the legacy shell with Xray $install_version and the selected exact installer"
if ! XRAY_CANDIDATE_VERSION="$install_version" XRAY_CANDIDATE_INSTALLER_REF="$install_ref" \
    XRAY_CANDIDATE_INSTALLER_SHA256="$install_sha" \
    bash "$legacy/.github/test/test_install.sh" reality >"$log" 2>&1; then
    echo 'Legacy baseline installation failed; candidate not evaluated' >&2
    diagnose
    exit 1
fi
systemctl is-active --quiet xray
config_sha=$(sha256sum /etc/idleleo/conf/xray/config.json | awk '{print $1}')
if [[ $scenario == user-recovery ]]; then
    echo 'Reproducing the known incompatible installer update'
    if XRAY_CANDIDATE_VERSION="$candidate" XRAY_CANDIDATE_INSTALLER_REF="$candidate_ref" \
        XRAY_CANDIDATE_INSTALLER_SHA256="$candidate_sha" \
        bash /etc/idleleo/install.sh --xray-update auto_update >"$log" 2>&1; then
        echo 'Expected the incompatible update to fail' >&2
        exit 1
    fi
    diagnose
    if systemctl is-active --quiet xray; then
        echo 'Expected the reproduced failure to leave the service stopped' >&2
        exit 1
    fi
    journal_text=$(journalctl -u xray --no-pager -n 40 2>/dev/null || true)
    grep -qi 'permission denied' <<<"$journal_text" || {
        echo 'Expected a permission-denied service failure' >&2
        exit 1
    }
    echo 'Upgrading the existing Shell to the API-published release'
    if ! bash /etc/idleleo/install.sh --update auto_update >"$log" 2>&1; then
        echo 'Shell upgrade failed' >&2; diagnose; exit 1
    fi
    expected_shell_sha=$(jq -r '.shell_release_sha256 // empty' "$XRAY_VERSIONS_FILE")
    [[ $expected_shell_sha =~ ^[0-9a-f]{64}$ ]]
    [[ $(sha256sum /etc/idleleo/install.sh | awk '{print $1}') == "$expected_shell_sha" ]]
    [[ $(sha256sum /etc/idleleo/conf/xray/config.json | awk '{print $1}') == "$config_sha" ]]
    echo 'Running the repaired Shell update with the currently qualified installer'
    good_version=$(jq -r '.xray_online_version' "$XRAY_VERSIONS_FILE")
    good_ref=$(jq -r '.xray_installer_ref' "$XRAY_VERSIONS_FILE")
    good_sha=$(jq -r '.xray_installer_sha256' "$XRAY_VERSIONS_FILE")
    if ! XRAY_CANDIDATE_VERSION="$good_version" XRAY_CANDIDATE_INSTALLER_REF="$good_ref" \
        XRAY_CANDIDATE_INSTALLER_SHA256="$good_sha" \
        bash /etc/idleleo/install.sh --xray-update auto_update >"$log" 2>&1; then
        echo 'Repaired Shell Xray update failed' >&2; diagnose; exit 1
    fi
    [[ $(/usr/local/bin/xray version | awk 'NR==1 {sub(/^v/, "", $2); print $2}') == "$good_version" ]]
    [[ $(sha256sum /etc/idleleo/conf/xray/config.json | awk '{print $1}') == "$config_sha" ]]
    systemctl is-active --quiet xray || { echo 'Xray service remains inactive' >&2; diagnose; exit 1; }
    user=$(systemctl show xray -p User --value)
    [[ -n $user ]] || user=root
    runuser -u "$user" -- test -r /usr/local/etc/xray/config.json
    runuser -u "$user" -- test -w /var/log/xray/access.log
    runuser -u "$user" -- test -w /var/log/xray/error.log
    echo "PASS: recovered Xray $good_version with unchanged config and active service"
    exit 0
fi
if [[ $scenario == reinstall ]]; then
    [[ $(jq -r '.xray_version // empty' /etc/idleleo/conf/install_config.json) == "$candidate" ]]
    [[ $(/usr/local/bin/xray version | awk 'NR==1 {sub(/^v/, "", $2); print $2}') == "$candidate" ]]
fi
if [[ $scenario == fresh ]]; then
    [[ $(/usr/local/bin/xray version | awk 'NR==1 {sub(/^v/, "", $2); print $2}') == "$candidate" ]]
    user=$(systemctl show xray -p User --value)
    [[ -n $user ]] || user=root
    runuser -u "$user" -- test -r /usr/local/etc/xray/config.json
    runuser -u "$user" -- test -w /var/log/xray/access.log
    runuser -u "$user" -- test -w /var/log/xray/error.log
    record_binary
    echo "Legacy fresh install passed: Xray $candidate, service account $user"
    exit 0
fi
if [[ $scenario == failure-recovery ]]; then
    # Inject a verified-format but incorrect checksum, forcing the real
    # downloader to reject the installer after the service was stopped.
    bad_sha=$(printf '%064d' 0)
    if XRAY_CANDIDATE_VERSION="$candidate" XRAY_CANDIDATE_INSTALLER_REF="$candidate_ref" \
        XRAY_CANDIDATE_INSTALLER_SHA256="$bad_sha" \
        bash /etc/idleleo/install.sh --xray-update auto_update >"$log" 2>&1; then
        echo 'Corrupted installer checksum unexpectedly accepted' >&2
        exit 1
    fi
    grep -q 'Xray-install SHA256 mismatch' "$log" || { echo 'Failure did not reach checksum verification' >&2; exit 1; }
    [[ $(/usr/local/bin/xray version | awk 'NR==1 {sub(/^v/, "", $2); print $2}') == "$base" ]]
    [[ $(sha256sum /etc/idleleo/conf/xray/config.json | awk '{print $1}') == "$config_sha" ]]
    systemctl is-active --quiet xray || { echo 'Original service was not restored after rejection' >&2; diagnose; exit 1; }
    record_binary
    echo "Legacy failure recovery passed: retained Xray $base and original config"
    exit 0
fi
if [[ $scenario == restart-recovery ]]; then
    # A real systemd pre-start hook rejects candidate starts while the local
    # backup exists. Layer 1 moves that backup back into place, after which a
    # start can succeed. No historical shell functions are patched.
    original_binary=$(sha256sum /usr/local/bin/xray | awk '{print $1}')
    marker=$(mktemp /tmp/xray-restart-failure.XXXXXX)
    chmod 666 "$marker"
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/qualification-fail-once.conf <<EOF
[Service]
Restart=no
ExecStartPre=+/bin/sh -c 'if [ -f /etc/idleleo/tmp/xray.prev ]; then echo failed > $marker; exit 1; fi'
EOF
    systemctl daemon-reload
    if XRAY_CANDIDATE_VERSION="$candidate" XRAY_CANDIDATE_INSTALLER_REF="$candidate_ref" \
        XRAY_CANDIDATE_INSTALLER_SHA256="$candidate_sha" \
        bash /etc/idleleo/install.sh --xray-update auto_update >"$log" 2>&1; then
        echo 'Failed service start unexpectedly reported success' >&2
        exit 1
    fi
    [[ -s $marker ]] || { echo 'Failure injection was not exercised' >&2; exit 1; }
    if [[ $(sha256sum /usr/local/bin/xray | awk '{print $1}') != "$original_binary" ]]; then
        restored_version=$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1 {sub(/^v/, "", $2); print $2}')
        [[ $restored_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || restored_version=unknown
        echo "Original binary was not restored; observed Xray version: $restored_version" >&2
        diagnose
        exit 1
    fi
    [[ $(sha256sum /etc/idleleo/conf/xray/config.json | awk '{print $1}') == "$config_sha" ]]
    systemctl is-active --quiet xray || { echo 'Original service was not restored after failed start' >&2; diagnose; exit 1; }
    record_binary
    echo "Legacy failed-start recovery passed: restored Xray $base and original config"
    exit 0
fi
if [[ $scenario == fallback ]]; then
    tested=$(jq -r '.xray_tested_version // empty' "$XRAY_VERSIONS_FILE")
    [[ $tested =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
    echo "Checking the unmodified legacy tested-version fallback: $tested"
    # Exercise the actual historical fallback with the candidate installer.
    # This directly tests the Layer 2 function; it does not claim the full
    # Layer 1 failure-to-Layer 2 transition has been exercised.
    if ! (
        export _TEST_MODE=1
        set +u
        source /etc/idleleo/install.sh >/dev/null 2>&1
        unset _TEST_MODE
        read_version
        fallback_xray_to_tested_version
    ) >"$log" 2>&1; then
        echo 'Legacy tested-version fallback failed; candidate is not qualified' >&2
        diagnose
        exit 1
    fi
    installed=$(/usr/local/bin/xray version | awk 'NR==1 {sub(/^v/, "", $2); print $2}')
    [[ "$installed" == "$tested" ]] || { echo "Fallback version mismatch: expected $tested, got $installed" >&2; exit 1; }
    [[ $(sha256sum /etc/idleleo/conf/xray/config.json | awk '{print $1}') == "$config_sha" ]] || { echo 'Fallback changed Xray config bytes' >&2; exit 1; }
    systemctl is-active --quiet xray || { echo 'Fallback service inactive' >&2; diagnose; exit 1; }
    user=$(systemctl show xray -p User --value)
    [[ -n $user ]] || user=root
    runuser -u "$user" -- test -r /usr/local/etc/xray/config.json || { echo 'Fallback service user cannot read config' >&2; exit 1; }
    runuser -u "$user" -- test -w /var/log/xray/access.log || { echo 'Fallback service user cannot write access log' >&2; exit 1; }
    runuser -u "$user" -- test -w /var/log/xray/error.log || { echo 'Fallback service user cannot write error log' >&2; exit 1; }
    record_binary
    echo "Legacy tested-version fallback passed: Xray $tested, service account $user"
    exit 0
fi
if [[ $scenario == shell-first ]]; then
    expected_shell=$(jq -r '.shell_online_version // empty' "$XRAY_VERSIONS_FILE")
    expected_shell_sha=$(jq -r '.shell_release_sha256 // empty' "$XRAY_VERSIONS_FILE")
    [[ $expected_shell =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $expected_shell_sha =~ ^[0-9a-f]{64}$ ]]
    echo "Upgrading the installed Shell to the exact API Release v$expected_shell"
    if ! bash /etc/idleleo/install.sh --update auto_update >"$log" 2>&1; then
        echo 'Shell update failed; candidate not evaluated' >&2
        diagnose
        exit 1
    fi
    [[ $(sha256sum /etc/idleleo/install.sh | awk '{print $1}') == "$expected_shell_sha" ]]
    [[ $(sha256sum /etc/idleleo/conf/xray/config.json | awk '{print $1}') == "$config_sha" ]]
    systemctl is-active --quiet xray
fi
echo "Running the unmodified legacy update entry for Xray $candidate"
if ! XRAY_CANDIDATE_VERSION="$candidate" XRAY_CANDIDATE_INSTALLER_REF="$candidate_ref" \
    XRAY_CANDIDATE_INSTALLER_SHA256="$candidate_sha" \
    bash /etc/idleleo/install.sh --xray-update auto_update >"$log" 2>&1; then
    echo 'Legacy update failed; candidate is not qualified' >&2
    diagnose
    exit 1
fi
[[ $(/usr/local/bin/xray version | awk 'NR==1 {sub(/^v/, "", $2); print $2}') == "$candidate" ]]
[[ $(sha256sum /etc/idleleo/conf/xray/config.json | awk '{print $1}') == "$config_sha" ]]
systemctl is-active --quiet xray
user=$(systemctl show xray -p User --value)
[[ -n $user ]] || user=root
runuser -u "$user" -- test -r /usr/local/etc/xray/config.json
runuser -u "$user" -- test -w /var/log/xray/access.log
runuser -u "$user" -- test -w /var/log/xray/error.log
record_binary
echo "Legacy upgrade passed: $scenario, Xray $install_version -> $candidate, service account $user, config unchanged"
