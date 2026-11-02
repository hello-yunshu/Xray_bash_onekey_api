#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
watch=${repo}/.github/workflows/watch-upstreams.yml
qualify=${repo}/.github/workflows/qualify-release.yml
grep -Fq 'python3 .github/scripts/dispatch_upstream_qualification.py' "$watch"
grep -Fq "cron: '23 */6 * * *'" "$watch"
grep -Fq 'CANDIDATE_REF:' "$watch"
! grep -Fq 'git push' "$watch"
grep -Fq 'needs: [inputs, qualify, broken-legacy-recovery, full-install, installer-smoke, minimal-bootstrap]' "$qualify"
# Install modes follow the released Shell; the workflow must not hardcode the
# historical five-mode list that breaks when xtls_only is replaced by relay.
grep -Fq 'python3 .github/scripts/install_modes.py' "$qualify"
grep -Fq 'mode: ${{ fromJSON(needs.inputs.outputs.install_modes) }}' "$qualify"
grep -Fq -- '--modes "$RUNNER_TEMP/install-modes.json"' "$qualify"
! grep -Eq 'mode: \[[^]]*xtls_only' "$qualify"
for scenario in fresh reinstall remove; do grep -Fq "$scenario" "$qualify"; done
echo 'watch-upstreams workflow contract passed'
