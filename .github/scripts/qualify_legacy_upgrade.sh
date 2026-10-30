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
[[ $scenario == direct || $scenario == shell-first ]]
[[ $base =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $candidate =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ $base_ref =~ ^[0-9a-f]{40}$ && $candidate_ref =~ ^[0-9a-f]{40}$ ]]
[[ $base_sha =~ ^[0-9a-f]{64}$ && $candidate_sha =~ ^[0-9a-f]{64}$ && $expected_sha =~ ^[0-9a-f]{64}$ ]]
[[ $(sha256sum "$legacy/install.sh" | awk '{print $1}') == "$expected_sha" ]]
log=$(mktemp)
trap 'rm -f "$log"' EXIT
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
echo "Installing the legacy shell with Xray $base and the baseline installer"
if ! XRAY_CANDIDATE_VERSION="$base" XRAY_CANDIDATE_INSTALLER_REF="$base_ref" \
    XRAY_CANDIDATE_INSTALLER_SHA256="$base_sha" \
    bash "$legacy/.github/test/test_install.sh" reality >"$log" 2>&1; then
    echo 'Legacy baseline installation failed; candidate not evaluated' >&2
    diagnose
    exit 1
fi
systemctl is-active --quiet xray
config_sha=$(sha256sum /etc/idleleo/conf/xray/config.json | awk '{print $1}')
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
runuser -u "$user" -- test -w /var/log/xray
echo "Legacy upgrade passed: $scenario, Xray $base -> $candidate, service account $user, config unchanged"
