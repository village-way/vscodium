"use client";

import { useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import { useAuth } from "./auth-context";

export function AppShell({ children }: { children: React.ReactNode }) {
  const { user, csrfToken } = useAuth();
  const pathname = usePathname();
  const router = useRouter();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");

  async function logout() {
    setPending(true); setError("");
    try {
      const response = await fetch("/api/auth/logout", { method: "POST", headers: { "x-csrf-token": csrfToken, origin: location.origin } });
      if (!response.ok) throw new Error("退出登录失败，请重试");
      location.href = "/login";
    } catch (value) {
      setError(value instanceof Error ? value.message : "退出登录失败，请重试"); setPending(false);
    }
  }

  return <>
    <header className="app-header">
      <div className="brand"><strong>湛卢构建门户</strong><span>Stable 发布编排</span></div>
      <nav aria-label="主导航"><a className={pathname === "/" ? "active" : ""} href="/">构建</a><a className={pathname.startsWith("/schedules") ? "active" : ""} href="/schedules">定时任务</a></nav>
      <div className="account"><span className="account-name">{user.username}</span><button className="ghost-button" disabled={pending} onClick={logout}>{pending ? "退出中…" : "退出登录"}</button></div>
    </header>
    {error && <div className="shell-error" role="alert">{error}</div>}
    <main>{children}</main>
  </>;
}
