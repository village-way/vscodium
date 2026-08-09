import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { argon2id } from "@noble/hashes/argon2";
import { getDatabase, id, now } from "@zhanlu/build-portal-db";

export const SESSION_COOKIE = "zhanlu_build_session";
const SESSION_SECONDS = 12 * 60 * 60;

function requireSecret(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
}

export function secretHash(value: string): string { return createHash("sha256").update(value).digest("hex"); }
export function ipHash(ip: string): string { return secretHash(`${requireSecret("IP_HASH_SECRET")}\0${ip}`); }
export function csrfTokenFor(sessionId: string): string { return createHmac("sha256", requireSecret("CSRF_HMAC_SECRET")).update(sessionId).digest("base64url"); }

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const digest = argon2id(password, salt, { m: 65536, t: 3, p: 1, dkLen: 32 });
  return `$argon2id$v=19$m=65536,t=3,p=1$${salt.toString("base64")}$${Buffer.from(digest).toString("base64")}`;
}

async function verifyPassword(encoded: string, password: string): Promise<boolean> {
  const parts = encoded.split("$");
  if (parts.length !== 6 || parts[1] !== "argon2id") return false;
  const parameters = Object.fromEntries(parts[3]!.split(",").map((part) => part.split("=")));
  const salt = Buffer.from(parts[4]!, "base64");
  const expected = Buffer.from(parts[5]!, "base64");
  const actual = Buffer.from(argon2id(password, salt, { m: Number(parameters.m), t: Number(parameters.t), p: Number(parameters.p), dkLen: expected.length }));
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export async function login(username: string, password: string, ip: string): Promise<{ sessionId: string; csrfToken: string; user: { id: string; username: string } }> {
  const database = getDatabase();
  const normalized = username.trim().toLowerCase();
  const hashedIp = ipHash(ip);
  const cutoff = now() - 15 * 60_000;
  const recent = database.prepare("SELECT COUNT(*) AS count FROM login_attempts WHERE succeeded=0 AND attempted_at>? AND (username=? OR ip_hash=?)").get(cutoff, normalized, hashedIp) as { count: number };
  if (Number(recent.count) >= 5) throw new AuthError("登录尝试过于频繁，请 15 分钟后再试", 429);
  const user = database.prepare("SELECT id,username,password_hash FROM users WHERE username=? AND disabled=0").get(normalized) as { id: string; username: string; password_hash: string } | undefined;
  const valid = user ? await verifyPassword(user.password_hash, password) : await verifyPassword(await hashPassword("rate-limit-equalizer"), password).then(() => false);
  database.prepare("INSERT INTO login_attempts(id,username,ip_hash,succeeded,attempted_at) VALUES(?,?,?,?,?)").run(id(), normalized, hashedIp, valid ? 1 : 0, now());
  if (!valid || !user) throw new AuthError("用户名或密码错误", 401);
  const sessionId = randomBytes(32).toString("base64url");
  const csrfToken = csrfTokenFor(sessionId);
  const timestamp = now();
  database.prepare("INSERT INTO sessions(id,user_id,csrf_hash,expires_at,created_at,last_seen_at) VALUES(?,?,?,?,?,?)")
    .run(secretHash(sessionId), user.id, secretHash(csrfToken), timestamp + SESSION_SECONDS * 1000, timestamp, timestamp);
  await audit(user.id, "auth.login", "session", null, hashedIp);
  return { sessionId, csrfToken, user: { id: user.id, username: user.username } };
}

export type AuthSession = { sessionId: string; userId: string; username: string; csrfHash: string };
export async function authenticate(cookieValue: string | undefined): Promise<AuthSession | null> {
  if (!cookieValue) return null;
  const database = getDatabase();
  const row = database.prepare("SELECT s.user_id,u.username,s.csrf_hash FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.id=? AND s.expires_at>? AND u.disabled=0")
    .get(secretHash(cookieValue), now()) as { user_id: string; username: string; csrf_hash: string } | undefined;
  if (!row) return null;
  database.prepare("UPDATE sessions SET last_seen_at=? WHERE id=?").run(now(), secretHash(cookieValue));
  return { sessionId: cookieValue, userId: row.user_id, username: row.username, csrfHash: row.csrf_hash };
}

export async function rotateCsrf(session: AuthSession): Promise<string> { return csrfTokenFor(session.sessionId); }
export function verifyCsrf(session: AuthSession, token: string | undefined): boolean {
  if (!token) return false;
  const actual = Buffer.from(secretHash(token));
  const expected = Buffer.from(secretHash(csrfTokenFor(session.sessionId)));
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}
export function verifyOrigin(origin: string | null): boolean {
  if (!origin) return false;
  try { return new URL(origin).origin === new URL(requireSecret("PUBLIC_ORIGIN")).origin; } catch { return false; }
}
export async function logout(cookieValue: string): Promise<void> { getDatabase().prepare("DELETE FROM sessions WHERE id=?").run(secretHash(cookieValue)); }
export async function audit(actorId: string | null, action: string, targetType: string, targetId: string | null, hashedIp?: string, data: Record<string, unknown> = {}): Promise<void> {
  getDatabase().prepare("INSERT INTO audit_events(id,actor_id,action,target_type,target_id,ip_hash,data,created_at) VALUES(?,?,?,?,?,?,?,?)")
    .run(id(), actorId, action, targetType, targetId, hashedIp ?? null, JSON.stringify(data), now());
}
export function sessionCookie(value: string, clear = false): string { return `${SESSION_COOKIE}=${clear ? "" : value}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${clear ? 0 : SESSION_SECONDS}`; }
export class AuthError extends Error { constructor(message: string, readonly status: number) { super(message); } }
