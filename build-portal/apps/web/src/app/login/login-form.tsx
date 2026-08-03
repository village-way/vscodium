"use client";

import { FormEvent, useState } from "react";

export function LoginForm({ next, expired }: { next: string; expired: boolean }) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(expired ? "登录状态已过期，请重新登录" : "");

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setPending(true); setError("");
    try {
      const response = await fetch("/api/auth/login", { method: "POST", headers: { "content-type": "application/json", origin: location.origin }, body: JSON.stringify({ username, password }) });
      const value = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(value.error ?? "登录失败，请重试");
      location.href = next;
    } catch (value) {
      setError(value instanceof Error ? value.message : "登录失败，请重试"); setPending(false);
    }
  }

  return <section className="login-card" aria-labelledby="login-title"><div className="login-card-heading"><p className="eyebrow">Administrator access</p><h2 id="login-title">登录工作台</h2><p className="muted">登录后才能创建、确认或管理构建任务。</p></div><form onSubmit={submit}><label htmlFor="username">用户名<input id="username" name="username" autoComplete="username" value={username} onChange={(event) => setUsername(event.target.value)} required /></label><label htmlFor="password">密码<input id="password" name="password" type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} required /></label>{error && <p className="form-error" role="alert">{error}</p>}<button type="submit" disabled={pending}>{pending ? "登录中…" : "登录"}</button></form><p className="login-footnote">连接地址仅供内网使用 · Session 有效期 12 小时</p></section>;
}
