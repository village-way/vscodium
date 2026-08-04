import assert from "node:assert/strict";
import test from "node:test";
import { summarizeRuns, type RunObservation } from "./run-status.js";

const run = (overrides: Partial<RunObservation> = {}): RunObservation => ({
  platform: "linux",
  runId: "101",
  status: "completed",
  conclusion: "success",
  ...overrides,
});

test("all successful runs complete the build", () => {
  assert.deepEqual(summarizeRuns([run(), run({ platform: "macos", runId: "102" })], false), { terminalPhase: "succeeded" });
});

test("a failed run produces a concise platform and run summary", () => {
  assert.deepEqual(summarizeRuns([run(), run({ platform: "windows", runId: "103", conclusion: "failure" })], false), {
    terminalPhase: "failed",
    reason: "failed runs: windows (103: failure)",
  });
});

test("a completed cancellation request wins over workflow conclusions", () => {
  assert.deepEqual(summarizeRuns([run({ conclusion: "cancelled" })], true), { terminalPhase: "cancelled" });
});

test("multiple platforms remain non-terminal while any run is incomplete", () => {
  assert.deepEqual(summarizeRuns([run(), run({ platform: "macos", runId: "102", status: "in_progress", conclusion: null })], false), { terminalPhase: null });
});
