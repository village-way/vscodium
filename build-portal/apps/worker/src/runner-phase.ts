import type { BuildPhase } from "@zhanlu/build-portal-contracts";

export function runnerPhase(line: string): BuildPhase | undefined {
  if (line.includes("Previewing selected GitLab") || line.includes("Previewing GitLab")) return "source_sync_preview";
  if (line.includes("Synchronizing selected GitLab") || line.includes("Synchronizing GitLab")) return "source_sync";
  if (line.startsWith("Preflight")) return "preflight";
  if (line.includes("Creating/updating the release")) return "release_prepare";
  if (line.includes("GitHub workflow dispatch API")) return "dispatching";
  return undefined;
}
