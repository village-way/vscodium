import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { closePool, getPool } from "./index.js";

const here = dirname(fileURLToPath(import.meta.url));
const migrationDir = resolve(here, "../migrations");
const files = (await readdir(migrationDir)).filter((file) => /^\d+_.*\.sql$/.test(file)).sort();
for (const file of files) await getPool().query(await readFile(resolve(migrationDir, file), "utf8"));
await closePool();
