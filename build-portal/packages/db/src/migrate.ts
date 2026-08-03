import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { closePool, getPool } from "./index.js";

const here = dirname(fileURLToPath(import.meta.url));
const migration = await readFile(resolve(here, "../migrations/0001_initial.sql"), "utf8");
await getPool().query(migration);
await closePool();
