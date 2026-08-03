import test from "node:test";
import assert from "node:assert/strict";
import { normalizeBuildForm } from "./build-form.js";

test("formal form values always resolve to release-only options", () => {
  const value = normalizeBuildForm({ kind: "formal", version: "1.4.1", platform: "linux", outputMode: "workflow-artifact", sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, syncGitLab: true, publish: true });
  assert.equal(value.outputMode, "release");
  assert.equal(value.syncGitLab, true);
  assert.equal(value.publish, true);
  assert.equal(value.triggerOnly, false);
});

test("development form never sends formal-only switches", () => {
  const value = normalizeBuildForm({ kind: "development", version: "1.4.1", platform: "linux", outputMode: "workflow-artifact", sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, syncGitLab: true, publish: true });
  assert.equal(value.syncGitLab, false);
  assert.equal(value.publish, false);
});
