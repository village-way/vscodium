import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { schedules } from "./schema.js";

test("schedule schema exposes archival state", async () => {
  assert.ok(schedules.archivedAt);
  const migration = await readFile(resolve(new URL("../migrations/0002_schedule_archive.sql", import.meta.url).pathname), "utf8");
  assert.match(migration, /ADD COLUMN IF NOT EXISTS archived_at/);
});
