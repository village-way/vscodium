export type BuildFormValues = { kind: "development" | "formal"; version: string; platform: string; outputMode: string; vscodiumRef: string; zhanluCodeRef: string; deliveryProfile: string; zhanluCoreRef: string; zhanluVsRef: string; bundleCodexRuntime: boolean; syncGitLab: boolean; publish: boolean }; // zhanlu_change

export function normalizeBuildForm(values: BuildFormValues) {
  const formal = values.kind === "formal";
  const { zhanluCodeRef, ...rest } = values;
  return { ...rest, vscodiumRef: values.vscodiumRef.trim(), sourceBranch: zhanluCodeRef.trim(), zhanluCoreRef: values.zhanluCoreRef.trim(), zhanluVsRef: values.zhanluVsRef.trim(), outputMode: formal ? "release" : values.outputMode, syncGitLab: formal && values.syncGitLab, publish: formal && values.publish, triggerOnly: false }; // zhanlu_change
}
