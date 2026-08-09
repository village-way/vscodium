import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import test from "node:test";
import { buildArguments, redact, runRelease } from "./index.js";

const spec = { kind: "development", version: "1.4.1", platform: "linux", sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, outputMode: "workflow-artifact", triggerOnly: false, syncGitLab: false, publish: false } as const;
test("portal invokes wrapper with a confirmed source plan", () => { const args = buildArguments(spec, "request-1", "/work", true, "/work/plan.tsv"); assert.ok(args.includes("--request-id")); assert.ok(args.includes("--generate-only")); assert.ok(args.includes("--apply")); assert.ok(args.includes("--no-wait")); assert.ok(args.includes("--portal-source-sync")); assert.equal(args[args.indexOf("--confirmed-source-plan") + 1], "/work/plan.tsv"); assert.equal(args.includes("--all-refs"), false); });
test("confirmed dispatch forwards persisted source commits", () => {
  const sourceRefs = {
    "zhanlu-code": { repository: "zhanlu-code", refType: "branch", requestedRef: "develop", sourceRef: "refs/heads/develop", destinationRef: "refs/heads/develop", gitlabSha: "a".repeat(40), gitlabObjectSha: "a".repeat(40), previousGithubSha: "d".repeat(40), action: "update" },
    "zhanlu-core": { repository: "zhanlu-core", refType: "branch", requestedRef: "develop", sourceRef: "refs/heads/develop", destinationRef: "refs/heads/develop", gitlabSha: "b".repeat(40), gitlabObjectSha: "b".repeat(40), previousGithubSha: "e".repeat(40), action: "update" },
    "zhanlu-vs": { repository: "zhanlu-vs", refType: "branch", requestedRef: "develop", sourceRef: "refs/heads/develop", destinationRef: "refs/heads/develop", gitlabSha: "c".repeat(40), gitlabObjectSha: "c".repeat(40), previousGithubSha: "f".repeat(40), action: "update" },
  };
  const args = buildArguments(spec, "request-2", "/work", true, "/work/plan.tsv", sourceRefs);
  assert.equal(args[args.indexOf("--source-commit") + 1], "a".repeat(40));
  assert.equal(args[args.indexOf("--zhanlu-core-commit") + 1], "b".repeat(40));
  assert.equal(args[args.indexOf("--zhanlu-vs-commit") + 1], "c".repeat(40));
});
test("secrets and URL credentials are redacted", () => { assert.equal(redact("Authorization: Bearer secret"), "Authorization: Bearer [REDACTED]"); assert.equal(redact("https://user:pass@example.test/x"), "https://[REDACTED]@example.test/x"); });
test("release runner redaction preserves safe failure hints", () => { assert.equal(redact("fatal: unable to auto-detect email address"), "fatal: unable to auto-detect email address"); });
test("release runner includes a redacted failure hint", async () => {
  const workspace = await mkdtemp(`${tmpdir()}/zhanlu-release-runner-`);
  const script = `${workspace}/fail.py`;
  const previous = process.env.ZHANLU_BUILD_SCRIPT;
  try {
    await mkdir(`${workspace}/vscodium`, { recursive: true });
    await writeFile(script, "import sys\nsys.stderr.write('fatal: unable to auto-detect email address\\n')\nsys.exit(128)\n", "utf8");
    process.env.ZHANLU_BUILD_SCRIPT = script;
    await assert.rejects(() => runRelease(spec, "request-failure", { workspace, apply: true, confirmedSourcePlan: `${workspace}/plan.tsv` }), /zhanlu_build\.py exited with 128: fatal: unable to auto-detect email address/);
  } finally {
    if (previous === undefined) delete process.env.ZHANLU_BUILD_SCRIPT;
    else process.env.ZHANLU_BUILD_SCRIPT = previous;
    await rm(workspace, { recursive: true, force: true });
  }
});
test("release runner preserves the actionable ANSI-prefixed error", async () => {
  const workspace = await mkdtemp(`${tmpdir()}/zhanlu-release-runner-`);
  const script = `${workspace}/fail.py`;
  const previous = process.env.ZHANLU_BUILD_SCRIPT;
  try {
    await mkdir(`${workspace}/vscodium`, { recursive: true });
    await writeFile(script, "import sys\nsys.stderr.write('\\x1b[0;31m[ERROR] stale delivery metadata\\x1b[0m\\n')\nsys.stderr.write('ERROR: command failed (1): bash trigger.sh\\n')\nsys.exit(1)\n", "utf8");
    process.env.ZHANLU_BUILD_SCRIPT = script;
    await assert.rejects(() => runRelease(spec, "request-failure", { workspace, apply: true, confirmedSourcePlan: `${workspace}/plan.tsv` }), /zhanlu_build\.py exited with 1: \[ERROR\] stale delivery metadata/);
  } finally {
    if (previous === undefined) delete process.env.ZHANLU_BUILD_SCRIPT;
    else process.env.ZHANLU_BUILD_SCRIPT = previous;
    await rm(workspace, { recursive: true, force: true });
  }
});
