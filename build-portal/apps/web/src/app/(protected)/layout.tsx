import { headers, cookies } from "next/headers";
import { redirect } from "next/navigation";
import { authenticate, csrfTokenFor, SESSION_COOKIE } from "@zhanlu/build-portal-auth";
import { AuthProvider, type AuthUser } from "./auth-context";
import { AppShell } from "./app-shell";
import { safeNext } from "../lib/url";

export const dynamic = "force-dynamic";

export default async function ProtectedLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const cookieStore = await cookies();
  const session = await authenticate(cookieStore.get(SESSION_COOKIE)?.value);
  if (!session) {
    const requestHeaders = await headers();
    const path = requestHeaders.get("x-protected-path") ?? requestHeaders.get("x-invoke-path") ?? "/";
    redirect(`/login?next=${encodeURIComponent(safeNext(path))}`);
  }
  const user: AuthUser = { id: session.userId, username: session.username };
  return <AuthProvider value={{ user, csrfToken: csrfTokenFor(session.sessionId) }}><AppShell>{children}</AppShell></AuthProvider>;
}
