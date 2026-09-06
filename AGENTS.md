# Zhanlu public build entry

This is the maintained `village-way/vscodium` fork, not a read-only upstream
reference. Changes here use GitHub PRs against the verified default branch
(currently `master`). Preserve the upstream VSCodium license and notices.

## Ownership and routing

- `.github/workflows/`, `create-release.sh`, `scripts/trigger-stable-release.sh`
  and `.agents/skills/zhanlu-build/` own public dispatch and release coordination.
- `build-portal/` owns the Web UI, Worker, immutable source plans, run attribution
  and deployment tooling. Read its local `AGENTS.md` before editing there.
- Platform jobs resolve and fetch `village-way/zhanlu-code` at their selected
  source SHA. Its private authoring repository is `zhanlu-code` in GitLab.
  Trace the exact workflow step before editing a similarly named script here:
  a file replaced by checkout during CI must be fixed in its actual source owner.
- Native Agent implementation belongs in `zhanlu-core/zhanlu-agent`. Legacy
  `zhanlu-vs` inputs still exist in release/mirror contracts; their presence does
  not make that repository the native Agent implementation owner. Do not remove
  them from one layer without tracing the wrapper, portal, workflows and chosen
  packaging revision together.
- VS Code upstream Agents/Sessions, the native Zhanlu Agent mode window and the
  Editor window are different validation surfaces. Packaging checks do not prove
  startup/restore in the native Agent window.

## Routine development

Use an isolated worktree for changes and preserve existing release checkouts,
user changes, generated artifacts and parent gitlinks. Inspect tracked paths and
Git's actual top-level before assuming the checkout or source owner. If inherited
`core.worktree` resolves elsewhere, use `git --work-tree=<absolute-task-path>`
consistently; do not stage apparent deletions or rewrite shared Git configuration. Use the
local `.agents/skills` entrypoint; shared CMSS or Zhanlu workspace Skills, when
available, do not override this public repository's identity or PR destination.
Do not commit internal environment data, credentials or private job traces.

Run checks for the touched layer:

- Rules/docs: `git diff --check` and verify linked paths and actual CLI options.
- Build wrapper: `python3 .agents/skills/zhanlu-build/scripts/test_zhanlu_build.py`.
- Shell/workflow changes: `bash -n` on changed shell scripts, matching tests under
  `scripts/`, and `actionlint` when available. Report unavailable checks.
- Portal: its package-local tests/typecheck; do not start a production Worker or
  perform deployment/migration to validate a documentation change.

Read `.agents/skills/zhanlu-build/SKILL.md` for release execution. A read-only
inspection does not require choosing a new version or approving a source sync.
Keep the exact source-plan approval, source SHA/remote lease checks, draft versus
published visibility, and selected-platform terminal evidence. A dispatch or
successful entry workflow alone is not a successful product build. Continue
independent diagnostics after a blocker and honor explicit no-wait requests.
Do not deploy, publish, mirror refs or delete storage as an incidental PR step.
