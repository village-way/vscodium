import assert from "node:assert/strict";
import test from "node:test";
import { buildSpecSchema, confirmationHash, resolveReleaseVersion, scheduleInputSchema } from "./index.js";

const development = { kind: "development", version: "1.4.1", platform: "linux", sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, outputMode: "workflow-artifact", triggerOnly: false, syncGitLab: false, publish: false } as const;

test("development version resolution is deterministic with explicit time patch", () => {
  assert.deepEqual(resolveReleaseVersion({ ...development, timePatch: "61" }), { releaseVersion: "1.4.10061", timePatch: "0061" });
});

test("formal publish is allowed but scheduled formal is rejected", () => {
  assert.equal(buildSpecSchema.safeParse({ ...development, kind: "formal", outputMode: "release", publish: true }).success, true);
  assert.equal(scheduleInputSchema.safeParse({ name: "bad", cron: "5 1 * * *", spec: { ...development, kind: "formal", outputMode: "release" } }).success, false);
});

test("confirmation hashes ignore object key order", () => {
  assert.equal(confirmationHash({ a: 1, b: 2 }, "s"), confirmationHash({ b: 2, a: 1 }, "s"));
});
