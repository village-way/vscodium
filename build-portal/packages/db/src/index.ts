import { drizzle } from "drizzle-orm/node-postgres";
import pg from "pg";
import * as schema from "./schema.js";

let pool: pg.Pool | undefined;

export function databaseUrl(): string {
  const value = process.env.DATABASE_URL;
  if (!value) throw new Error("DATABASE_URL is required");
  return value;
}

export function getPool(): pg.Pool {
  pool ??= new pg.Pool({ connectionString: databaseUrl(), max: Number(process.env.DB_POOL_SIZE ?? 10), application_name: process.env.APP_COMPONENT ?? "build-portal" });
  return pool;
}

export function db() { return drizzle(getPool(), { schema }); }
export { schema };

export async function withTransaction<T>(callback: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await getPool().connect();
  try { await client.query("BEGIN"); const result = await callback(client); await client.query("COMMIT"); return result; }
  catch (error) { await client.query("ROLLBACK"); throw error; }
  finally { client.release(); }
}

export async function appendBuildEvent(buildId: string, event: string, data: Record<string, unknown> = {}, level = "info"): Promise<void> {
  await getPool().query(
    `INSERT INTO build_events(build_id, sequence, event, data, level)
     SELECT $1, COALESCE(MAX(sequence), 0) + 1, $2, $3::jsonb, $4 FROM build_events WHERE build_id = $1`,
    [buildId, event, JSON.stringify(data), level],
  );
}

export async function closePool(): Promise<void> { if (pool) await pool.end(); pool = undefined; }
