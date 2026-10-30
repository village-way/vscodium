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
The wait job needs `contents: write` because GitHub only lists Draft Releases
for callers with push access. It only reads release metadata and has no OIDC
permission; the publication job keeps `contents: read`.

Configure `RELEASE_METADATA_ASSET` with the existing delivery metadata asset
filename. The source supplies `scripts/npm-package-runtime.mjs` and
`scripts/publish-npm-package.sh` under `SOURCE_SUBDIR`. The source read App and
repository variables are shared with the platform builds.
The runtime helper must declare `publication-format=1`; older sources stop
before publication rather than ignoring the prepare/publish phases.

The npm package's Trusted Publisher must authorize this owner/repository and
`publish-package.yml`, allowing direct publication and dist-tag management.
Only the publication job requests `id-token: write`; no npm token is needed.
The job pins npm 11.21.0 and reads Bun's version from the source. Package jobs
queue serially using GitHub's `queue: max` concurrency option.

Retry the package Action against the original platform run IDs after correcting
a failed platform or npm permission. Existing matching package content is reused
and channel promotion is repaired. An immutable version with different content
is rejected, and older releases do not move installation channels backwards.
Before the first npm write, the publication job preserves the complete public
tarball bundle for seven days. Retries of the same Action restore those exact
bytes and verify the pinned source, version, channel and every package digest.
Only prepared public packages are stored; source checkouts are excluded. Expired
or ambiguous publication artifacts stop recovery.
If the workflow was updated after the platform batch started, set
`platform_workflow_commit` to that batch's original workflow SHA while preserving
its request ID and run IDs. The release lookup includes drafts by matching the
exact tag in the paginated releases list; GitHub's tag endpoint returns published
releases only.
## Optional private source transport

Stable platform workflows accept `private_source_repository` (`owner/name`).
Configure `PRIVATE_SOURCE_DEPLOY_KEY` with a read/write deploy key restricted to
that private repository. Keep Actions disabled on the source mirror so importing
source branches cannot execute their workflows. The normal source App path is
unchanged when the input is empty.

This mode fetches the requested immutable source commit over authenticated SSH.
Linux and Windows compile intermediates remain encrypted and are stored only on
`build-artifacts/<run-id>` branches in the same private repository. Chunks are
limited to 32 MiB and pushed in bounded batches; a completion manifest binds the
run, source commit, workflow commit, Profile digest, sizes and checksums. Consumers
validate that manifest and every chunk before restoring the archive. A blocking
read/write probe runs before compilation. These source intermediates are never
uploaded to this public repository's Actions artifacts or Release assets.

Intermediate branches are retained for diagnosis. Final installer assets may be
uploaded separately to the selected draft Release. Dispatching the three platform
workflows does not dispatch package publication; callers that prohibit registry
publication must not invoke the default publication wrapper.
