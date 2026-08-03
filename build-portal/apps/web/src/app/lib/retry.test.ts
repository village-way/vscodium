import assert from "node:assert/strict";
import test from "node:test";
import { decideBuildRetry } from "./retry.js";

test("allows a complete retry before workflow dispatch", () => {
  assert.deepEqual(decideBuildRetry({ phase: "failed", runCount: 0, lastPhase: "release_prepare", requestedPlatforms: ["macos", "linux", "windows"], failedPlatforms: [] }), { mode: "full", platforms: ["macos", "linux", "windows"] });
});

test("fails closed when a workflow may already have been dispatched", () => {
  assert.deepEqual(decideBuildRetry({ phase: "failed", runCount: 0, lastPhase: "dispatching", requestedPlatforms: ["linux"], failedPlatforms: [] }), { mode: "reject", reason: "only a failed pre-dispatch build without workflow runs can be fully retried" });
});

test("keeps platform retry separate from complete retry", () => {
  assert.deepEqual(decideBuildRetry({ phase: "failed", runCount: 3, lastPhase: "running", requestedPlatforms: ["macos", "linux", "windows"], failedPlatforms: ["linux"] }), { mode: "platforms", platforms: ["linux"] });
});
