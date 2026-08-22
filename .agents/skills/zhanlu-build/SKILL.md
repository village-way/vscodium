---
name: zhanlu-build
description: Synchronize Zhanlu component source from GitLab to GitHub, then prepare and run Zhanlu IDE development or formal releases through the workspace vscodium release scripts, including version/time-patch pinning, GitHub Release creation, optional component GitLab release synchronization, macOS/Linux/Windows workflow dispatch, and run monitoring. Use when asked to build, publish, release, rerun, or inspect a Zhanlu IDE release such as 1.4.15061 or 1.4.1. Do not use for writing the unified user-facing GitLab release notes; use zhanlu-release for that.
---

# Zhanlu Build

Use the bundled wrapper instead of assembling `create-release.sh` and
`trigger-stable-release.sh` arguments manually.

## Defaults

- Store this skill in the current `/Volumes/Files/vscodium` project, but run
  releases from the canonical `/Volumes/Files/zhanlu-ide/vscodium` checkout.
  Do not run release commands from the older standalone checkout that contains
  this skill.
- Use the selected VSCodium workflow branch, `develop` for zhanlu-code and zhanlu-core, and no zhanlu-vs ref for the native Agent architecture. Pass zhanlu-vs only for legacy VSIX builds.
- Use delivery Profile `default`, workflow dispatch, and platform `all`.
- Do not bundle the optional Codex CLI runtime by default; its build input is `0`.
- For an interactive wrapper invocation, preview and then synchronize the
  required component repositories from GitLab to GitHub. Use default branches for the
  normal `develop` flow and all refs when any requested source ref is not
  `develop`.
- For build-portal invocations, preview an immutable plan containing `develop`
  for the four native-Agent components plus distinct selected zhanlu-code and
  zhanlu-core refs. Include zhanlu-vs only when a legacy source is selected. Apply that exact plan with
  `--portal-source-sync --confirmed-source-plan`; never add `--all-refs`.
- Keep the GitHub Release as draft unless the user explicitly requests
  publication.
- Sync the four native-Agent component GitLab repositories for formal releases,
  plus zhanlu-vs only when selected; do not sync them for development releases.
- Wait for the selected workflow runs to finish unless the user asks to return
  immediately after dispatch.

## Workflow

1. Require the release kind and version.
   - Development with a base version: `development 1.4.1` resolves once to a
     time-patched release such as `1.4.15079`.
   - Development with an exact version: `development 1.4.15061` reuses `5061`
     as the internal time patch.
   - Formal: `formal 1.4.1` keeps the public version free of the time patch and
     pins one internal four-digit patch for every platform.
2. Run the wrapper without `--apply`:

   ```bash
   python3 .agents/skills/zhanlu-build/scripts/zhanlu_build.py \
     --kind <development|formal> --version <version>
   ```

3. Show the resolved release version, internal patch, refs, Profile, platform,
   visibility, source-mirror scope, GitLab-release-sync decision, repository
   state, component SHAs, and exact native commands. Never expose token values.
4. Ask the user to confirm that exact plan. Explain that applying it may push a
   component branches or tags from GitLab to GitHub, push a GitHub release
   tag/commit, create or edit a GitHub Release, create GitLab tags and releases
   for the selected components, and dispatch workflows.
5. Only after explicit confirmation in the current conversation, repeat the
   same command with `--apply`.
6. During an interactive apply, run
   `sync-zhanlu-gitlab-to-github.sh --dry-run` first. For build-portal apply,
   the Worker must already have run `sync-zhanlu-selected-refs.sh --dry-run`
   for all required `develop` refs plus distinct selected build refs. Apply only
   that user-confirmed immutable plan. Continue to synchronization only when
   every preview succeeds; continue to release creation only when every
   synchronization succeeds.
7. Report the source synchronization result, GitHub Release URL, GitLab release
   synchronization result, workflow run URLs, conclusions, and failed job
   names. Do not call a release successful until every selected workflow has
   reached a successful terminal state.

## Common Overrides

Use only overrides requested by the user:

