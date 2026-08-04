import assert from "node:assert/strict";
import test from "node:test";
import { runnerPhase } from "./runner-phase.js";

test("does not mark dispatching before the GitHub API call starts", () => {
  assert.equal(runnerPhase("Dispatching stable workflow(s)..."), undefined);
  assert.equal(runnerPhase("执行: GitHub workflow dispatch API stable-linux.yml --ref master …"), "dispatching");
});

test("keeps preparation phase markers", () => {
  assert.equal(runnerPhase("Previewing selected GitLab refs..."), "source_sync_preview");
  assert.equal(runnerPhase("Synchronizing selected GitLab refs..."), "source_sync");
  assert.equal(runnerPhase("Preflight checks passed"), "preflight");
  assert.equal(runnerPhase("Creating/updating the release before workflow fan-out..."), "release_prepare");
});
