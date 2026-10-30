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

After a trusted qualification succeeds, `promote-qualified-release.yml`
publishes and verifies the API snapshot, compatibility evidence and hashes,
then pushes the validated pair together. The push is not forced: a concurrent
main-branch update requires a fresh qualification. Existing clients continue
to use `main/xray_shell_versions.json`.

For an intentional withdrawal of the recommended Xray version, manually
dispatch the same qualification with the desired exact older pair and enable
`allow_rollback`. All ordinary tests, evidence checks, Release verification
and concurrency checks still apply. Scheduled discovery never enables this
option. Changing the recommendation does not itself run an update on a
client's installed Xray.

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
recovery; stopping future promotion does not repair them. GitHub Release
immutability must be checked separately: the workflows reject mismatched
existing assets, but this alone is not GitHub-enforced immutability.
