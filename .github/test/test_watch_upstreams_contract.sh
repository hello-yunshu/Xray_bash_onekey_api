#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
workflow=${repo}/.github/workflows/watch-upstreams.yml

grep -Fq 'qualify-xray-fresh:' "${workflow}"
grep -Fq 'qualify-xray-upgrade:' "${workflow}"
grep -Fq 'needs: [discover, compatibility-release-gate]' "${workflow}"
grep -Fq 'uses: ./.github/workflows/qualify-legacy-upgrade.yml' "${workflow}"
[[ $(grep -Fc "needs.compatibility-release-gate.result == 'success'" "${workflow}") -eq 1 ]]

for mode in xtls_only ws_grpc_xhttp reality reality_nginx tls; do
    grep -Fq -- "- ${mode}" "${workflow}"
done

for scenario in fresh reinstall remove; do
    grep -Fq -- "- ${scenario}" "${workflow}"
done

if grep -Fq 'for mode in xtls_only ws_grpc_xhttp reality reality_nginx tls' "${workflow}"; then
    echo 'FAIL: five-mode qualification still shares one runner' >&2
    exit 1
fi

grep -Fq "test_installer_candidate_smoke.sh '\${{ matrix.scenario }}'" "${workflow}"
grep -Fq "test_install.sh '\${{ matrix.mode }}'" "${workflow}"
grep -Fq "stage_candidate_metadata.py" "${workflow}"
grep -Fq "exit 1" "${workflow}"

echo 'watch-upstreams workflow contract passed'
