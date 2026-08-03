import test from "node:test";
import assert from "node:assert/strict";
import { nextOccurrence, previousOccurrence } from "./scheduling.js";

test("scheduler computes Asia/Tokyo occurrences deterministically", () => {
  const now = new Date("2026-08-03T00:00:00.000Z");
  assert.equal(previousOccurrence("5 1 * * *", "Asia/Tokyo", now).toISOString(), "2026-08-02T16:05:00.000Z");
  assert.equal(nextOccurrence("5 1 * * *", "Asia/Tokyo", now).toISOString(), "2026-08-03T16:05:00.000Z");
});
