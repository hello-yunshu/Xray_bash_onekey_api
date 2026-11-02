# CHANGELOG

## 3.3.0 — 2026-11-02

- Shell 3.3.0 发布元数据：`shell_online_version` 与 `shell_tested_version` 同步为 3.3.0，
  `shell_release_sha256` 绑定 Release 资产；`compatibility-baselines.json` 新增 v3.3.0
  基线（Release commit 与 install.sh 摘要）。
- 资格矩阵改为只读解析已发布 Shell 的 `test_install.sh`：3.2.11 解析为 `xtls_only`，
  3.3.0 解析为 `relay`；证据收集与校验接受 `--modes`，不再硬编码五模式列表。
- 最低直接升级来源：`minimumDirectUpgradeVersion=3.3.0`。3.2.9–3.2.11 只验证
  `shell-first` 与 `reinstall`，3.3.0+ 验证 `direct` 等正常直更路径；不使用
  expected-incompatible 豁免。
