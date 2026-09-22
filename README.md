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
