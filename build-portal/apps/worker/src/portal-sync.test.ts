import assert from "node:assert/strict";
import test from "node:test";
import { buildSpecSchema } from "@zhanlu/build-portal-contracts";
import { parseSourcePlan, portalSyncArguments } from "./index.js";

const spec = buildSpecSchema.parse({ kind: "development", version: "1.4.2", platform: "all", sourceBranch: "feature/x", zhanluCoreRef: "develop", outputMode: "workflow-artifact" });

test("portal preview always includes four develop refs and only distinct custom refs", () => {
  const args = portalSyncArguments(spec, "/tmp/plan.tsv");
  const refs = args.flatMap((value, index) => args[index - 1] === "--ref" ? [value] : []);
  assert.deepEqual(refs.slice(0, 4), ["zhanlu-cloud=develop", "zhanlu-code=develop", "zhanlu-core=develop", "zhanlu-loc=develop"]);
  assert.deepEqual(refs.slice(4), ["zhanlu-code=feature/x"]);
  assert.equal(args.includes("--all-refs"), false);
});

test("source plan selects custom build SHAs while retaining every develop mirror", () => {
  const sha = (letter: string) => letter.repeat(40);
  const rows = [
    ["zhanlu-cloud", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("a"), sha("a"), "-", "create"],
    ["zhanlu-code", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("b"), sha("b"), sha("c"), "update"],
    ["zhanlu-core", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("d"), sha("d"), sha("d"), "unchanged"],
    ["zhanlu-loc", "branch", "develop", "refs/heads/develop", "refs/heads/develop", sha("e"), sha("e"), "-", "create"],
    ["zhanlu-code", "branch", "feature/x", "refs/heads/feature/x", "refs/heads/feature/x", sha("1"), sha("1"), "-", "create"],
  ];
  const parsed = parseSourcePlan(rows.map((row) => row.join("\t")).join("\n") + "\n", spec);
  assert.equal(parsed.mirrorPlan.length, 5);
  assert.equal(parsed.sourceRefs["zhanlu-code"]?.gitlabSha, sha("1"));
  assert.equal(parsed.sourceRefs["zhanlu-core"]?.gitlabSha, sha("d"));
});
