import { spawn } from "node:child_process";
import type { BuildSpec } from "@zhanlu/build-portal-contracts";

const SECRET_PATTERN = /(authorization:\s*bearer\s+|token[=:]\s*|password[=:]\s*|cookie:\s*)\S+/gi;
export function redact(line: string): string { return line.replace(SECRET_PATTERN, "$1[REDACTED]").replace(/(https?:\/\/)[^/@\s]+@/g, "$1[REDACTED]@"); }

export type RunnerResult = { schemaVersion: "v1"; requestId?: string; releaseVersion: string; versionTimePatch: string; runs: Array<{ workflow: string; runId: number; url: string }> };

export function buildArguments(spec: BuildSpec, requestId: string, workspace: string, apply: boolean): string[] {
  const args = ["--kind", spec.kind, "--version", spec.version, "--workspace", workspace, "--source-branch", spec.sourceBranch, "--delivery-profile", spec.deliveryProfile, "--zhanlu-core-ref", spec.zhanluCoreRef, "--zhanlu-vs-ref", spec.zhanluVsRef, "--bundle-codex-runtime", spec.bundleCodexRuntime ? "1" : "0", "--platform", spec.platform, "--request-id", requestId, "--output", "json", "--no-wait"];
  if (spec.timePatch) args.push("--time-patch", spec.timePatch);
  if (spec.outputMode === "workflow-artifact") args.push("--generate-only");
  if (spec.triggerOnly) args.push("--trigger-only");
  if (!spec.syncGitLab) args.push("--no-gitlab");
  if (spec.publish) args.push("--publish");
  if (apply) args.push("--apply");
  return args;
}

export async function runRelease(spec: BuildSpec, requestId: string, options: { workspace: string; apply: boolean; onLog?: (line: string) => Promise<void> }): Promise<RunnerResult> {
  const script = process.env.ZHANLU_BUILD_SCRIPT ?? `${options.workspace}/vscodium/.agents/skills/zhanlu-build/scripts/zhanlu_build.py`;
  const child = spawn("python3", [script, ...buildArguments(spec, requestId, options.workspace, options.apply)], { cwd: `${options.workspace}/vscodium`, env: process.env, stdio: ["ignore", "pipe", "pipe"] });
  const jsonLines: string[] = []; let failureHint = ""; let processing=Promise.resolve();const buffers={stdout:"",stderr:""};
  const consumeLine=async(raw:string)=>{if(!raw)return;const line=redact(raw);if(line.startsWith("{"))jsonLines.push(line);if(/^(?:ERROR|fatal:|error:)/i.test(line.trim()))failureHint=line.trim();await options.onLog?.(line);};
  const consumeFailureLine=consumeLine;
  const consumeChunk=async(chunk:Buffer,stream:keyof typeof buffers)=>{const lines=(buffers[stream]+chunk.toString("utf8")).split(/\r?\n/);buffers[stream]=lines.pop()??"";for(const line of lines)await (stream === "stderr" ? consumeFailureLine(line) : consumeLine(line));};
  child.stdout.on("data",(chunk:Buffer)=>{processing=processing.then(()=>consumeChunk(chunk,"stdout"));}); child.stderr.on("data",(chunk:Buffer)=>{processing=processing.then(()=>consumeChunk(chunk,"stderr"));});
  const code = await new Promise<number>((resolve, reject) => child.once("error", reject).once("close", (value) => resolve(value ?? 1)));
  await processing;await consumeLine(buffers.stdout);await consumeFailureLine(buffers.stderr);
  if (code !== 0) throw new Error(`zhanlu_build.py exited with ${code}${failureHint ? `: ${failureHint}` : ""}`);
  for (const line of jsonLines.reverse()) {
    try { const value = JSON.parse(line) as RunnerResult; if (value.schemaVersion === "v1" && Array.isArray(value.runs)) return value; } catch { /* structured output only */ }
  }
  throw new Error("release wrapper returned no schema v1 result");
}
