import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { argon2id } from "@noble/hashes/argon2";
import { getPool } from "@zhanlu/build-portal-db";

export const SESSION_COOKIE = "zhanlu_build_session";
const SESSION_SECONDS = 12 * 60 * 60;

export function secretHash(value: string): string { return createHash("sha256").update(value).digest("hex"); }
export function ipHash(ip: string): string { return secretHash(`${process.env.IP_HASH_SECRET ?? requireSecret("IP_HASH_SECRET")}\0${ip}`); }
function requireSecret(name: string): string { const value = process.env[name]; if (!value) throw new Error(`${name} is required`); return value; }

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16); const digest = argon2id(password, salt, { m: 65536, t: 3, p: 1, dkLen: 32 });
  return `$argon2id$v=19$m=65536,t=3,p=1$${salt.toString("base64")}$${Buffer.from(digest).toString("base64")}`;
}

async function verifyPassword(encoded: string, password: string): Promise<boolean> {
  const parts = encoded.split("$"); if (parts.length !== 6 || parts[1] !== "argon2id") return false;
  const parameters = Object.fromEntries(parts[3]!.split(",").map((part) => part.split("="))); const salt = Buffer.from(parts[4]!, "base64"); const expected = Buffer.from(parts[5]!, "base64");
  const actual = Buffer.from(argon2id(password, salt, { m: Number(parameters.m), t: Number(parameters.t), p: Number(parameters.p), dkLen: expected.length })); return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export async function login(username: string, password: string, ip: string): Promise<{ sessionId: string; csrfToken: string; user: { id: string; username: string } }> {
  const pool = getPool();
  const normalized = username.trim().toLowerCase();
  const hashedIp = ipHash(ip);
  const recent = await pool.query<{ count: string }>("SELECT count(*)::text AS count FROM login_attempts WHERE succeeded=false AND attempted_at > now() - interval '15 minutes' AND (username=$1 OR ip_hash=$2)", [normalized, hashedIp]);
  if (Number(recent.rows[0]?.count ?? 0) >= 5) throw new AuthError("login rate limit exceeded", 429);
  const result = await pool.query<{ id: string; username: string; password_hash: string }>("SELECT id, username, password_hash FROM users WHERE username=$1 AND disabled=false", [normalized]);
  const user = result.rows[0];
  const valid = user ? await verifyPassword(user.password_hash, password) : await verifyPassword(await hashPassword("rate-limit-equalizer"), password).then(() => false);
  await pool.query("INSERT INTO login_attempts(username, ip_hash, succeeded) VALUES($1,$2,$3)", [normalized, hashedIp, valid]);
  if (!valid || !user) throw new AuthError("invalid credentials", 401);
  const sessionId = randomBytes(32).toString("base64url");
  const csrfToken = randomBytes(32).toString("base64url");
  await pool.query("INSERT INTO sessions(id,user_id,csrf_hash,expires_at) VALUES($1,$2,$3,now()+($4 || ' seconds')::interval)", [secretHash(sessionId), user.id, secretHash(csrfToken), SESSION_SECONDS]);
  await audit(user.id, "auth.login", "session", null, hashedIp);
  return { sessionId, csrfToken, user: { id: user.id, username: user.username } };
}

export type AuthSession = { sessionId: string; userId: string; username: string; csrfHash: string };
export async function authenticate(cookieValue: string | undefined): Promise<AuthSession | null> {
  if (!cookieValue) return null;
  const result = await getPool().query<{ user_id: string; username: string; csrf_hash: string }>("SELECT s.user_id,u.username,s.csrf_hash FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.id=$1 AND s.expires_at>now() AND u.disabled=false", [secretHash(cookieValue)]);
  if (!result.rows[0]) return null;
  await getPool().query("UPDATE sessions SET last_seen_at=now() WHERE id=$1", [secretHash(cookieValue)]);
  return { sessionId: cookieValue, userId: result.rows[0].user_id, username: result.rows[0].username, csrfHash: result.rows[0].csrf_hash };
}

export async function rotateCsrf(session: AuthSession): Promise<string> { const token = randomBytes(32).toString("base64url"); await getPool().query("UPDATE sessions SET csrf_hash=$2,last_seen_at=now() WHERE id=$1", [secretHash(session.sessionId), secretHash(token)]); return token; }

export function verifyCsrf(session: AuthSession, token: string | undefined): boolean {
  if (!token) return false;
  const actual = Buffer.from(secretHash(token)); const expected = Buffer.from(session.csrfHash);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function verifyOrigin(origin: string | null): boolean {
  const expected = requireSecret("PUBLIC_ORIGIN");
  if (!origin) return false;
  try { return new URL(origin).origin === new URL(expected).origin; } catch { return false; }
}

export async function logout(cookieValue: string): Promise<void> { await getPool().query("DELETE FROM sessions WHERE id=$1", [secretHash(cookieValue)]); }
export async function audit(actorId: string | null, action: string, targetType: string, targetId: string | null, hashedIp?: string, data: Record<string, unknown> = {}): Promise<void> { await getPool().query("INSERT INTO audit_events(actor_id,action,target_type,target_id,ip_hash,data) VALUES($1,$2,$3,$4,$5,$6::jsonb)", [actorId, action, targetType, targetId, hashedIp ?? null, JSON.stringify(data)]); }
export function sessionCookie(value: string, clear = false): string { return `${SESSION_COOKIE}=${clear ? "" : value}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${clear ? 0 : SESSION_SECONDS}`; }
export class AuthError extends Error { constructor(message: string, readonly status: number) { super(message); } }
