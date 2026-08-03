import { execFile } from "node:child_process";
import { mkdir } from "node:fs/promises";
import { hostname } from "node:os";
import { promisify } from "node:util";
import type pg from "pg";
import { buildSpecSchema, resolveReleaseVersion, terminalPhases, type BuildPhase, type BuildSpec } from "@zhanlu/build-portal-contracts";
import { appendBuildEvent, closePool, getPool } from "@zhanlu/build-portal-db";
import { assertRepositoryAccess, github, installationToken, startCredentialBroker } from "@zhanlu/build-portal-github-app";
import { runRelease } from "@zhanlu/build-portal-release-runner";
import { decideRecovery } from "./recovery.js";

const run = promisify(execFile); const WORKER_ID = process.env.WORKER_ID ?? hostname(); const VERSION = process.env.PORTAL_VERSION ?? "development"; const WORKSPACE_ROOT = process.env.WORKSPACE_ROOT ?? "/var/lib/zhanlu-build/workspace"; const PREPARE_LOCK = 0x5a4c524c; const POLL_MS = Number(process.env.WORKER_POLL_MS ?? 5000);
const workflowByPlatform = { macos: "stable-macos.yml", linux: "stable-linux.yml", windows: "stable-windows.yml" } as const;
type BuildRow = { id: string; request_id: string; spec: unknown; resolved: Record<string, unknown> | null; phase: BuildPhase; cancel_requested_at: Date | null };

type RepositoryUrls=string|{github?:string;gitlab?:string};
function repositoryConfig(): Record<string, RepositoryUrls> { const raw = process.env.REPOSITORIES_JSON; if (!raw) throw new Error("REPOSITORIES_JSON is required"); return JSON.parse(raw) as Record<string,RepositoryUrls>; }
function checkoutUrl(name:string):string{const value=repositoryConfig()[name];const url=typeof value==="string"?value:name==="vscodium"?value?.github:value?.gitlab??value?.github;if(!url)throw new Error(`repository URL missing for ${name}`);return url;}
async function git(args: string[], cwd?: string) { return run("git", args, { cwd, env: process.env, maxBuffer: 10 * 1024 * 1024 }); }
async function setPhase(id: string, phase: BuildPhase, reason?: string): Promise<void> { await getPool().query("UPDATE builds SET phase=$2,phase_reason=$3,updated_at=now(),lease_expires_at=now()+interval '90 seconds' WHERE id=$1", [id, phase, reason ?? null]); await appendBuildEvent(id, "phase.changed", { phase, reason }); }

async function ensureCheckout(name: string, branch: string): Promise<void> {
  const url = checkoutUrl(name); const path = `${WORKSPACE_ROOT}/${name}`;
  await mkdir(WORKSPACE_ROOT, { recursive: true });
  try { await git(["-C", path, "rev-parse", "--git-dir"]); } catch { await git(["clone", "--origin", "origin", "--branch", branch, "--single-branch", url, path]); }
  const status = (await git(["-C", path, "status", "--porcelain"])).stdout.trim(); if (status) throw new Error(`dedicated checkout is dirty: ${name}`);
  await git(["-C", path, "fetch", "--prune", "origin", branch]); await git(["-C", path, "checkout", branch]);
  const head = (await git(["-C", path, "rev-parse", "HEAD"])).stdout.trim(); const remote = (await git(["-C", path, "rev-parse", `origin/${branch}`])).stdout.trim(); if (head !== remote) await git(["-C", path, "merge", "--ff-only", `origin/${branch}`]); const finalHead=(await git(["-C",path,"rev-parse","HEAD"])).stdout.trim();if(finalHead!==remote)throw new Error(`${name} must equal origin/${branch}: HEAD=${finalHead} remote=${remote}`);
}

