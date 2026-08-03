import assert from "node:assert/strict";
import test from "node:test";
import { isAuthFailure, MonitorCoordinator, runMonitorWithRecovery } from "./monitor-recovery.js";

test("retries a monitor once and allows auth recovery", async () => {
  let attempts = 0;
  let retries = 0;
  await runMonitorWithRecovery(
    async () => {
      attempts += 1;
      if (attempts === 1) throw Object.assign(new Error("Bad credentials"), { status: 401 });
    },
    async () => { retries += 1; },
    0,
  );
  assert.equal(attempts, 2);
  assert.equal(retries, 1);
  assert.equal(isAuthFailure({ response: { status: 401 } }), true);
});

test("fails after one recovery retry", async () => {
  let attempts = 0;
  await assert.rejects(
    runMonitorWithRecovery(async () => { attempts += 1; throw new Error("temporary failure"); }, undefined, 0),
    /temporary failure/,
  );
  assert.equal(attempts, 2);
});

test("runs independent monitors concurrently and deduplicates one build", async () => {
  const coordinator = new MonitorCoordinator();
  let active = 0;
  let maximum = 0;
  let release!: () => void;
  const blocked = new Promise<void>((resolve) => { release = resolve; });
  const task = async () => { active += 1; maximum = Math.max(maximum, active); await blocked; active -= 1; };
  assert.equal(coordinator.start("build-a", task, async () => undefined), true);
  assert.equal(coordinator.start("build-a", task, async () => undefined), false);
  assert.equal(coordinator.start("build-b", task, async () => undefined), true);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(maximum, 2);
  release();
  for (let attempt = 0; attempt < 20 && (coordinator.isActive("build-a") || coordinator.isActive("build-b")); attempt += 1) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(coordinator.isActive("build-a"), false);
  assert.equal(coordinator.isActive("build-b"), false);
});
