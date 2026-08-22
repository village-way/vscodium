import { execFile } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { hostname } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { buildSpecSchema, confirmationHash, resolveReleaseVersion, type BuildPhase, type BuildSpec } from "@zhanlu/build-portal-contracts";
import { appendBuildEvent, closeDatabase, getDatabase, id, now, parseJson, transaction } from "@zhanlu/build-portal-db";
import { assertRepositoryAccess, github, installationToken, startCredentialBroker } from "@zhanlu/build-portal-github-app";
import { runRelease, type SourceRefResult, type SourceRefs } from "@zhanlu/build-portal-release-runner";
import { configureReleaseGitIdentity } from "./git-identity.js";
import { prepareGitlabCliEnvironment } from "./gitlab-cli.js";

const exec = promisify(execFile);
const WORKER_ID = process.env.WORKER_ID ?? hostname();
const VERSION = process.env.PORTAL_VERSION ?? "development";
const WORKSPACE_ROOT = process.env.WORKSPACE_ROOT ?? "/var/lib/zhanlu-build/work";
const GIT_CACHE_ROOT = process.env.GIT_CACHE_ROOT ?? "/var/lib/zhanlu-build/git-cache";
const POLL_MS = Number(process.env.WORKER_POLL_MS ?? 3000);
const LEASE_MS = 10 * 60_000;
const componentRepositories = ["zhanlu-cloud", "zhanlu-code", "zhanlu-core", "zhanlu-loc", "zhanlu-vs"] as const;
const buildRepositories = ["zhanlu-code", "zhanlu-core", "zhanlu-vs"] as const;
const requiredComponentRepositories = ["zhanlu-cloud", "zhanlu-code", "zhanlu-core", "zhanlu-loc"] as const; // zhanlu_change
const workflowByPlatform = { macos: "stable-macos.yml", linux: "stable-linux.yml", windows: "stable-windows.yml" } as const;

type RepositoryUrls = string | { github?: string; gitlab?: string };
type BuildRow = {
  id: string;
  request_id: string;
  spec: BuildSpec;
  resolved: Record<string, unknown>;
  phase: BuildPhase;
};

function repositoryConfig(): Record<string, RepositoryUrls> {
  const raw = process.env.REPOSITORIES_JSON;
  if (!raw) throw new Error("REPOSITORIES_JSON is required");
  const value = JSON.parse(raw) as Record<string, RepositoryUrls>;
  for (const name of ["vscodium", ...requiredComponentRepositories]) if (!value[name]) throw new Error(`repository URL missing for ${name}`); // zhanlu_change - legacy zhanlu-vs config is optional
  return value;
}

function repositoryUrl(name: string, provider: "github" | "gitlab"): string {
  const value = repositoryConfig()[name];
  const url = typeof value === "string" ? value : value?.[provider];
  if (!url) throw new Error(`${provider} URL missing for ${name}`);
  return url;
}

async function git(args: string[], cwd?: string): Promise<string> {
  const result = await exec("git", args, { cwd, env: process.env, maxBuffer: 16 * 1024 * 1024 });
  return result.stdout.trim();
}

function selectedPlatforms(spec: BuildSpec): Array<keyof typeof workflowByPlatform> {
  return spec.platform === "all" ? ["macos", "linux", "windows"] : [spec.platform];
}

function rowFromDatabase(row: Record<string, unknown>): BuildRow {
  return {
    id: String(row.id),
    request_id: String(row.request_id),
    spec: buildSpecSchema.parse(parseJson(row.spec, {})),
    resolved: parseJson(row.resolved, {}),
    phase: row.phase as BuildPhase,
  };
}

