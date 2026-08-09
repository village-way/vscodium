import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { promisify } from "node:util";
import test from "node:test";
import { appendBuildEvent, closeDatabase, getDatabase, id, now, transaction } from "./index.js";

const exec = promisify(execFile);

test("SQLite enables durability pragmas and transactions roll back atomically", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zhanlu-portal-db-"));
  const previous = process.env.SQLITE_PATH;
  process.env.SQLITE_PATH = path.join(root, "state", "portal.sqlite3");
  try {
    closeDatabase();
    const database = getDatabase();
    assert.equal((database.prepare("PRAGMA journal_mode").get() as { journal_mode: string }).journal_mode, "wal");
    assert.equal((database.prepare("PRAGMA foreign_keys").get() as { foreign_keys: number }).foreign_keys, 1);
    const user = id(); const timestamp = now();
    database.prepare("INSERT INTO users(id,username,password_hash,created_at,updated_at) VALUES(?,?,?,?,?)").run(user, "admin", "hash", timestamp, timestamp);
    assert.throws(() => transaction((active) => {
      active.prepare("INSERT INTO audit_events(id,actor_id,action,target_type,data,created_at) VALUES(?,?,?,?,?,?)").run(id(), user, "test", "test", "{}", now());
      throw new Error("rollback");
    }), /rollback/);
    assert.equal((database.prepare("SELECT COUNT(*) AS count FROM audit_events").get() as { count: number }).count, 0);
    const build = id();
    database.prepare("INSERT INTO builds(id,request_id,spec,phase,created_at,updated_at) VALUES(?,?,?,?,?,?)").run(build, id(), "{}", "queued", timestamp, timestamp);
    appendBuildEvent(build, "phase.changed", { phase: "queued" });
    appendBuildEvent(build, "phase.changed", { phase: "dispatching" });
    assert.deepEqual((database.prepare("SELECT sequence FROM build_events ORDER BY sequence").all() as Array<{ sequence: number }>).map((row) => row.sequence), [1, 2]);
  } finally {
    closeDatabase();
    if (previous === undefined) delete process.env.SQLITE_PATH; else process.env.SQLITE_PATH = previous;
    await rm(root, { recursive: true, force: true });
  }
});

test("backup command creates an integrity-checked restorable SQLite file", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "zhanlu-portal-backup-"));
  const state = path.join(root, "state", "portal.sqlite3");
  const backups = path.join(root, "backups");
  const previous = process.env.SQLITE_PATH;
  process.env.SQLITE_PATH = state;
  try {
    closeDatabase();
    getDatabase().prepare("INSERT INTO users(id,username,password_hash,created_at,updated_at) VALUES(?,?,?,?,?)").run(id(), "admin", "hash", now(), now());
    closeDatabase();
    await exec("node", ["--import", "tsx", "packages/db/src/backup.ts"], { cwd: process.cwd(), env: { ...process.env, SQLITE_PATH: state, SQLITE_BACKUP_DIR: backups } });
    const files = (await readdir(backups)).filter((entry) => entry.endsWith(".sqlite3"));
    assert.equal(files.length, 1);
    const restored = new DatabaseSync(path.join(backups, files[0]!), { readOnly: true });
    assert.equal((restored.prepare("PRAGMA integrity_check").get() as Record<string, unknown>).integrity_check, "ok");
    assert.equal((restored.prepare("SELECT COUNT(*) AS count FROM users").get() as { count: number }).count, 1);
    restored.close();
  } finally {
    closeDatabase();
    if (previous === undefined) delete process.env.SQLITE_PATH; else process.env.SQLITE_PATH = previous;
    await rm(root, { recursive: true, force: true });
  }
});
