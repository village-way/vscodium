import type { BuildPhase } from "@zhanlu/build-portal-contracts";

export type RecoveryDecision = { mode: "full" | "trigger-only" | "monitor" | "needs-attention"; platforms: string[]; reason?: string };

export function decideRecovery(input: { phase: BuildPhase; selected: string[]; persisted: string[]; discovered: Record<string, number> }): RecoveryDecision {
  const duplicated = Object.entries(input.discovered).filter(([, count]) => count > 1).map(([platform]) => platform);
  if (duplicated.length) return { mode: "needs-attention", platforms: duplicated, reason: "multiple workflow runs match the portal request id" };
  const known = new Set([...input.persisted, ...Object.entries(input.discovered).filter(([, count]) => count === 1).map(([platform]) => platform)]);
  const missing = input.selected.filter((platform) => !known.has(platform));
  if (!missing.length) return { mode: "monitor", platforms: input.selected };
  if (input.phase === "dispatching") return { mode: "trigger-only", platforms: missing };
  if (input.persisted.length) return { mode: "trigger-only", platforms: missing };
  return { mode: "full", platforms: missing };
}