export function claimBuild(): BuildRow | null {
  return transaction((database) => {
    const candidate = database.prepare(`
      SELECT * FROM builds
      WHERE phase IN ('preview_queued','previewing','queued','source_sync','preflight','dispatching')
        AND (lease_expires_at IS NULL OR lease_expires_at < ?)
      ORDER BY created_at
      LIMIT 1
    `).get(now()) as Record<string, unknown> | undefined;
    if (!candidate) return null;
    const changed = database.prepare("UPDATE builds SET lease_owner=?,lease_expires_at=?,updated_at=? WHERE id=? AND (lease_expires_at IS NULL OR lease_expires_at<?)")
      .run(WORKER_ID, now() + LEASE_MS, now(), String(candidate.id), now());
    return changed.changes === 1 ? rowFromDatabase(candidate) : null;
  });
}

function setPhase(buildId: string, phase: BuildPhase, reason?: string): void {
  getDatabase().prepare("UPDATE builds SET phase=?,phase_reason=?,lease_expires_at=?,updated_at=? WHERE id=?")
    .run(phase, reason ?? null, now() + LEASE_MS, now(), buildId);
  appendBuildEvent(buildId, "phase.changed", { phase, reason });
}

function storeResolved(buildId: string, resolved: Record<string, unknown>, hash?: string): void {
  getDatabase().prepare("UPDATE builds SET resolved=?,confirmation_hash=COALESCE(?,confirmation_hash),updated_at=? WHERE id=?")
    .run(JSON.stringify(resolved), hash ?? null, now(), buildId);
}

function storePreview(buildId: string, spec: BuildSpec, resolved: Record<string, unknown>, hash: string): void {
  getDatabase().prepare("UPDATE builds SET spec=?,resolved=?,confirmation_hash=?,updated_at=? WHERE id=?")
    .run(JSON.stringify(spec), JSON.stringify(resolved), hash, now(), buildId);
}

function isDevelop(ref: string): boolean { return ref === "develop" || ref === "refs/heads/develop"; }

// zhanlu_change start - zhanlu-vs is a legacy source input after the native Agent migration
function selectedComponentRepositories(spec: BuildSpec): readonly string[] {
  return spec.zhanluVsRef ? componentRepositories : requiredComponentRepositories;
}

function selectedBuildRepositories(spec: BuildSpec): readonly string[] {
  return spec.zhanluVsRef ? buildRepositories : buildRepositories.slice(0, 2);
}
// zhanlu_change end

export function portalSyncArguments(spec: BuildSpec, planFile: string): string[] {
  const args = ["./scripts/sync-zhanlu-selected-refs.sh", "--dry-run"];
  for (const repository of selectedComponentRepositories(spec)) args.push("--ref", `${repository}=develop`); // zhanlu_change
  const selected: Array<[string, string]> = [
    ["zhanlu-code", spec.sourceBranch],
    ["zhanlu-core", spec.zhanluCoreRef],
    ...(spec.zhanluVsRef ? [["zhanlu-vs", spec.zhanluVsRef] as [string, string]] : []), // zhanlu_change
  ];
  for (const [repository, ref] of selected) if (!isDevelop(ref)) args.push("--ref", `${repository}=${ref}`);
  args.push("--output-plan", planFile);
  return args;
}

