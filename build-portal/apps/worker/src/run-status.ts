export type RunObservation = {
  platform: string;
  runId: string;
  status: string;
  conclusion: string | null;
};

export type RunSummary = {
  terminalPhase: "succeeded" | "failed" | "cancelled" | null;
  reason?: string;
};

export function summarizeRuns(runs: RunObservation[], cancellationRequested: boolean): RunSummary {
  if (!runs.length || runs.some((run) => run.status !== "completed")) return { terminalPhase: null };
  if (cancellationRequested) return { terminalPhase: "cancelled" };

  const failed = runs.filter((run) => run.conclusion !== "success");
  if (!failed.length) return { terminalPhase: "succeeded" };

  return {
    terminalPhase: "failed",
    reason: `failed runs: ${failed.map((run) => `${run.platform} (${run.runId}: ${run.conclusion ?? "unknown"})`).join(", ")}`,
  };
}
