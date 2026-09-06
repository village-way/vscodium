# Build Portal development

The parent `AGENTS.md` defines public build ownership. This package owns the
manual release portal; product builds execute through the parent wrapper and
GitHub workflows, not through `pnpm build`.

## Locate and validate

- `apps/web`: Next.js UI/API; `apps/worker`: queue/lease execution and source sync.
- `packages/contracts`: request/source-plan schemas shared by Web and Worker.
- `packages/release-runner`: exact wrapper arguments and run attribution.
- `packages/db`: SQLite/WAL, migrations, backup and task leases.
- `packages/auth`, `packages/github-app`: authentication and credential handling.
- `deploy/`: production changes and the separately destructive legacy cleanup.

Use the versions pinned in `package.json` (Node 22.x and pnpm 10.17.1), and run
commands from `build-portal/`: `pnpm install --frozen-lockfile` when dependencies
are needed, then the relevant `pnpm test` and `pnpm typecheck`. Run `pnpm build`
for affected Web/bundle integration. Tests use temporary state; never point them
at production SQLite, credentials, cache repositories or deployed endpoints.
Documentation-only changes need path/link checks and `git diff --check`.
Missing dependencies block dependent checks, not source review or other preparation.

## Preserve these contracts

Preview and execute the same immutable source plan. Verify GitLab source SHAs
and exact GitHub destination leases again before mutation. Portal execution uses
selected refs, never all-refs. Preserve transaction/lease ownership and recovery;
a canceled client or timed-out request is not evidence the remote run stopped.
Bind results to request ID, source/workflow SHA and exact platform run IDs; keep
pending, failure and successful artifact acceptance distinct. Never log tokens,
passwords, cookies or private keys, or reuse live credentials in test fixtures.

A coding request does not authorize launching the live Worker, `db:migrate`,
bootstrap, backups, Docker push, Kubernetes deployment or storage cleanup.
Reuse an explicit approval only for its exact target and operation. In particular,
`deploy/scripts/cleanup-legacy.sh` is a one-time irreversible migration cleanup,
not a routine post-deploy check. Require explicit approval naming its current
resources and backups before execution; its built-in target checks remain required.