export function parseSourcePlan(contents: string, spec: BuildSpec): { mirrorPlan: SourceRefResult[]; sourceRefs: SourceRefs } {
  const mirrorPlan = contents.trim().split("\n").filter(Boolean).map((line, index) => {
    const fields = line.split("\t");
    if (fields.length !== 9) throw new Error(`invalid source plan row ${index + 1}`);
    const [repository, refType, requestedRef, sourceRef, destinationRef, gitlabObjectSha, gitlabSha, previous, action] = fields as [string, string, string, string, string, string, string, string, string];
    if (!componentRepositories.includes(repository as typeof componentRepositories[number])) throw new Error(`unexpected repository in source plan: ${repository}`);
    if (!/^[0-9a-f]{40}$/.test(gitlabObjectSha) || !/^[0-9a-f]{40}$/.test(gitlabSha)) throw new Error(`invalid GitLab SHA for ${repository}`);
    if (previous !== "-" && !/^[0-9a-f]{40}$/.test(previous)) throw new Error(`invalid GitHub lease for ${repository}`);
    return { repository, refType, requestedRef, sourceRef, destinationRef, gitlabSha, gitlabObjectSha, previousGithubSha: previous === "-" ? "" : previous, action };
  });
  const develop = new Set(mirrorPlan.filter((item) => item.destinationRef === "refs/heads/develop").map((item) => item.repository));
  const expectedDevelop = selectedComponentRepositories(spec); // zhanlu_change
  if (develop.size !== expectedDevelop.length || expectedDevelop.some((repository) => !develop.has(repository))) throw new Error(`source plan does not contain all ${expectedDevelop.length} required develop refs`);
  const requested: Record<string, string> = { "zhanlu-code": spec.sourceBranch, "zhanlu-core": spec.zhanluCoreRef, ...(spec.zhanluVsRef ? { "zhanlu-vs": spec.zhanluVsRef } : {}) }; // zhanlu_change
  const sourceRefs: SourceRefs = {};
  for (const repository of selectedBuildRepositories(spec)) { // zhanlu_change
    const matches = mirrorPlan.filter((item) => item.repository === repository && (item.requestedRef === requested[repository] || (isDevelop(requested[repository]!) && item.destinationRef === "refs/heads/develop")));
    if (matches.length !== 1) throw new Error(`source plan did not resolve exactly one ${repository} build ref`);
    sourceRefs[repository] = matches[0]!;
  }
  const destinations = mirrorPlan.map((item) => `${item.repository}\0${item.destinationRef}`);
  if (new Set(destinations).size !== destinations.length) throw new Error("source plan contains duplicate destination refs");
  return { mirrorPlan, sourceRefs };
}

async function prepareBareCache(name: string, provider: "github" | "gitlab", branch: string): Promise<string> {
  await mkdir(GIT_CACHE_ROOT, { recursive: true });
  const cache = path.join(GIT_CACHE_ROOT, `${name}.git`);
  try { await git([`--git-dir=${cache}`, "rev-parse", "--is-bare-repository"]); }
  catch { await git(["init", "--bare", cache]); }
  const url = repositoryUrl(name, provider);
  const remote = provider === "github" && name === "vscodium" ? "origin" : provider;
  try { await git([`--git-dir=${cache}`, "remote", "set-url", remote, url]); }
  catch { await git([`--git-dir=${cache}`, "remote", "add", remote, url]); }
  if (provider === "gitlab") {
    try { await git([`--git-dir=${cache}`, "remote", "set-url", "origin", url]); }
    catch { await git([`--git-dir=${cache}`, "remote", "add", "origin", url]); }
  }
  await git([`--git-dir=${cache}`, "worktree", "prune", "--expire=now"]);
  await git([`--git-dir=${cache}`, "fetch", "--force", "--no-tags", remote, `+refs/heads/${branch}:refs/remotes/origin/${branch}`]);
  return cache;
}

type PreparedWorkspace = { root: string; worktrees: Array<{ cache: string; directory: string }> };

async function prepareWorkspace(build: BuildRow): Promise<PreparedWorkspace> {
  const root = path.join(WORKSPACE_ROOT, build.request_id);
  await rm(root, { recursive: true, force: true });
  await mkdir(root, { recursive: true });
  const worktrees: PreparedWorkspace["worktrees"] = [];
  const add = async (name: string, provider: "github" | "gitlab", branch: string) => {
    const cache = await prepareBareCache(name, provider, branch);
    const directory = path.join(root, name);
    await git([`--git-dir=${cache}`, "worktree", "add", "--force", "-B", branch, directory, `refs/remotes/origin/${branch}`]);
    worktrees.push({ cache, directory });
  };
  await add("vscodium", "github", build.spec.vscodiumRef); // zhanlu_change
  await configureReleaseGitIdentity(path.join(root, "vscodium"));
  if (build.spec.kind === "formal" && build.spec.syncGitLab) {
    for (const repository of selectedComponentRepositories(build.spec)) await add(repository, "gitlab", "develop"); // zhanlu_change
  }
  return { root, worktrees };
}

