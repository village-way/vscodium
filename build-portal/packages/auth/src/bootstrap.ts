import { hashPassword } from "./index.js";
import { closePool, getPool } from "@zhanlu/build-portal-db";

const username = (process.env.BOOTSTRAP_ADMIN_USERNAME ?? "admin").trim().toLowerCase();
const password = process.env.BOOTSTRAP_ADMIN_PASSWORD;
if (!password || password.length < 16) throw new Error("BOOTSTRAP_ADMIN_PASSWORD must contain at least 16 characters");
const count = await getPool().query<{ count: string }>("SELECT count(*)::text AS count FROM users");
if (Number(count.rows[0]?.count ?? 0) !== 0) throw new Error("bootstrap refused: users already exist");
await getPool().query("INSERT INTO users(username,password_hash) VALUES($1,$2)", [username, await hashPassword(password)]);
await closePool();
