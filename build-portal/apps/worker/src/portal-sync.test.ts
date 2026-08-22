import assert from "node:assert/strict";
import test from "node:test";
import { buildSpecSchema } from "@zhanlu/build-portal-contracts";
import { parseSourcePlan, portalSyncArguments } from "./index.js";

const spec = buildSpecSchema.parse({ kind: "development", version: "1.4.2", platform: "all", vscodiumRef: "dev-agent-host", sourceBranch: "feature/x", zhanluCoreRef: "develop", zhanluVsRef: "refs/tags/v1", outputMode: "workflow-artifact" });
const nativeSpec = buildSpecSchema.parse({ ...spec, zhanluVsRef: "" }); // zhanlu_change

test("portal preview always includes five develop refs and only distinct custom refs", () => {
  const args = portalSyncArguments(spec, "/tmp/plan.tsv");
  const refs = args.flatMap((value, index) => args[index - 1] === "--ref" ? [value] : []);
  assert.deepEqual(refs.slice(0, 5), ["zhanlu-cloud=develop", "zhanlu-code=develop", "zhanlu-core=develop", "zhanlu-loc=develop", "zhanlu-vs=develop"]);
  assert.deepEqual(refs.slice(5), ["zhanlu-code=feature/x", "zhanlu-vs=refs/tags/v1"]);
  assert.equal(args.includes("--all-refs"), false);
});

test("native Agent preview omits the retired zhanlu-vs repository", () => {
  const args = portalSyncArguments(nativeSpec, "/tmp/plan.tsv");
  const refs = args.flatMap((value, index) => args[index - 1] === "--ref" ? [value] : []);
  assert.deepEqual(refs, ["zhanlu-cloud=develop", "zhanlu-code=develop", "zhanlu-core=develop", "zhanlu-loc=develop", "zhanlu-code=feature/x"]);
});

test("source plan selects custom build SHAs while retaining every develop mirror", () => {
  const sha = (letter: string) => letter.repeat(40);
  const rows = [
    ["zhanlu-cloud", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("a"), sha("a"), "-", "create"],
    ["zhanlu-code", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("b"), sha("b"), sha("c"), "update"],
    ["zhanlu-core", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("d"), sha("d"), sha("d"), "unchanged"],
    ["zhanlu-loc", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("e"), sha("e"), "-", "create"],
    ["zhanlu-vs", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("f"), sha("f"), "-", "create"],
    ["zhanlu-code", "branch", "feature/x", "refs/heads/feature/x", "refs/heads/feature/x", sha("1"), sha("1"), "-", "create"],
    ["zhanlu-vs", "tag", "refs/tags/v1", "refs/tags/v1", "refs/tags/v1", sha("2"), sha("2"), "-", "create"],
  ];
  const parsed = parseSourcePlan(rows.map((row) => row.join("\t")).join("\n") + "\n", spec);
  assert.equal(parsed.mirrorPlan.length, 7);
  assert.equal(parsed.sourceRefs["zhanlu-code"]?.gitlabSha, sha("1"));
  assert.equal(parsed.sourceRefs["zhanlu-core"]?.gitlabSha, sha("d"));
  assert.equal(parsed.sourceRefs["zhanlu-vs"]?.gitlabSha, sha("2"));
});

test("native Agent source plan resolves Code and Core without zhanlu-vs", () => {
  const sha = (letter: string) => letter.repeat(40);
  const rows = [
    ["zhanlu-cloud", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("a"), sha("a"), "-", "create"],
    ["zhanlu-code", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("b"), sha("b"), "-", "create"],
    ["zhanlu-core", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("c"), sha("c"), "-", "create"],
    ["zhanlu-loc", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("d"), sha("d"), "-", "create"],
    ["zhanlu-code", "branch", "feature/x", "refs/heads/feature/x", "refs/heads/feature/x", sha("e"), sha("e"), "-", "create"],
  ];
  const parsed = parseSourcePlan(rows.map((row) => row.join("\t")).join("\n") + "\n", nativeSpec);
  assert.deepEqual(Object.keys(parsed.sourceRefs), ["zhanlu-code", "zhanlu-core"]);
});
