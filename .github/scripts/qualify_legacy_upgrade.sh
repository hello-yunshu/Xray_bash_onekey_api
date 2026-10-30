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
[[ $scenario == fresh || $scenario == direct || $scenario == shell-first || $scenario == reinstall || $scenario == failure-recovery ]]
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
if [[ $scenario == reinstall ]]; then
    [[ $(jq -r '.xray_version // empty' /etc/idleleo/conf/install_config.json) == "$candidate" ]]
    [[ $(/usr/local/bin/xray version | awk 'NR==1 {sub(/^v/, "", $2); print $2}') == "$candidate" ]]
fi
if [[ $scenario == fresh ]]; then
    [[ $(/usr/local/bin/xray version | awk 'NR==1 {sub(/^v/, "", $2); print $2}') == "$candidate" ]]
    user=$(systemctl show xray -p User --value)
    [[ -n $user ]] || user=root
    runuser -u "$user" -- test -r /usr/local/etc/xray/config.json
    runuser -u "$user" -- test -w /var/log/xray
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
    echo "Legacy failure recovery passed: retained Xray $base and original config"
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
runuser -u "$user" -- test -w /var/log/xray
echo "Legacy upgrade passed: $scenario, Xray $install_version -> $candidate, service account $user, config unchanged"
