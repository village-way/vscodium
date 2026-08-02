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
- Use `develop` for zhanlu-code, zhanlu-core, and zhanlu-vs.
- Use delivery Profile `default`, workflow dispatch, and platform `all`.
- Do not bundle the optional Codex CLI runtime by default; its build input is `0`.
- Before every applied build or release, preview and then synchronize the five
  component repositories from GitLab to GitHub. Use default branches for the
  normal `develop` flow and all refs when any requested source ref is not
  `develop`.
- Keep the GitHub Release as draft unless the user explicitly requests
  publication.
- Sync the five component GitLab repositories for formal releases; do not sync
  them for development releases.
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
   for five components, and dispatch workflows.
5. Only after explicit confirmation in the current conversation, repeat the
   same command with `--apply`.
6. During apply, run `sync-zhanlu-gitlab-to-github.sh --dry-run` first. Continue
   to the real synchronization only when the preview exits zero; continue to
   release creation only when the real synchronization exits zero.
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
```

Use `--source-branch`, `--zhanlu-core-ref`, `--zhanlu-vs-ref`,
`--delivery-profile`, or `--time-patch` only when the user explicitly selects a
non-default source or patch.

## Safety Rules

- Treat `--apply` as the remote-mutation gate. Dry-run must not call GitHub,
  GitLab, fetch, tag, release, or workflow APIs.
- On apply, run the source synchronization preview and real synchronization
  before release preflight, creation, or workflow dispatch. Treat exit code 1
  (partial/skipped refs) and exit code 2 (configuration/authentication failure)
  as blocking failures.
- Use the synchronization script's default-branch mode when all three build
  refs are `develop`; add `--all-refs` when source-branch, zhanlu-core-ref, or
  zhanlu-vs-ref selects anything else.
- Require the release checkout to be clean, on `master`, and equal to
  `origin/master` after fetch.
- Before formal GitLab synchronization, require `zhanlu-cloud`, `zhanlu-code`,
  `zhanlu-core`, `zhanlu-loc`, and `zhanlu-vs` to be clean, on `develop`, and
  equal to `origin/develop` after fetch.
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
