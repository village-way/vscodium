export type BuildFormValues = { kind: "development" | "formal"; version: string; platform: string; outputMode: string; sourceBranch: string; deliveryProfile: string; zhanluCoreRef: string; zhanluVsRef: string; bundleCodexRuntime: boolean; syncGitLab: boolean; publish: boolean };

export function normalizeBuildForm(values: BuildFormValues) {
  const formal = values.kind === "formal";
  return { ...values, outputMode: formal ? "release" : values.outputMode, syncGitLab: formal && values.syncGitLab, publish: formal && values.publish, triggerOnly: false };
}
