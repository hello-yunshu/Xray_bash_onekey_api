# Observed Xray compatibility failures

These entries describe the exact tested combinations and scenarios. They are
not claims about every Shell version, installation or operating system.
Qualification must still test each proposed combination independently.

## 2026-10-30: installer 9433c4e7 with Xray 26.10.29

The upstream watcher tested Xray `26.10.29` with Xray-install commit
`9433c4e7ce293e0a930fa0708d6865212129510c` (installer SHA-256
`6e91a3041ee4328f6d30330cdd2916439eb0c61cbeb5fbcf8165fe963cec0872`).
[Qualification 41107219625](https://github.com/hello-yunshu/Xray_bash_onekey_api/actions/runs/41107219625)
failed and the candidate was not promoted. The 3.2.9 direct update reported
permission denial and an inactive Xray service.

In [diagnostic run 41107745216](https://github.com/hello-yunshu/Xray_bash_onekey_api/actions/runs/41107745216),
a systemd start failure was injected until the local backup was restored.
The 3.2.9 test started from Xray `26.3.27` with installer `e741a4f`; the
3.2.10 and 3.2.11 tests started from Xray `26.10.29` with the same installer.
All three scripts fell back to Xray `25.12.8`.
The service was inactive for 3.2.9 and active for 3.2.10 and 3.2.11. This
result is specific to that injected failure and tested candidate.

The shared API instead promoted the separately qualified Xray `26.10.29` and
installer `e741a4f56d368afbb9e5be3361b40c4552d3710d` pair in
[API Release api-2026.10.30.41106539411](https://github.com/hello-yunshu/Xray_bash_onekey_api/releases/tag/api-2026.10.30.41106539411).
This prevents the failed candidate being newly recommended; it does not repair
an installation that is already offline.