async function prepareWorkspace(spec: BuildSpec): Promise<void> { const githubRepos=Object.values(repositoryConfig()).flatMap((value)=>{const urls=typeof value==="string"?[value]:[value.github].filter((item):item is string=>Boolean(item));return urls.flatMap((url)=>{try{const parsed=new URL(url);if(parsed.hostname!=="github.com")return[];return[parsed.pathname.replace(/^\//,"").replace(/\.git$/,"")];}catch{return[];}});});await assertRepositoryAccess(githubRepos);await ensureCheckout("vscodium", "master"); if (spec.kind === "formal" && spec.syncGitLab && !spec.triggerOnly) for (const name of ["zhanlu-cloud","zhanlu-code","zhanlu-core","zhanlu-loc","zhanlu-vs"]) await ensureCheckout(name, "develop"); }

async function claim(): Promise<BuildRow | null> {
  const result = await getPool().query<BuildRow>(`WITH candidate AS (SELECT id FROM builds WHERE phase IN ('queued','source_sync_preview','source_sync','preflight','release_prepare','dispatching','running') AND (lease_expires_at IS NULL OR lease_expires_at<now()) ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1) UPDATE builds b SET lease_owner=$1,lease_expires_at=now()+interval '90 seconds',updated_at=now() FROM candidate c WHERE b.id=c.id RETURNING b.*`, [WORKER_ID]); return result.rows[0] ?? null;
}

async function acquirePrepareLock(): Promise<pg.PoolClient> { const client = await getPool().connect(); await client.query("SELECT pg_advisory_lock($1)", [PREPARE_LOCK]); return client; }
async function releasePrepareLock(client: pg.PoolClient): Promise<void> { try { await client.query("SELECT pg_advisory_unlock($1)", [PREPARE_LOCK]); } finally { client.release(); } }

function selectedPlatforms(spec: BuildSpec): Array<keyof typeof workflowByPlatform> { return spec.platform === "all" ? ["macos","linux","windows"] : [spec.platform]; }

async function saveRuns(build: BuildRow, runs: Array<{workflow:string;runId:number;url:string}>): Promise<void> {
  for (const item of runs) { const platform = Object.entries(workflowByPlatform).find(([,workflow]) => workflow === item.workflow)?.[0]; if (!platform) throw new Error(`unknown workflow ${item.workflow}`); await getPool().query("INSERT INTO build_runs(build_id,platform,workflow,run_id,run_url,status,dispatch_attempts) VALUES($1,$2,$3,$4,$5,'queued',1) ON CONFLICT(build_id,platform) DO UPDATE SET run_id=excluded.run_id,run_url=excluded.run_url,status='queued',conclusion=NULL,dispatch_attempts=build_runs.dispatch_attempts+1,updated_at=now()", [build.id,platform,item.workflow,String(item.runId),item.url]); }
}

async function findRunsByRequest(build: BuildRow, platforms: Array<keyof typeof workflowByPlatform>): Promise<Array<{workflow:string;runId:number;url:string}>> {
  const owner = process.env.GITHUB_OWNER; const repo = process.env.GITHUB_REPOSITORY_NAME ?? "vscodium"; if (!owner) throw new Error("GITHUB_OWNER is required"); const client = await github(); const found: Array<{workflow:string;runId:number;url:string}> = [];
  for (const platform of platforms) { const workflow = workflowByPlatform[platform]; const response = await client.actions.listWorkflowRuns({ owner, repo, workflow_id: workflow, event: "workflow_dispatch", per_page: 30 }); const matches = response.data.workflow_runs.filter((item) => item.display_title?.includes(build.request_id)); if (matches.length > 1) throw new Error(`ambiguous runs for ${workflow}`); if (matches[0]) found.push({ workflow, runId: matches[0].id, url: matches[0].html_url }); }
  return found;
}

async function dispatch(build: BuildRow, spec: BuildSpec): Promise<void> {
  const token=await installationToken();process.env.GH_TOKEN=token;process.env.GITHUB_TOKEN=token;
  let observed:BuildPhase|undefined;const log=async(line:string)=>{let phase:BuildPhase|undefined;if(line.includes("Previewing GitLab"))phase="source_sync_preview";else if(line.includes("Synchronizing GitLab"))phase="source_sync";else if(line.startsWith("Preflight"))phase="preflight";else if(line.includes("Creating/updating the release"))phase="release_prepare";else if(line.includes("Dispatching stable workflow"))phase="dispatching";if(phase&&phase!==observed){observed=phase;await setPhase(build.id,phase);}await appendBuildEvent(build.id,"runner.log",{line});};
  const existing = await getPool().query<{platform:string;run_id:string|null}>("SELECT platform,run_id FROM build_runs WHERE build_id=$1", [build.id]); const persisted=existing.rows.filter((row)=>row.run_id).map((row)=>row.platform);const selected=selectedPlatforms(spec);const initiallyMissing=selected.filter((platform)=>!persisted.includes(platform));const discovered:Record<string,number>={};
  if (["dispatching","running"].includes(build.phase)&&initiallyMissing.length) { const recovered = await findRunsByRequest(build, initiallyMissing); await saveRuns(build,recovered); for(const item of recovered){const platform=Object.entries(workflowByPlatform).find(([,workflow])=>workflow===item.workflow)?.[0];if(platform)discovered[platform]=1;} }
  const decision=decideRecovery({phase:build.phase,selected,persisted,discovered});if(decision.mode==="needs-attention")throw new Error(`ambiguous workflow attribution: ${decision.reason}`);if(decision.mode==="monitor")return;
  if(decision.mode==="full"){const result=await runRelease(spec,build.request_id,{workspace:WORKSPACE_ROOT,apply:true,onLog:log});await saveRuns(build,result.runs);return;}
  for (const platform of decision.platforms) { const result = await runRelease({ ...spec, platform:platform as keyof typeof workflowByPlatform, triggerOnly: true }, build.request_id, { workspace: WORKSPACE_ROOT, apply: true, onLog: log }); await saveRuns(build,result.runs); }
}

async function monitor(build: BuildRow): Promise<void> {
  const owner = process.env.GITHUB_OWNER; const repo = process.env.GITHUB_REPOSITORY_NAME ?? "vscodium"; if (!owner) throw new Error("GITHUB_OWNER is required"); const client = await github();
  while (true) { const cancellation = await getPool().query<{cancel_requested_at:Date|null}>("SELECT cancel_requested_at FROM builds WHERE id=$1",[build.id]); const runs = await getPool().query<{id:string;run_id:string;status:string}>("SELECT id,run_id,status FROM build_runs WHERE build_id=$1",[build.id]); let complete=0; let success=true;
    for (const item of runs.rows) { if (cancellation.rows[0]?.cancel_requested_at && item.status !== "completed") await client.actions.cancelWorkflowRun({owner,repo,run_id:Number(item.run_id)}).catch(() => undefined); const detail = await client.actions.getWorkflowRun({owner,repo,run_id:Number(item.run_id)}); const status=detail.data.status ?? "unknown"; const conclusion=detail.data.conclusion; await getPool().query("UPDATE build_runs SET status=$2,conclusion=$3,run_url=$4,updated_at=now() WHERE id=$1",[item.id,status,conclusion,detail.data.html_url]); if(status==="completed"){complete++; if(conclusion!=="success")success=false;} }
    if (complete===runs.rowCount && runs.rowCount>0) { await setPhase(build.id,cancellation.rows[0]?.cancel_requested_at?"cancelled":success?"succeeded":"failed"); return; }
    await getPool().query("UPDATE builds SET lease_expires_at=now()+interval '90 seconds' WHERE id=$1",[build.id]); await new Promise((resolve)=>setTimeout(resolve,30_000));
  }
}

async function processBuild(build: BuildRow): Promise<void> { const spec=buildSpecSchema.parse(build.spec); if(build.phase==="running"){await monitor(build);return;} let lock:pg.PoolClient|undefined; try { lock=await acquirePrepareLock(); if(build.phase!=="dispatching")await prepareWorkspace(spec);const resolved=build.resolved ?? {...resolveReleaseVersion(spec),platforms:selectedPlatforms(spec)};await getPool().query("UPDATE builds SET resolved=$2::jsonb WHERE id=$1",[build.id,JSON.stringify(resolved)]);if(build.phase==="queued")await setPhase(build.id,"source_sync_preview");await dispatch(build,spec); await setPhase(build.id,"running"); } catch(error) { await setPhase(build.id,error instanceof Error&&error.message.includes("ambiguous")?"needs_attention":"failed",error instanceof Error?error.message:"unknown"); return; } finally { if(lock) await releasePrepareLock(lock); } await monitor(build); }

async function processMockBuild(build: BuildRow): Promise<void>{const spec=buildSpecSchema.parse(build.spec);const resolved=build.resolved??{...resolveReleaseVersion(spec),platforms:selectedPlatforms(spec)};await setPhase(build.id,"preflight");await getPool().query("UPDATE builds SET resolved=$2::jsonb WHERE id=$1",[build.id,JSON.stringify(resolved)]);await setPhase(build.id,"dispatching");for(const platform of selectedPlatforms(spec))await getPool().query("INSERT INTO build_runs(build_id,platform,workflow,run_id,run_url,status,conclusion,dispatch_attempts) VALUES($1,$2,$3,$4,$5,'completed','success',1) ON CONFLICT(build_id,platform) DO UPDATE SET status='completed',conclusion='success',updated_at=now()",[build.id,platform,workflowByPlatform[platform],`mock-${build.request_id}-${platform}`,`https://example.invalid/mock/${build.request_id}/${platform}`]);await setPhase(build.id,"succeeded","mock executor");}

async function refreshRefs(): Promise<void> { const config=repositoryConfig();for(const [repository,value] of Object.entries(config)){const providers=typeof value==="string"?[[value.includes("gitlab")?"gitlab":"github",value] as const]:Object.entries(value);for(const ref of ["develop","master"]){const observed:Array<{provider:string;sha:string}>=[];for(const [provider,url] of providers){if(!url)continue;try{const {stdout}=await git(["ls-remote","--heads",url,ref]);const sha=stdout.trim().split(/\s+/)[0];if(sha)observed.push({provider,sha});}catch{/* not every repo has both defaults */}}const syncStatus=observed.length>1?(new Set(observed.map((item)=>item.sha)).size===1?"in_sync":"diverged"):"single_provider";for(const item of observed)await getPool().query("INSERT INTO ref_snapshots(repository,provider,ref,sha,sync_status) VALUES($1,$2,$3,$4,$5)",[repository,item.provider,ref,item.sha,syncStatus]);}}}
let lastRefRefresh=0; async function heartbeat():Promise<void>{await getPool().query("INSERT INTO workers(id,version,heartbeat_at) VALUES($1,$2,now()) ON CONFLICT(id) DO UPDATE SET version=excluded.version,heartbeat_at=now()",[WORKER_ID,VERSION]);}
async function refRefreshRequested():Promise<boolean>{const result=await getPool().query<{requested_at:Date|null}>("SELECT max(created_at) AS requested_at FROM audit_events WHERE action='refs.refresh.requested'");return Boolean(result.rows[0]?.requested_at&&result.rows[0].requested_at.getTime()>lastRefRefresh);}
let lastDailySync=""; async function maybeDailySync(now=new Date()):Promise<void>{const parts=new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Tokyo",year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hour12:false}).formatToParts(now);const value=Object.fromEntries(parts.map((part)=>[part.type,part.value]));const date=`${value.year}-${value.month}-${value.day}`;if(value.hour!=="01"||value.minute!=="05"||lastDailySync===date)return;const lock=await acquirePrepareLock();try{await ensureCheckout("vscodium","master");const cwd=`${WORKSPACE_ROOT}/vscodium`;await run("bash",["./scripts/sync-zhanlu-gitlab-to-github.sh","--dry-run"],{cwd,env:process.env});await run("bash",["./scripts/sync-zhanlu-gitlab-to-github.sh"],{cwd,env:process.env});lastDailySync=date;console.log(`default-branch sync completed for ${date}`);}finally{await releasePrepareLock(lock);}}
async function main(){const mock=process.env.EXECUTOR_MODE==="mock";if(!mock)await startCredentialBroker();console.log(`worker ${WORKER_ID} started (${mock?"mock":"real"})`);while(true){try{await heartbeat();if(!mock){await maybeDailySync();if(Date.now()-lastRefRefresh>10*60_000||await refRefreshRequested()){await refreshRefs();lastRefRefresh=Date.now();}}const build=await claim();if(build)await(mock?processMockBuild(build):processBuild(build));else await new Promise((resolve)=>setTimeout(resolve,POLL_MS));}catch(error){console.error("worker loop failed",error instanceof Error?error.message:"unknown");await new Promise((resolve)=>setTimeout(resolve,POLL_MS));}}}
const shutdown=async()=>{await closePool();process.exit(0)};process.on("SIGTERM",shutdown);process.on("SIGINT",shutdown);if(process.env.NODE_ENV!=="test")void main();
