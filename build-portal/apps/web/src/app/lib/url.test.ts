import test from "node:test";
import assert from "node:assert/strict";
import { safeNext } from "./url.js";

test("safeNext only accepts internal absolute paths", () => {
  assert.equal(safeNext("/builds"), "/builds");
  assert.equal(safeNext("/builds/123?tab=events"), "/builds/123?tab=events");
  assert.equal(safeNext("//evil.example"), "/");
  assert.equal(safeNext("https://evil.example"), "/");
  assert.equal(safeNext(undefined), "/");
});
