import assert from "node:assert/strict";
import test from "node:test";
import { buildArguments, redact } from "./index.js";

const spec = { kind: "development", version: "1.4.1", platform: "linux", sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, outputMode: "workflow-artifact", triggerOnly: false, syncGitLab: false, publish: false } as const;
test("portal invokes wrapper with deterministic attribution", () => { const args = buildArguments(spec, "request-1", "/work", true); assert.ok(args.includes("--request-id")); assert.ok(args.includes("--generate-only")); assert.ok(args.includes("--apply")); assert.ok(args.includes("--no-wait")); });
test("secrets and URL credentials are redacted", () => { assert.equal(redact("Authorization: Bearer secret"), "Authorization: Bearer [REDACTED]"); assert.equal(redact("https://user:pass@example.test/x"), "https://[REDACTED]@example.test/x"); });
