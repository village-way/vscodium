import { CronExpressionParser } from "cron-parser";

export function previousOccurrence(cron: string, timezone: string, now: Date): Date {
  return CronExpressionParser.parse(cron, { currentDate: now, tz: timezone }).prev().toDate();
}

export function nextOccurrence(cron: string, timezone: string, now = new Date()): Date {
  return CronExpressionParser.parse(cron, { currentDate: now, tz: timezone }).next().toDate();
}
