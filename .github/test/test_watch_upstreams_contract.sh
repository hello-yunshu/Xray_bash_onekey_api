#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
watch=${repo}/.github/workflows/watch-upstreams.yml
qualify=${repo}/.github/workflows/qualify-release.yml
grep -Fq 'gh workflow run qualify-release.yml --ref main' "$watch"
grep -Fq 'candidate_installer_ref="$CANDIDATE_REF"' "$watch"
! grep -Fq 'git push' "$watch"
grep -Fq 'needs: [inputs, qualify, broken-legacy-recovery, full-install, installer-smoke, minimal-bootstrap]' "$qualify"
for mode in xtls_only ws_grpc_xhttp reality reality_nginx tls; do grep -Fq "$mode" "$qualify"; done
for scenario in fresh reinstall remove; do grep -Fq "$scenario" "$qualify"; done
echo 'watch-upstreams workflow contract passed'