async function cleanWorkspace(prepared: PreparedWorkspace): Promise<void> {
  for (const worktree of prepared.worktrees.reverse()) {
    await git([`--git-dir=${worktree.cache}`, "worktree", "remove", "--force", worktree.directory]).catch(() => undefined);
    await git([`--git-dir=${worktree.cache}`, "worktree", "prune", "--expire=now"]).catch(() => undefined);
  }
  await rm(prepared.root, { recursive: true, force: true });
}

async function previewBuild(build: BuildRow): Promise<void> {
  setPhase(build.id, "previewing");
  const prepared = await prepareWorkspace(build);
  try {
    const planFile = path.join(prepared.root, ".portal-source-plan.tsv");
    await exec("bash", portalSyncArguments(build.spec, planFile), { cwd: path.join(prepared.root, "vscodium"), env: process.env, maxBuffer: 16 * 1024 * 1024 });
    const planTsv = await readFile(planFile, "utf8");
    const parsed = parseSourcePlan(planTsv, build.spec);
    const version = resolveReleaseVersion(build.spec);
    const pinnedSpec = buildSpecSchema.parse({ ...build.spec, timePatch: version.timePatch });
    const resolved = { ...build.resolved, ...version, sourceRefs: parsed.sourceRefs, mirrorPlan: parsed.mirrorPlan, syncPlanTsv: planTsv, previewedAt: new Date().toISOString() };
    const secret = process.env.CONFIRMATION_SECRET;
    if (!secret) throw new Error("CONFIRMATION_SECRET is required");
    const hash = confirmationHash({ spec: pinnedSpec, resolved }, secret);
    storePreview(build.id, pinnedSpec, resolved, hash);
    setPhase(build.id, "awaiting_confirmation");
  } finally {
    await cleanWorkspace(prepared);
  }
}

function saveRuns(build: BuildRow, runs: Array<{ workflow: string; runId: number; url: string }>): void {
  const expected = selectedPlatforms(build.spec);
  if (runs.length !== expected.length) throw new Error(`expected ${expected.length} workflow runs, received ${runs.length}`);
  const timestamp = now();
  for (const item of runs) {
    const platform = Object.entries(workflowByPlatform).find(([, workflow]) => workflow === item.workflow)?.[0];
    if (!platform || !expected.includes(platform as typeof expected[number])) throw new Error(`unexpected workflow ${item.workflow}`);
    getDatabase().prepare(`INSERT INTO build_runs(id,build_id,platform,workflow,run_id,run_url,status,created_at,updated_at)
      VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(build_id,platform) DO UPDATE SET workflow=excluded.workflow,run_id=excluded.run_id,run_url=excluded.run_url,status=excluded.status,updated_at=excluded.updated_at`)
      .run(id(), build.id, platform, item.workflow, String(item.runId), item.url, "dispatched", timestamp, timestamp);
  }
}

async function discoverRuns(build: BuildRow): Promise<Array<{ workflow: string; runId: number; url: string }>> {
  const owner = process.env.GITHUB_OWNER;
  const repo = process.env.GITHUB_REPOSITORY_NAME ?? "vscodium";
  if (!owner) throw new Error("GITHUB_OWNER is required");
  const client = await github();
  const found: Array<{ workflow: string; runId: number; url: string }> = [];
  for (const platform of selectedPlatforms(build.spec)) {
    const workflow = workflowByPlatform[platform];
    const response = await client.actions.listWorkflowRuns({ owner, repo, workflow_id: workflow, event: "workflow_dispatch", per_page: 50 });
    const matches = response.data.workflow_runs.filter((item) => item.display_title?.includes(build.request_id));
    if (matches.length > 1) throw new Error(`ambiguous workflow attribution for ${workflow}`);
    if (matches[0]) found.push({ workflow, runId: matches[0].id, url: matches[0].html_url });
  }
  return found;
}

