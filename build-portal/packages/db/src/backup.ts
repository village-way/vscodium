import { mkdir, open, readdir, rename, stat, unlink } from "node:fs/promises";
import path from "node:path";
import { backup, DatabaseSync } from "node:sqlite";
import { closeDatabase, getDatabase } from "./index.js";

async function main(): Promise<void> {
  const backupRoot = process.env.SQLITE_BACKUP_DIR ?? "/var/lib/zhanlu-build/backups";
  const retentionDays = Number(process.env.SQLITE_BACKUP_RETENTION_DAYS ?? 14);
  await mkdir(backupRoot, { recursive: true });
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
  const destination = path.join(backupRoot, `zhanlu-build-${stamp}.sqlite3`);
  const temporary = `${destination}.tmp-${process.pid}`;
  try {
    await backup(getDatabase(), temporary);
    const restored = new DatabaseSync(temporary, { readOnly: true });
    const result = restored.prepare("PRAGMA integrity_check").get() as Record<string, unknown>;
    restored.close();
    if (Object.values(result)[0] !== "ok") throw new Error(`SQLite integrity_check failed: ${JSON.stringify(result)}`);
    const handle = await open(temporary, "r");
    await handle.sync();
    await handle.close();
    await rename(temporary, destination);
    const cutoff = Date.now() - retentionDays * 86_400_000;
    for (const entry of await readdir(backupRoot)) {
      if (!/^zhanlu-build-.*\.sqlite3$/.test(entry) || entry === path.basename(destination)) continue;
      const candidate = path.join(backupRoot, entry);
      if ((await stat(candidate)).mtimeMs < cutoff) await unlink(candidate);
    }
    console.log(`SQLite backup verified: ${destination}`);
  } finally {
    await unlink(temporary).catch(() => undefined);
    closeDatabase();
  }
}

void main();
