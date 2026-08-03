import { NextRequest, NextResponse } from "next/server";

const SESSION_COOKIE = "zhanlu_build_session";

export function middleware(request: NextRequest) {
  const next = `${request.nextUrl.pathname}${request.nextUrl.search}`;
  if (request.cookies.get(SESSION_COOKIE)?.value) {
    const requestHeaders = new Headers(request.headers);
    requestHeaders.set("x-protected-path", next || "/");
    return NextResponse.next({ request: { headers: requestHeaders } });
  }
  const login = new URL("/login", request.url);
  login.searchParams.set("next", next || "/");
  return NextResponse.redirect(login);
}

export const config = { matcher: ["/", "/schedules/:path*", "/builds/:path*"] };
