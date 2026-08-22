import { randomUUID } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";
import { authenticate, audit, AuthError, ipHash, login, logout, rotateCsrf, SESSION_COOKIE, sessionCookie, verifyCsrf, verifyOrigin } from "@zhanlu/build-portal-auth";
import { buildSpecSchema } from "@zhanlu/build-portal-contracts";
import { getDatabase, iso, now, parseJson, transaction } from "@zhanlu/build-portal-db";

export const runtime = "nodejs";
const json = (value: unknown, status = 200) => NextResponse.json(value, { status, headers: { "cache-control": "no-store" } });
const clientIp = (request: NextRequest) => request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";

async function requestBody(request: NextRequest): Promise<unknown> {
  try { return await request.json(); } catch { throw new HttpError("invalid JSON body", 400); }
}

function buildId(path: string[], suffix?: string): string | null {
  return path[0] === "builds" && path[1] && (!suffix || path[2] === suffix) ? path[1] : null;
}

function serializeBuild(row: Record<string, unknown>): Record<string, unknown> {
  return {
    ...row,
    spec: parseJson(row.spec, {}),
    resolved: parseJson(row.resolved, {}),
    created_at: iso(row.created_at),
    updated_at: iso(row.updated_at),
    confirmed_at: iso(row.confirmed_at),
    lease_expires_at: undefined,
    lease_owner: undefined,
  };
}

