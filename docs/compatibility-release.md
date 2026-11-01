# Xray compatibility and API releases

`compatibility-baselines.json` lists the released Shell versions supported by
the shared API. Each identity pins a release commit and install script hash.
An optional `initial` tuple provides a known-working starting point for a
historical Shell that cannot install the current online tuple. It does not
change the optimistic concurrency baseline for publication.

`watch-upstreams.yml` discovers an exact Xray and installer pair and dispatches
`qualify-release.yml`. The qualification runs real released Shell scripts on
systemd runners, plus the full install modes, installer smoke tests and minimal
bootstrap checks. The evidence describes the actual paths and environments;
it records the installed binary hash and the hash of a separately downloaded
architecture-specific reference archive whose binary matches it. The fallback
check invokes the historical fallback function directly. A
failed or missing required job prevents publication and promotion. A repeated
run for the current pair does not create a new Release or Shell version.

For released installer smoke harnesses with the known early-exiting version
reader, CI copies that harness and changes only the reader to consume its
input fully, avoiding a `pipefail`/SIGPIPE false failure. The released Shell
and the installer under test are not altered.

While 3.2.9 remains a supported baseline, qualification also reproduces its
documented permission-related offline state, upgrades the installed Shell,
and verifies recovery with the exact candidate pair. The release evidence
records this job and its recovered binary identity; a missing or failed
recovery check blocks promotion.

After a trusted qualification succeeds, `promote-qualified-release.yml`
publishes and verifies the API snapshot, compatibility evidence and hashes,
then pushes the validated pair together. The push is not forced: a concurrent
main-branch update requires a fresh qualification. Existing clients continue
to use `main/xray_shell_versions.json`.

Do not promote an older Xray version to the shared endpoint. Historical
automatic updaters compare versions for inequality and may downgrade a running
client without prompting. The publication gate rejects lower versions even
after successful qualification. Replacing an installer while keeping the
same Xray version remains possible after the full qualification. Safe core
rollback requires a future client-aware strategy.

The publication guard only prevents lowering the shared recommendation. An
older automatic updater can still install that recommendation over a newer
core if the version recorded in its project configuration differs. An external
official installer may not update that configuration, so the binary version
alone does not determine whether the next scheduled update will run. The
3.2.11 fresh-install path also installs the recommended version when the
existing binary differs. Do not claim that this server-side guard prevents
every possible client downgrade.

To propose a new Xray `tested_version`, dispatch `qualify-release.yml` on
`main` with the current online tuple as both base and candidate, and set
`candidate_tested_version` to the proposed fallback. After all jobs succeed,
dispatch `promote_tested_version.yml` for `xray`, passing that exact version
and the qualification run ID. The workflow authenticates the evidence and
current metadata, publishes and verifies an API Release, then updates both
tested-version files. A changed main branch or expired/missing evidence
requires a fresh qualification. The regular online promotion workflow treats
a changed fallback candidate as evidence only.

If any supported Shell fails, keep the existing shared tuple. A successful
test for one release or environment is not a claim that other versions or
environments are compatible. Historical broken installations need separate
recovery; stopping future promotion does not repair them. See the
[observed compatibility failures](compatibility-incidents.md) for exact
candidate and recovery details. GitHub Release
immutability must be checked separately: the workflows reject mismatched
existing assets, but this alone is not GitHub-enforced immutability.

### 发布中断与重复晋级

发布器先创建绑定 qualification、main commit 和资产摘要的草稿，再上传和逐字节核验资产，最后公开。重试仅补传同一草稿中缺少的资产；已有资产不同、草稿身份不符或存在额外资产都会拒绝，不覆盖资产。已公开的 Release 仍只读核验。旧发布器留下且没有身份标记的草稿需要人工核查，不能自动接管。

重复晋级已生效的 tested version（没有新备注，或备注相同）成功退出，不更新时间、不创建提交，也不要求重新提供 qualification。修改备注仍走验证和发布流程。

### 自动下载巡检与受控重试

- `Check production Xray downloads` 每小时 UTC 第 17 分钟检查线上推荐及 tested 版本的 Linux x86_64/arm64 zip 和 dgst 下载端点，以及固定安装器的内容摘要。检查不安装、不改变元数据，也不代表新增架构运行资格。失败显示在 Actions 与 Job Summary 中，通知取决于 GitHub 仓库/账号设置。
- 下载巡检失败后，`Verify and Promote Upstreams` 通过受信任 main 的 workflow_run 自动启动发现；正常发现计划是 UTC `23 */6 * * *`（北京时间约 02:23、08:23、14:23、20:23）。GitHub 定时执行可能延迟。
- 自动资格测试按候选/基线组合、相关元数据和资格流水线内容生成运行标识。不重复启动仍在运行的同组合；已结束的同组合最多每 24 小时重试一次（包括晋级因 main 并发变化而未完成的成功测试）。不同组合立即重新评估。无新组合且下载健康时不发起完整测试。
- 内核和安装器同时更新时，分别验证“新内核 + 已验证安装器”和“新内核 + 新安装器”，防止安装器变更阻塞独立可行的内核升级。任何晋级仍走完整历史基线矩阵和原有证据认证，不因下载故障放宽验证，也不自动降级。
- 巡检不会让失效旧包恢复。若旧基线无法下载且没有可信保留副本，自动资格测试会报告失败并保留现有推荐；更高频率无法替代长期归档。无需客户端升级，install.sh 不变。
