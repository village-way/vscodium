import { randomUUID } from "node:crypto";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { DatabaseSync, type StatementSync } from "node:sqlite";

let active: DatabaseSync | undefined;
let activePath: string | undefined;

export function databasePath(): string {
  return process.env.SQLITE_PATH ?? "/var/lib/zhanlu-build/state/portal.sqlite3";
}

export function getDatabase(): DatabaseSync {
  const filename = databasePath();
  if (active && activePath === filename) return active;
  if (active) active.close();
  mkdirSync(path.dirname(filename), { recursive: true });
  active = new DatabaseSync(filename);
  activePath = filename;
  active.exec("PRAGMA busy_timeout=10000; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;");
  migrate(active);
  return active;
}

export function migrate(database = getDatabase()): void {
  database.exec(`
    BEGIN IMMEDIATE;
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      username TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0,1)),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      csrf_hash TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      created_at INTEGER NOT NULL,
      last_seen_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS sessions_expires_idx ON sessions(expires_at);
    CREATE TABLE IF NOT EXISTS login_attempts (
      id TEXT PRIMARY KEY,
      username TEXT NOT NULL,
      ip_hash TEXT NOT NULL,
      succeeded INTEGER NOT NULL CHECK(succeeded IN (0,1)),
      attempted_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS login_attempts_window_idx ON login_attempts(username, ip_hash, attempted_at);
    CREATE TABLE IF NOT EXISTS builds (
      id TEXT PRIMARY KEY,
      request_id TEXT NOT NULL UNIQUE,
      spec TEXT NOT NULL,
      resolved TEXT,
      confirmation_hash TEXT,
      phase TEXT NOT NULL,
      phase_reason TEXT,
      requested_by TEXT REFERENCES users(id),
      confirmed_at INTEGER,
      lease_owner TEXT,
      lease_expires_at INTEGER,
      release_url TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS builds_claim_idx ON builds(phase, lease_expires_at, created_at);
    CREATE TABLE IF NOT EXISTS build_runs (
      id TEXT PRIMARY KEY,
      build_id TEXT NOT NULL REFERENCES builds(id) ON DELETE CASCADE,
      platform TEXT NOT NULL,
      workflow TEXT NOT NULL,
      run_id TEXT NOT NULL,
      run_url TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      UNIQUE(build_id, platform)
    );
    CREATE TABLE IF NOT EXISTS build_events (
      id TEXT PRIMARY KEY,
      build_id TEXT NOT NULL REFERENCES builds(id) ON DELETE CASCADE,
      sequence INTEGER NOT NULL,
      level TEXT NOT NULL,
      event TEXT NOT NULL,
      data TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      UNIQUE(build_id, sequence)
    );
    CREATE TABLE IF NOT EXISTS audit_events (
      id TEXT PRIMARY KEY,
      actor_id TEXT REFERENCES users(id),
      action TEXT NOT NULL,
      target_type TEXT NOT NULL,
      target_id TEXT,
      ip_hash TEXT,
      data TEXT NOT NULL,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS audit_events_created_idx ON audit_events(created_at DESC);
    INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(1, unixepoch('subsec') * 1000);
    COMMIT;
  `);
}

export function closeDatabase(): void {
  active?.close();
  active = undefined;
  activePath = undefined;
}

export function transaction<T>(callback: (database: DatabaseSync) => T): T {
  const database = getDatabase();
  database.exec("BEGIN IMMEDIATE");
  try {
    const result = callback(database);
    database.exec("COMMIT");
    return result;
  } catch (error) {
    database.exec("ROLLBACK");
    throw error;
  }
}

export function statement(sql: string): StatementSync { return getDatabase().prepare(sql); }
export function now(): number { return Date.now(); }
export function id(): string { return randomUUID(); }

export function appendBuildEvent(buildId: string, event: string, data: Record<string, unknown> = {}, level = "info"): void {
  transaction((database) => {
    const row = database.prepare("SELECT COALESCE(MAX(sequence), 0) AS sequence FROM build_events WHERE build_id=?").get(buildId) as { sequence: number };
    database.prepare("INSERT INTO build_events(id,build_id,sequence,level,event,data,created_at) VALUES(?,?,?,?,?,?,?)")
      .run(id(), buildId, Number(row.sequence) + 1, level, event, JSON.stringify(data), now());
  });
}

export function parseJson<T>(value: unknown, fallback: T): T {
  if (typeof value !== "string") return fallback;
  try { return JSON.parse(value) as T; } catch { return fallback; }
}

export function iso(value: unknown): string | null {
  return typeof value === "number" ? new Date(value).toISOString() : null;
}
