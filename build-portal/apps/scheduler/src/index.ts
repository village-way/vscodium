import { CronExpressionParser } from "cron-parser";
import { getPool, closePool, withTransaction } from "@zhanlu/build-portal-db";
import { scheduleInputSchema } from "@zhanlu/build-portal-contracts";

const SCAN_MS = 30_000; const CATCH_UP_MS = 15 * 60_000; const LOCK_ID = 0x5a48414e;
let firstScan = true;

export async function scan(now = new Date()): Promise<number> {
  return withTransaction(async (client) => {
    const lock = await client.query<{ locked: boolean }>("SELECT pg_try_advisory_xact_lock($1) AS locked", [LOCK_ID]);
    if (!lock.rows[0]?.locked) return 0;
    const schedules = await client.query("SELECT * FROM schedules WHERE enabled=true"); let created = 0;
    for (const row of schedules.rows) {
      const value = scheduleInputSchema.parse({ name: row.name, cron: row.cron, timezone: row.timezone, enabled: row.enabled, spec: row.spec });
      const previous = CronExpressionParser.parse(value.cron, { currentDate: now, tz: value.timezone }).prev().toDate();
      const age = now.getTime() - previous.getTime();
      if (age < 0 || age > (firstScan ? CATCH_UP_MS : SCAN_MS + 5_000)) continue;
      // Keep the occurrence/build link explicit.  The previous data-modifying
      // CTE could insert both rows but leave build_id NULL on PostgreSQL 16,
      // orphaning the scheduler occurrence from the queued build.
      const occurrence = await client.query<{ id: string }>(
        `INSERT INTO schedule_occurrences(schedule_id,scheduled_for)
         VALUES($1,$2) ON CONFLICT DO NOTHING RETURNING id`,
        [row.id, previous],
      );
      if (!occurrence.rows[0]) continue;
      const build = await client.query<{ id: string }>(
        `INSERT INTO builds(spec,phase,confirmed_at)
         VALUES($1::jsonb,'queued',now()) RETURNING id`,
        [JSON.stringify(value.spec)],
      );
      const buildId = build.rows[0]?.id;
      if (!buildId) throw new Error("scheduler build insert returned no id");
      await client.query(
        `UPDATE schedule_occurrences SET build_id=$2,status='queued' WHERE id=$1`,
        [occurrence.rows[0].id, buildId],
      );
      created += 1;
    }
    firstScan = false; return created;
  });
}

async function main() { console.log("scheduler started"); while (true) { try { const created = await scan(); if (created) console.log(`created ${created} occurrence(s)`); } catch (error) { console.error("scheduler scan failed", error instanceof Error ? error.message : "unknown"); } await new Promise((resolve) => setTimeout(resolve, SCAN_MS)); } }
const shutdown = async () => { await closePool(); process.exit(0); }; process.on("SIGTERM", shutdown); process.on("SIGINT", shutdown);
if (process.env.NODE_ENV !== "test") void main();
