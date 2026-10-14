# Build Automation

Build automation and release staging for an internal editor distribution.

This repository only contains the CI entry points. The build inputs are fetched
from a private source repository at run time. Releases here are staging drafts.

Not accepting issues or pull requests.

Source-bearing intermediate artifacts are encrypted with AES-256-GCM before
upload. Configure `SOURCE_ARTIFACT_KEY` as a repository Actions secret containing
32 cryptographically random bytes encoded as 64 hexadecimal characters. Do not
reuse an access token as this key. Missing keys and unauthenticated or legacy
plaintext archives fail the build; no plaintext fallback is supported.

Both the entry workflow and private build scripts must include this contract.
Download jobs authenticate the archive in the same repository/run context before
extracting it. Retry jobs from the same run before rotating the key, or start a
fresh run after rotation. Source archives and source maps are not release assets.

Git credentials are supplied per command, without credential-bearing URLs or
persistent helpers. Build-security tests run without production secrets on Linux,
Windows and macOS. These controls protect public artifacts; the CI platform and
trusted build jobs necessarily have access to build inputs and secrets. Existing
artifacts and logs require separate incident cleanup and credential rotation.

Package publication runs in `publish-package.yml` after the exact selected
platform run IDs all succeed. Only the standard delivery profile with Release
output enables publication; workflow-artifact output and customer profiles skip
it. Draft Releases are eligible. The package uses the release's pinned source
commit, with `latest` for formal releases and `next` for development releases.

Configure `RELEASE_METADATA_ASSET` with the existing delivery metadata asset
filename. The source supplies `scripts/npm-package-runtime.mjs` and
`scripts/publish-npm-package.sh` under `SOURCE_SUBDIR`. The source read App and
repository variables are shared with the platform builds.

The npm package's Trusted Publisher must authorize this owner/repository and
`publish-package.yml`, allowing direct publication and dist-tag management.
Only the publication job requests `id-token: write`; no npm token is needed.
The job pins npm 11.21.0 and reads Bun's version from the source. Package jobs
queue serially using GitHub's `queue: max` concurrency option.

Retry the package Action against the original platform run IDs after correcting
a failed platform or npm permission. Existing matching package content is reused
and channel promotion is repaired. An immutable version with different content
is rejected, and older releases do not move installation channels backwards.
