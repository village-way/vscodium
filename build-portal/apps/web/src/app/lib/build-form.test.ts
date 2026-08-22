import test from "node:test";
import assert from "node:assert/strict";
import { normalizeBuildForm } from "./build-form.js";

test("formal form values always resolve to release-only options", () => {
  const value = normalizeBuildForm({ kind: "formal", version: "1.4.1", platform: "linux", outputMode: "workflow-artifact", vscodiumRef: " dev-agent-host ", zhanluCodeRef: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "", bundleCodexRuntime: false, syncGitLab: true, publish: true });
  assert.equal(value.outputMode, "release");
  assert.equal(value.syncGitLab, true);
  assert.equal(value.publish, true);
  assert.equal(value.triggerOnly, false);
  assert.equal(value.vscodiumRef, "dev-agent-host");
  assert.equal(value.zhanluVsRef, "");
});

test("development form never sends formal-only switches", () => {
  const value = normalizeBuildForm({ kind: "development", version: "1.4.1", platform: "linux", outputMode: "workflow-artifact", vscodiumRef: "master", zhanluCodeRef: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "", bundleCodexRuntime: false, syncGitLab: true, publish: true });
  assert.equal(value.syncGitLab, false);
  assert.equal(value.publish, false);
});

test("custom refs are mapped to the compatible API fields", () => {
  const value = normalizeBuildForm({ kind: "development", version: "1.4.1", platform: "all", outputMode: "workflow-artifact", vscodiumRef: "dev-agent-host", zhanluCodeRef: " feature/release ", deliveryProfile: "default", zhanluCoreRef: "refs/tags/v1.4.1", zhanluVsRef: "a".repeat(40), bundleCodexRuntime: false, syncGitLab: false, publish: false });
  assert.equal(value.sourceBranch, "feature/release");
  assert.equal(value.zhanluCoreRef, "refs/tags/v1.4.1");
  assert.equal(value.zhanluVsRef, "a".repeat(40));
  assert.equal("zhanluCodeRef" in value, false);
});
