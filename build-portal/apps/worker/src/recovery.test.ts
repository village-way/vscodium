import assert from "node:assert/strict";
import test from "node:test";
import { decideRecovery } from "./recovery.js";

test("crash before dispatch reruns the idempotent full preparation", () => {
  assert.deepEqual(decideRecovery({ phase: "release_prepare", selected: ["linux"], persisted: [], discovered: {} }), { mode: "full", platforms: ["linux"] });
});

test("crash after dispatch restores monitoring without duplicate runs", () => {
  assert.deepEqual(decideRecovery({ phase: "dispatching", selected: ["linux"], persisted: [], discovered: { linux: 1 } }), { mode: "monitor", platforms: ["linux"] });
});

test("only a missing platform is retriggered against the existing release", () => {
  assert.deepEqual(decideRecovery({ phase: "dispatching", selected: ["macos", "linux", "windows"], persisted: ["macos"], discovered: { linux: 1, windows: 0 } }), { mode: "trigger-only", platforms: ["windows"] });
});

test("ambiguous attribution fails closed", () => {
  assert.equal(decideRecovery({ phase: "dispatching", selected: ["linux"], persisted: [], discovered: { linux: 2 } }).mode, "needs-attention");
});
