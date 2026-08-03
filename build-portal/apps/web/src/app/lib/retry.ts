const preDispatchPhases = new Set(["queued", "source_sync_preview", "source_sync", "preflight", "release_prepare"]);

export type RetryDecision =
  | { mode: "full"; platforms: string[] }
  | { mode: "platforms"; platforms: string[] }
  | { mode: "reject"; reason: string };

export function decideBuildRetry(input: { phase: string; runCount: number; lastPhase?: string; requestedPlatforms: string[]; failedPlatforms: string[] }): RetryDecision {
  if (input.phase === "failed" && input.runCount === 0 && (!input.lastPhase || preDispatchPhases.has(input.lastPhase)) && input.failedPlatforms.length === 0) {
    return { mode: "full", platforms: input.requestedPlatforms };
  }
  if (input.failedPlatforms.length > 0) return { mode: "platforms", platforms: input.failedPlatforms };
  return { mode: "reject", reason: "only a failed pre-dispatch build without workflow runs can be fully retried" };
}
