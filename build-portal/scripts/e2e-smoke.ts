import assert from "node:assert/strict";

const base = (process.env.E2E_BASE_URL ?? "https://127.0.0.1:30443").replace(/\/$/, "");
const username = process.env.E2E_USERNAME ?? "admin";
const password = process.env.E2E_PASSWORD;
if (!password) throw new Error("E2E_PASSWORD is required");

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
type Json = Record<string, any>;

function cookiesFrom(response: Response): string {
  const values = typeof response.headers.getSetCookie === "function" ? response.headers.getSetCookie() : [response.headers.get("set-cookie") ?? ""];
  return values.map((value) => value.split(";", 1)[0]).filter(Boolean).join("; ");
}

async function request(path: string, init: RequestInit = {}, cookie = "") {
  const headers = new Headers(init.headers);
  if (cookie) headers.set("cookie", cookie);
  return fetch(`${base}${path}`, { ...init, headers });
}

async function main(): Promise<void> {
const redirect = await request("/", { redirect: "manual" });
assert.ok([301, 302, 307, 308].includes(redirect.status), `unauthenticated root should redirect, got ${redirect.status}`);
assert.match(redirect.headers.get("location") ?? "", /\/login\?next=/);
assert.equal((await request("/api/metrics")).status, 401);

const login = await request("/api/auth/login", { method: "POST", headers: { "content-type": "application/json", origin: base }, body: JSON.stringify({ username, password }) });
assert.equal(login.status, 200);
const loginValue = await login.json() as Json;
const cookie = cookiesFrom(login);
assert.ok(cookie);
assert.ok(loginValue.csrfToken);

const root = await request("/", {}, cookie);
assert.equal(root.status, 200);
const rootHtml = await root.text();
assert.match(rootHtml, /创建构建/);
assert.doesNotMatch(rootHtml, /管理员登录/);

const csrf = loginValue.csrfToken as string;
const headers = { "content-type": "application/json", "x-csrf-token": csrf, origin: base };
const preview = await request("/api/build-previews", { method: "POST", headers, body: JSON.stringify({ kind: "development", version: "1.4.1", platform: "linux", sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, outputMode: "workflow-artifact", triggerOnly: false, syncGitLab: false, publish: false }) }, cookie);
assert.equal(preview.status, 201);
const previewValue = await preview.json() as Json;
const build = previewValue.build as Json;
const detailPage = await request(`/builds/${build.id}`, {}, cookie);
assert.equal(detailPage.status, 200);
await detailPage.text();
const detail = await request(`/api/builds/${build.id}`, {}, cookie);
assert.equal(detail.status, 200);
const detailValue = await detail.json() as Json;
assert.equal(detailValue.build.id, build.id);
assert.ok(detailValue.build.confirmation_hash);

const confirmed = await request(`/api/builds/${build.id}/confirm`, { method: "POST", headers, body: JSON.stringify({ confirmationHash: build.confirmation_hash }) }, cookie);
assert.equal(confirmed.status, 200);
let phase = "queued";
for (let attempt = 0; attempt < 40; attempt += 1) {
  await sleep(500);
  const response = await request(`/api/builds/${build.id}`, {}, cookie);
  const value = await response.json() as Json;
  phase = value.build.phase;
  if (phase === "succeeded") break;
}
assert.equal(phase, "succeeded", `mock build ended in ${phase}`);

const schedule = await request("/api/schedules", { method: "POST", headers, body: JSON.stringify({ name: "e2e schedule", cron: "5 1 * * *", timezone: "Asia/Tokyo", enabled: true, spec: { kind: "development", version: "1.4.1", platform: "linux", sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, outputMode: "workflow-artifact", triggerOnly: false, syncGitLab: false, publish: false } }) }, cookie);
assert.equal(schedule.status, 201);
const scheduleValue = await schedule.json() as Json;
const scheduleId = scheduleValue.schedule.id as string;
const edited = await request(`/api/schedules/${scheduleId}`, { method: "PATCH", headers, body: JSON.stringify({ enabled: false }) }, cookie);
assert.equal(edited.status, 200);
const archived = await request(`/api/schedules/${scheduleId}`, { method: "DELETE", headers, body: "{}" }, cookie);
assert.equal(archived.status, 200);
const schedules = await request("/api/schedules", {}, cookie);
assert.equal(schedules.status, 200);
assert.equal(((await schedules.json()) as Json).schedules.some((item: Json) => item.id === scheduleId), false);

const logout = await request("/api/auth/logout", { method: "POST", headers }, cookie);
assert.equal(logout.status, 200);
assert.equal((await request("/api/builds", {}, cookie)).status, 401);
console.log("build portal HTTPS E2E smoke passed");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
