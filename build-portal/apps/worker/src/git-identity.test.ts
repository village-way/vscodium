import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import test from "node:test";
import { configureReleaseGitIdentity, releaseGitIdentity } from "./git-identity.js";

const exec = promisify(execFile);

test("configures and verifies the release identity in a checkout", async () => {
  const path = await mkdtemp(`${tmpdir()}/zhanlu-git-identity-`);
  try {
    await exec("git", ["init", "-q", path]);
    const identity = await configureReleaseGitIdentity(path, { RELEASE_GIT_USER_NAME: "village-way", RELEASE_GIT_USER_EMAIL: "wandepen@163.com" });
    assert.deepEqual(identity, { name: "village-way", email: "wandepen@163.com" });
    const configured = await exec("git", ["-C", path, "config", "--local", "--get-regexp", "^user\\."]);
    assert.match(configured.stdout, /user\.name village-way/);
    assert.match(configured.stdout, /user\.email wandepen@163\.com/);
  } finally {
    await rm(path, { recursive: true, force: true });
  }
});

test("rejects an explicitly empty identity", () => {
  assert.throws(() => releaseGitIdentity({ RELEASE_GIT_USER_NAME: "", RELEASE_GIT_USER_EMAIL: "" }), /RELEASE_GIT_USER_NAME/);
});