async function recoverDispatch(build: BuildRow): Promise<void> {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    const runs = await discoverRuns(build);
    if (runs.length === selectedPlatforms(build.spec).length) {
      saveRuns(build, runs);
      setPhase(build.id, "succeeded", "GitHub Actions dispatched");
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 10_000));
  }
  throw new Error("dispatch recovery could not attribute every selected workflow; refusing to dispatch duplicates");
}

async function dispatchBuild(build: BuildRow): Promise<void> {
  if (build.phase === "dispatching") return recoverDispatch(build);
  const planTsv = typeof build.resolved.syncPlanTsv === "string" ? build.resolved.syncPlanTsv : "";
  const sourceRefs = build.resolved.sourceRefs as SourceRefs | undefined;
  if (!planTsv || !sourceRefs) throw new Error("confirmed source plan is missing");
  const prepared = await prepareWorkspace(build);
  try {
    const planFile = path.join(prepared.root, ".confirmed-source-plan.tsv");
    await writeFile(planFile, planTsv, { mode: 0o600 });
    const token = await installationToken();
    process.env.GH_TOKEN = token;
    process.env.GITHUB_TOKEN = token;
    setPhase(build.id, "source_sync");
    const result = await runRelease(build.spec, build.request_id, {
      workspace: prepared.root,
      apply: true,
      confirmedSourcePlan: planFile,
      sourceRefs,
      onLog: async (line) => {
        if (line.startsWith("Preflight vscodium:")) setPhase(build.id, "preflight");
        if (line.startsWith("Dispatching stable workflow")) setPhase(build.id, "dispatching");
        const release = line.match(/GitHub Release \([^)]*\): (https:\/\/\S+)/)?.[1];
        if (release) getDatabase().prepare("UPDATE builds SET release_url=?,updated_at=? WHERE id=?").run(release, now(), build.id);
      },
    });
    saveRuns(build, result.runs);
    setPhase(build.id, "succeeded", "GitHub Actions dispatched");
  } catch (error) {
    const recovered = await discoverRuns(build).catch(() => []);
    if (recovered.length === selectedPlatforms(build.spec).length) {
      saveRuns(build, recovered);
      setPhase(build.id, "succeeded", "GitHub Actions dispatched; result recovered after runner error");
      return;
    }
    throw error;
  } finally {
    await cleanWorkspace(prepared);
  }
}

async function processBuild(build: BuildRow): Promise<void> {
  try {
    if (build.phase === "preview_queued" || build.phase === "previewing") await previewBuild(build);
    else await dispatchBuild(build);
  } catch (error) {
    const reason = error instanceof Error ? error.message : "unknown worker error";
    console.error(`build ${build.id} failed: ${reason}`);
    setPhase(build.id, "failed", reason);
  }
}

async function main(): Promise<void> {
  await mkdir(WORKSPACE_ROOT, { recursive: true });
  await mkdir(GIT_CACHE_ROOT, { recursive: true });
  await prepareGitlabCliEnvironment();
  await startCredentialBroker();
  const githubRepositories = Object.values(repositoryConfig()).flatMap((value) => {
    const url = typeof value === "string" ? value : value.github;
    if (!url) return [];
    try { const parsed = new URL(url); return parsed.hostname === "github.com" ? [parsed.pathname.replace(/^\//, "").replace(/\.git$/, "")] : []; } catch { return []; }
  });
  await assertRepositoryAccess(githubRepositories);
  console.log(`worker ${WORKER_ID} started (${VERSION}) with ${githubRepositories.length} GitHub repositories`);
  while (true) {
    const build = claimBuild();
    if (build) await processBuild(build);
    else await new Promise((resolve) => setTimeout(resolve, POLL_MS));
  }
}

const shutdown = () => { closeDatabase(); process.exit(0); };
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
if (process.env.NODE_ENV !== "test") void main();
