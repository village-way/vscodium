import type { Metadata } from "next";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { authenticate, SESSION_COOKIE } from "@zhanlu/build-portal-auth";
import { LoginForm } from "./login-form";
import { safeNext } from "../lib/url";

export const dynamic = "force-dynamic";
export const metadata: Metadata = { title: "构建门户", description: "Stable release orchestration" };

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ next?: string; reason?: string }> }) {
  const cookieStore = await cookies();
  if (await authenticate(cookieStore.get(SESSION_COOKIE)?.value)) redirect("/");
  const params = await searchParams;
  return <main className="login-page"><section className="login-brand"><p className="eyebrow">Stable Release</p><h1>构建门户</h1><p>集中管理 Stable 构建预览、确认、运行监控和定时任务。</p><span className="login-hint">仅限授权管理员使用</span></section><LoginForm next={safeNext(params.next)} expired={params.reason === "expired"} /></main>;
}
