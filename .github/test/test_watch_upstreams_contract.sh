#!/usr/bin/env bash

set -euo pipefail

repo=$(cd "$(dirname "$0")/../.." && pwd)
workflow=${repo}/.github/workflows/watch-upstreams.yml

grep -Fq 'qualify-xray-fresh:' "${workflow}"
grep -Fq 'qualify-xray-upgrade:' "${workflow}"
grep -Fq 'needs: [discover, qualify-xray-fresh, qualify-xray-upgrade]' "${workflow}"

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
grep -Fq "needs.qualify-xray-fresh.result == 'success'" "${workflow}"
grep -Fq "needs.qualify-xray-upgrade.result == 'success'" "${workflow}"

echo 'watch-upstreams workflow contract passed'