```bash
# Bundle the optional Codex CLI runtime for an experimental development build
python3 .agents/skills/zhanlu-build/scripts/zhanlu_build.py \
  --kind development --version 1.4.1 --bundle-codex-runtime 1

# Formal release without component GitLab synchronization
python3 .agents/skills/zhanlu-build/scripts/zhanlu_build.py \
  --kind formal --version 1.4.1 --no-gitlab

# Re-run one platform against an existing release without recreating it
python3 .agents/skills/zhanlu-build/scripts/zhanlu_build.py \
  --kind formal --version 1.4.1 --trigger-only --platform windows

# Publish instead of retaining the default GitHub draft
python3 .agents/skills/zhanlu-build/scripts/zhanlu_build.py \
  --kind formal --version 1.4.1 --publish

# Dispatch and return without monitoring
python3 .agents/skills/zhanlu-build/scripts/zhanlu_build.py \
  --kind development --version 1.4.1 --no-wait

# Machine-readable legacy selected-ref dispatch; the final JSON line uses
# schema v1 and contains resolved sourceRefs plus exact workflow run IDs/URLs
python3 .agents/skills/zhanlu-build/scripts/zhanlu_build.py \
  --kind development --version 1.4.1 --platform linux \
  --request-id 71efcf01-7b10-4db0-9efd-f2af58f26a81 \
  --selected-source-sync --generate-only --no-wait --output json
```

Use `--workflow-ref`, `--source-branch`, `--zhanlu-core-ref`, `--zhanlu-vs-ref`,
`--delivery-profile`, or `--time-patch` only when the user explicitly selects a
non-default source or patch.

## Safety Rules

- Treat `--apply` as the remote-mutation gate. Dry-run must not call GitHub,
  GitLab, fetch, tag, release, or workflow APIs.
- On apply, run the source synchronization preview and real synchronization
  before release preflight, creation, or workflow dispatch. Treat exit code 1
  (partial/skipped refs) and exit code 2 (configuration/authentication failure)
  as blocking failures.
- For direct interactive builds, use the synchronization script's
  default-branch mode when all selected build refs are `develop`; add `--all-refs`
  when one selects anything else. This legacy mirror-maintenance behavior does
  not apply to the build portal.
- For portal builds, GitLab is authoritative. Before the first remote write,
  preview all required component `develop` refs plus distinct selected build refs.
  Update only those planned GitHub refs with exact
  `--force-with-lease=<ref>:<preview-sha>`. Never use an unconditional force
  push. Preserve the confirmed plan and resolved build commits for recovery.
- Require the release checkout to be clean, on the selected workflow branch,
  and equal to the corresponding origin branch after fetch.
- Before formal GitLab synchronization, require `zhanlu-cloud`, `zhanlu-code`,
  `zhanlu-core`, and `zhanlu-loc` to be clean, on `develop`, and equal to
  `origin/develop` after fetch; require the same for zhanlu-vs only when selected.
- Load GitLab credentials from the process or the ignored workspace `.env`.
  Never print credentials or place them in command arguments.
- Never enable `GITLAB_FORCE_TAG_UPDATE`; stop on conflicting existing tags.
- Stop before dispatch when Release creation fails.
- Stop before preflight and Release creation when either source synchronization
  phase fails.
- Stop workflow attribution when more than one new matching run appears; report
  the ambiguity instead of watching the wrong run.
- Use `--trigger-only` for retries of an existing Release. Pair it with
  `--publish` when the existing GitHub Release is already published so the
  native trigger does not try to restore draft visibility.
- Reserve `--request-id` and `--output json` for machine callers. The native
  workflow dispatch must return one exact run ID and URL per selected platform;
  a missing response or ambiguous request-ID lookup is a blocking failure.
- Use `--generate-only` only for development workflow-artifact validation. It
  must not create, read, publish, or upload to a GitHub Release.

## Scope Boundary

Use `$zhanlu-release` separately when the user wants the unified, product-facing
GitLab release notes or parent `zhanlu-ide` release. This skill intentionally
uses the native `create-release.sh -g` component synchronization and does not
replace the release-notes workflow.

## Validation

After editing this skill, run:

```bash
python3 .agents/skills/zhanlu-build/scripts/test_zhanlu_build.py
python3 /Users/peng/.codex/skills/.system/skill-creator/scripts/quick_validate.py \
  .agents/skills/zhanlu-build
git diff --check -- .agents/skills/zhanlu-build
```
