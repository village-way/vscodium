import assert from "node:assert/strict";
import test from "node:test";
import { buildRefSchema, buildSpecSchema, confirmationHash, resolveReleaseVersion } from "./index.js";

const development = { kind: "development", version: "1.4.1", platform: "linux", sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, outputMode: "workflow-artifact", triggerOnly: false, syncGitLab: false, publish: false } as const;

test("development version resolution is deterministic with explicit time patch", () => {
  assert.deepEqual(resolveReleaseVersion({ ...development, timePatch: "61" }), { releaseVersion: "1.4.10061", timePatch: "0061" });
});

test("formal publish remains available for manual releases", () => {
  assert.equal(buildSpecSchema.safeParse({ ...development, kind: "formal", outputMode: "release", publish: true }).success, true);
});

test("confirmation hashes ignore object key order", () => {
  assert.equal(confirmationHash({ a: 1, b: 2 }, "s"), confirmationHash({ b: 2, a: 1 }, "s"));
});

test("build refs accept branches, tags, standard refs, and exact commits", () => {
  assert.equal(buildRefSchema.parse(" feature/release "), "feature/release");
  assert.equal(buildRefSchema.parse("refs/tags/v1.4.1"), "refs/tags/v1.4.1");
  assert.equal(buildRefSchema.parse("A".repeat(40)), "a".repeat(40));
  assert.equal(buildSpecSchema.parse({ ...development, sourceBranch: "refs/heads/feature/release", zhanluCoreRef: "v1.4.1", zhanluVsRef: "b".repeat(40) }).sourceBranch, "refs/heads/feature/release");
});

test("build refs reject unsafe or ambiguous values", () => {
  for (const value of ["", "feature release", "feature;echo", "feature..release", "feature~release"]) {
    assert.equal(buildRefSchema.safeParse(value).success, false, value);
  }
});
