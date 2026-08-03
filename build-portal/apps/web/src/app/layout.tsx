import type { Metadata } from "next";
import "./styles.css";

export const metadata: Metadata = { title: "湛卢构建门户", description: "Zhanlu Stable release orchestration" };
export default function Layout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="zh-CN"><body>{children}</body></html>; }
