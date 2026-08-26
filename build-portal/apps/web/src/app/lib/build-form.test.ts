import test from "node:test";
import assert from "node:assert/strict";
import { defaultZhanluCoreRef as contractDefaultZhanluCoreRef } from "@zhanlu/build-portal-contracts";
import { defaultZhanluCoreRef, normalizeBuildForm } from "./build-form.js";

test("browser-safe core default matches the server contract", () => {
  assert.equal(defaultZhanluCoreRef, contractDefaultZhanluCoreRef);
});

test("formal form values always resolve to release-only options", () => {
  const value = normalizeBuildForm({ kind: "formal", version: "1.4.1", platform: "linux", outputMode: "workflow-artifact", zhanluCodeRef: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", bundleCodexRuntime: false, syncGitLab: true, publish: true });
  assert.equal(value.outputMode, "release");
  assert.equal(value.syncGitLab, true);
  assert.equal(value.publish, true);
  assert.equal(value.triggerOnly, false);
});

test("development form never sends formal-only switches", () => {
  const value = normalizeBuildForm({ kind: "development", version: "1.4.1", platform: "linux", outputMode: "workflow-artifact", zhanluCodeRef: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", bundleCodexRuntime: false, syncGitLab: true, publish: true });
  assert.equal(value.syncGitLab, false);
  assert.equal(value.publish, false);
});

test("custom refs are mapped to the compatible API fields", () => {
  const value = normalizeBuildForm({ kind: "development", version: "1.4.1", platform: "all", outputMode: "workflow-artifact", zhanluCodeRef: " feature/release ", deliveryProfile: "default", zhanluCoreRef: "refs/tags/v1.4.1", bundleCodexRuntime: false, syncGitLab: false, publish: false });
  assert.equal(value.sourceBranch, "feature/release");
  assert.equal(value.zhanluCoreRef, "refs/tags/v1.4.1");
  assert.equal("zhanluCodeRef" in value, false);
});