async function handler(request: NextRequest, context: { params: Promise<{ path: string[] }> }) {
  const { path } = await context.params;
  const route = path.join("/");
  const method = request.method;
  if (route === "health/live") return json({ status: "ok" });
  if (route === "health/ready") {
    try { getDatabase().prepare("SELECT 1").get(); return json({ status: "ready" }); }
    catch { return json({ status: "not_ready" }, 503); }
  }
  if (route === "auth/login" && method === "POST") {
    if (!verifyOrigin(request.headers.get("origin"))) throw new HttpError("invalid origin", 403);
    const value = await requestBody(request) as Record<string, unknown>;
    const result = await login(String(value.username ?? ""), String(value.password ?? ""), clientIp(request));
    const response = json({ user: result.user, csrfToken: result.csrfToken });
    response.headers.set("set-cookie", sessionCookie(result.sessionId));
    return response;
  }

  const session = await authenticate(request.cookies.get(SESSION_COOKIE)?.value);
  if (!session) throw new HttpError("authentication required", 401);
  if (route === "auth/me" && method === "GET") return json({ user: { id: session.userId, username: session.username }, csrfToken: await rotateCsrf(session) });
  if (route === "metrics" && method === "GET") {
    const counts = getDatabase().prepare("SELECT phase,COUNT(*) AS count FROM builds GROUP BY phase").all() as Array<{ phase: string; count: number }>;
    return new NextResponse(counts.map((row) => `zhanlu_builds{phase=\"${row.phase}\"} ${row.count}`).join("\n") + "\n", { headers: { "content-type": "text/plain; version=0.0.4", "cache-control": "no-store" } });
  }
  if (method !== "GET" && (!verifyOrigin(request.headers.get("origin")) || !verifyCsrf(session, request.headers.get("x-csrf-token") ?? undefined))) throw new HttpError("CSRF validation failed", 403);
  if (route === "auth/logout" && method === "POST") {
    await logout(session.sessionId);
    const response = json({ ok: true });
    response.headers.set("set-cookie", sessionCookie("", true));
    return response;
  }

  if (route === "build-previews" && method === "POST") {
    const spec = buildSpecSchema.parse(await requestBody(request));
    if (spec.triggerOnly) throw new HttpError("triggerOnly is not available in the portal", 400);
    const timestamp = now();
    const build = {
      id: randomUUID(),
      requestId: randomUUID(),
      spec,
      resolved: {
        refs: { vscodiumRef: spec.vscodiumRef, sourceBranch: spec.sourceBranch, zhanluCoreRef: spec.zhanluCoreRef, zhanluVsRef: spec.zhanluVsRef }, // zhanlu_change
        deliveryProfile: spec.deliveryProfile,
        platforms: spec.platform === "all" ? ["macos", "linux", "windows"] : [spec.platform],
        syncScope: spec.zhanluVsRef ? "five-develop-plus-selected" : "four-develop-plus-selected", // zhanlu_change
        githubVisibility: spec.publish ? "published" : "draft",
        syncGitLab: spec.kind === "formal" && spec.syncGitLab,
      },
    };
    getDatabase().prepare("INSERT INTO builds(id,request_id,spec,resolved,phase,requested_by,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)")
      .run(build.id, build.requestId, JSON.stringify(spec), JSON.stringify(build.resolved), "preview_queued", session.userId, timestamp, timestamp);
    await audit(session.userId, "build.preview.requested", "build", build.id, ipHash(clientIp(request)), { requestId: build.requestId });
    return json({ build: { id: build.id } }, 201);
  }

  if (route === "builds" && method === "GET") {
    const rows = getDatabase().prepare("SELECT b.*,u.username AS requested_by_username FROM builds b LEFT JOIN users u ON u.id=b.requested_by ORDER BY b.created_at DESC LIMIT 100").all() as Array<Record<string, unknown>>;
    return json({ builds: rows.map(serializeBuild) });
  }
  const id = buildId(path);
  if (id && path.length === 2 && method === "GET") {
    const row = getDatabase().prepare("SELECT b.*,u.username AS requested_by_username FROM builds b LEFT JOIN users u ON u.id=b.requested_by WHERE b.id=?").get(id) as Record<string, unknown> | undefined;
    if (!row) throw new HttpError("build not found", 404);
    const runs = (getDatabase().prepare("SELECT platform,workflow,run_id,run_url,status,created_at,updated_at FROM build_runs WHERE build_id=? ORDER BY platform").all(id) as Array<Record<string, unknown>>)
      .map((run) => ({ ...run, created_at: iso(run.created_at), updated_at: iso(run.updated_at) }));
    return json({ build: serializeBuild(row), runs });
  }
  const confirmId = buildId(path, "confirm");
  if (confirmId && method === "POST") {
    const value = await requestBody(request) as Record<string, unknown>;
    const row = transaction((database) => {
      const current = database.prepare("SELECT * FROM builds WHERE id=?").get(confirmId) as Record<string, unknown> | undefined;
      if (!current) throw new HttpError("build not found", 404);
      if (current.phase !== "awaiting_confirmation") throw new HttpError("build is not awaiting confirmation", 409);
      if (value.confirmationHash !== current.confirmation_hash) throw new HttpError("preview changed or confirmation hash is invalid", 409);
      const spec = parseJson<Record<string, unknown>>(current.spec, {});
      const resolved = parseJson<Record<string, unknown>>(current.resolved, {});
      if (spec.publish && value.phrase !== `FORMAL ${resolved.releaseVersion}`) throw new HttpError("formal publish confirmation phrase does not match", 409);
      database.prepare("UPDATE builds SET phase='queued',confirmed_at=?,lease_owner=NULL,lease_expires_at=NULL,updated_at=? WHERE id=?").run(now(), now(), confirmId);
      return { spec };
    });
    await audit(session.userId, row.spec.publish ? "build.formal_publish_confirm" : "build.confirm", "build", confirmId, ipHash(clientIp(request)));
    return json({ phase: "queued" });
  }
  throw new HttpError("route not found", 404);
}

class HttpError extends Error { constructor(message: string, readonly status: number) { super(message); } }
async function dispatch(request: NextRequest, context: { params: Promise<{ path: string[] }> }) {
  try { return await handler(request, context); }
  catch (error) {
    if (error instanceof HttpError || error instanceof AuthError) return json({ error: error.message }, error.status);
    if (error && typeof error === "object" && "issues" in error) return json({ error: "validation failed", issues: (error as { issues: unknown }).issues }, 400);
    console.error("request failed", error instanceof Error ? error.message : "unknown");
    return json({ error: "internal error" }, 500);
  }
}
export const GET = dispatch;
export const POST = dispatch;
