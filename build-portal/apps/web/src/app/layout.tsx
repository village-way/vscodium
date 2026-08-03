import type { Metadata } from "next";
import "./styles.css";

export const metadata: Metadata = { title: "湛卢构建门户", description: "Zhanlu Stable release orchestration" };
export default function Layout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="zh-CN"><body><header><strong>湛卢构建门户</strong><span>Stable 发布编排</span><nav><a href="/">构建</a><a href="/schedules">定时任务</a></nav></header><main>{children}</main></body></html>; }
