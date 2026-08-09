import { hashPassword } from "./index.js";
import { closeDatabase, getDatabase, id, now } from "@zhanlu/build-portal-db";

async function main(): Promise<void> {
  const username = (process.env.BOOTSTRAP_ADMIN_USERNAME ?? "admin").trim().toLowerCase();
  const password = process.env.BOOTSTRAP_ADMIN_PASSWORD;
  if (!password || password.length < 16) throw new Error("BOOTSTRAP_ADMIN_PASSWORD must contain at least 16 characters");
  const database = getDatabase();
  const count = database.prepare("SELECT COUNT(*) AS count FROM users").get() as { count: number };
  if (Number(count.count) !== 0) {
    console.log("bootstrap skipped: an administrator already exists");
    closeDatabase();
    return;
  }
  const timestamp = now();
  database.prepare("INSERT INTO users(id,username,password_hash,created_at,updated_at) VALUES(?,?,?,?,?)")
    .run(id(), username, await hashPassword(password), timestamp, timestamp);
  closeDatabase();
}

void main();
