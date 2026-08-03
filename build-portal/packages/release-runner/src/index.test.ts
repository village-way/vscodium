import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import test from "node:test";
import { buildArguments, redact, runRelease } from "./index.js";

const spec = { kind: "development", version: "1.4.1", platform: "linux", sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, outputMode: "workflow-artifact", triggerOnly: false, syncGitLab: false, publish: false } as const;
test("portal invokes wrapper with deterministic attribution", () => { const args = buildArguments(spec, "request-1", "/work", true); assert.ok(args.includes("--request-id")); assert.ok(args.includes("--generate-only")); assert.ok(args.includes("--apply")); assert.ok(args.includes("--no-wait")); });
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
    await assert.rejects(() => runRelease(spec, "request-failure", { workspace, apply: true }), /zhanlu_build\.py exited with 128: fatal: unable to auto-detect email address/);
  } finally {
    if (previous === undefined) delete process.env.ZHANLU_BUILD_SCRIPT;
    else process.env.ZHANLU_BUILD_SCRIPT = previous;
    await rm(workspace, { recursive: true, force: true });
  }
});
