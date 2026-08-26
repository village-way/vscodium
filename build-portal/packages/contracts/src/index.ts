import { createHash } from "node:crypto";
import { z } from "zod";

export const platforms = ["macos", "linux", "windows", "all"] as const;
export const defaultZhanluCoreRef = "3d7802ec82d0e7fd774cb1d3f4cb65ac24819909";
export const buildPhases = [
  "preview_queued", "previewing", "awaiting_confirmation", "queued",
  "source_sync", "preflight", "dispatching", "succeeded", "failed",
] as const;

const fullCommitPattern = /^[0-9a-f]{40}$/i;
const safeRefPattern = /^[A-Za-z0-9][A-Za-z0-9._/@+-]{0,199}$/;

function canonicalBuildRef(value: string): string {
  const trimmed = value.trim();
  return fullCommitPattern.test(trimmed) ? trimmed.toLowerCase() : trimmed;
}

function isValidBuildRef(value: string): boolean {
  const canonical = canonicalBuildRef(value);
  if (fullCommitPattern.test(canonical)) return true;
  return safeRefPattern.test(canonical)
    && !canonical.includes("..")
    && !canonical.includes("@{")
    && !canonical.includes("//")
    && !canonical.endsWith("/")
    && !canonical.endsWith(".");
}

export const buildRefSchema = z.string()
  .trim()
  .min(1, "源码引用不能为空")
  .max(200, "源码引用不能超过 200 个字符")
  .refine(isValidBuildRef, "请输入合法的 branch、tag、ref 或完整 40 位 commit SHA")
  .transform(canonicalBuildRef);

const rawBuildSpecSchema = z.object({
  kind: z.enum(["development", "formal"]),
  version: z.string().regex(/^v?\d+\.\d+\.\d+$/),
  timePatch: z.string().regex(/^\d{1,4}$/).optional(),
  platform: z.enum(platforms).default("all"),
  // Kept as sourceBranch for workflow/API compatibility; this is the zhanlu-code ref.
  sourceBranch: buildRefSchema.default("develop"),
  deliveryProfile: z.string().min(1).max(100).default("default"),
  zhanluCoreRef: buildRefSchema.default(defaultZhanluCoreRef),
  bundleCodexRuntime: z.boolean().default(false),
  outputMode: z.enum(["release", "workflow-artifact"]).default("release"),
  triggerOnly: z.boolean().default(false),
  syncGitLab: z.boolean().optional(),
  publish: z.boolean().default(false),
});

export const buildSpecSchema = rawBuildSpecSchema.transform((spec) => ({ ...spec, syncGitLab: spec.syncGitLab ?? spec.kind === "formal" })).superRefine((spec, ctx) => {
  if (spec.kind === "formal" && spec.outputMode !== "release") {
    ctx.addIssue({ code: "custom", path: ["outputMode"], message: "formal builds require release output" });
  }
  if (spec.outputMode === "workflow-artifact" && spec.kind !== "development") {
    ctx.addIssue({ code: "custom", path: ["outputMode"], message: "workflow artifacts are development-only" });
  }
  if (spec.publish && spec.kind !== "formal") {
    ctx.addIssue({ code: "custom", path: ["publish"], message: "publish is only valid for formal builds" });
  }
  if (spec.triggerOnly && spec.outputMode !== "release") {
    ctx.addIssue({ code: "custom", path: ["triggerOnly"], message: "trigger-only requires an existing release" });
  }
});

export type BuildSpec = z.infer<typeof buildSpecSchema>;
export type BuildPhase = typeof buildPhases[number];
export type Platform = typeof platforms[number];

export function resolveReleaseVersion(spec: BuildSpec, now = new Date()): { releaseVersion: string; timePatch: string } {
  const base = spec.version.replace(/^v/, "");
  const publicPatch = base.split(".")[2]!;
  if (spec.kind === "development" && publicPatch.length > 4) {
    const inferred = publicPatch.slice(-4);
    if (spec.timePatch && spec.timePatch.padStart(4, "0") !== inferred) throw new Error("time patch does not match development version suffix");
    return { releaseVersion: base, timePatch: inferred };
  }
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23", timeZone: "Asia/Tokyo" }).formatToParts(now).map((part) => [part.type, part.value]));
  const year = Number(parts.year); const localDate = Date.UTC(year, Number(parts.month) - 1, Number(parts.day)); const day = Math.floor((localDate - Date.UTC(year, 0, 0)) / 86_400_000);
  const generated = String(day * 24 + Number(parts.hour)).padStart(4, "0");
  const timePatch = spec.timePatch?.padStart(4, "0") ?? generated;
  return { releaseVersion: spec.kind === "development" ? `${base}${timePatch}` : base, timePatch };
}

export function confirmationHash(value: unknown, secret: string): string {
  return createHash("sha256").update(stableJson(value)).update("\0").update(secret).digest("hex");
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, item]) => `${JSON.stringify(key)}:${stableJson(item)}`).join(",")}}`;
  return JSON.stringify(value);
}

export const terminalPhases = new Set<BuildPhase>(["succeeded", "failed"]);
