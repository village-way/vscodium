export type BuildFormValues = { kind: "development" | "formal"; version: string; platform: string; outputMode: string; zhanluCodeRef: string; deliveryProfile: string; zhanluCoreRef: string; bundleCodexRuntime: boolean; syncGitLab: boolean; publish: boolean };
export const defaultZhanluCoreRef = "3d7802ec82d0e7fd774cb1d3f4cb65ac24819909";

export function normalizeBuildForm(values: BuildFormValues) {
  const formal = values.kind === "formal";
  const { zhanluCodeRef, ...rest } = values;
  return { ...rest, sourceBranch: zhanluCodeRef.trim(), zhanluCoreRef: values.zhanluCoreRef.trim(), outputMode: formal ? "release" : values.outputMode, syncGitLab: formal && values.syncGitLab, publish: formal && values.publish, triggerOnly: false };
}
