"use client";

import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { apiJson, writeHeaders, ApiError } from "../lib/api-client";
import { normalizeBuildForm } from "../lib/build-form";
import { useAuth } from "./auth-context";

type Repository = "zhanlu-code" | "zhanlu-core" | "zhanlu-vs";
type Build = { id: string; spec: { version: string; platform: string; kind: string }; resolved?: { releaseVersion?: string }; phase: string; created_at: string };
const statusLabels: Record<string, string> = { awaiting_confirmation: "待确认", queued: "排队中", source_sync: "同步源码", preflight: "发布预检", dispatching: "触发工作流", succeeded: "已派发", failed: "失败", preview_queued: "等待预览", previewing: "生成预览" };
const formatDate = (value?: string) => value ? new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Shanghai" }).format(new Date(value)) : "—";

function RefField({ repository, value, onChange }: { repository: Repository; value: string; onChange: (value: string) => void }) {
  return <label className="ref-field"><span>{repository}</span><input value={value} onChange={(event) => onChange(event.target.value)} required placeholder="develop / tag / SHA" autoComplete="off" spellCheck={false} /></label>;
}

export function BuildWorkspace() {
  const { csrfToken } = useAuth();
  const router = useRouter();
  const [kind, setKind] = useState<"development" | "formal">("development");
  const [outputMode, setOutputMode] = useState("workflow-artifact");
  const [platform, setPlatform] = useState("all");
  const [version, setVersion] = useState("");
  const [zhanluCodeRef, setZhanluCodeRef] = useState("develop");
  const [deliveryProfile, setDeliveryProfile] = useState("default");
  const [zhanluCoreRef, setZhanluCoreRef] = useState("develop");
  const [zhanluVsRef, setZhanluVsRef] = useState("develop");
  const [bundleCodexRuntime, setBundleCodexRuntime] = useState(false);
  const [syncGitLab, setSyncGitLab] = useState(false);
  const [publish, setPublish] = useState(false);
  const [builds, setBuilds] = useState<Build[]>([]);
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => {
    if (kind === "formal") { setOutputMode("release"); setSyncGitLab(true); }
    else { setPublish(false); setSyncGitLab(false); setOutputMode("workflow-artifact"); }
  }, [kind]);

  async function refresh() {
    try { setBuilds((await apiJson<{ builds: Build[] }>("/api/builds")).builds); }
    catch (error) { if (!(error instanceof ApiError && error.status === 401)) setMessage(error instanceof Error ? error.message : "加载数据失败"); }
  }
  useEffect(() => { void refresh(); }, []);

  async function preview(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setMessage("");
    try {
      const response = await apiJson<{ build: { id: string } }>("/api/build-previews", {
        method: "POST",
        headers: writeHeaders(csrfToken),
        body: JSON.stringify(normalizeBuildForm({ kind, version, platform, outputMode, zhanluCodeRef, deliveryProfile, zhanluCoreRef, zhanluVsRef, bundleCodexRuntime, syncGitLab, publish })),
      });
      router.push(`/builds/${response.build.id}`);
    } catch (error) { setMessage(error instanceof Error ? error.message : "预览创建失败"); setPending(false); }
  }

  return <div className="workspace">
    <section className="page-heading"><div><h1>创建构建</h1><p className="muted">先生成五仓同步预览，确认后触发 GitHub Actions。</p></div></section>
    <section className="panel form-panel">
      <div className="panel-heading"><h2>构建参数</h2><span className="workflow-chip">vscodium@master</span></div>
      <form onSubmit={preview}>
        <div className="fields">
          <label>类型<select value={kind} onChange={(event) => setKind(event.target.value as "development" | "formal")}><option value="development">开发版</option><option value="formal">正式版</option></select></label>
          <label>版本<input value={version} onChange={(event) => setVersion(event.target.value)} required placeholder="1.4.2" /></label>
          <label>平台<select value={platform} onChange={(event) => setPlatform(event.target.value)}><option value="all">全部平台</option><option value="linux">Linux</option><option value="macos">macOS</option><option value="windows">Windows</option></select></label>
          <label>产物<select value={outputMode} onChange={(event) => setOutputMode(event.target.value)} disabled={kind === "formal"}><option value="workflow-artifact">工作流制品</option><option value="release">Release</option></select></label>
          <label>交付配置<input value={deliveryProfile} onChange={(event) => setDeliveryProfile(event.target.value)} required /></label>
          <div className="source-section">
            <div className="source-section-heading"><strong>构建源码</strong><span>五个组件的 develop 始终同步；以下三个仓库可追加自定义 Ref。</span></div>
            <div className="source-fields"><RefField repository="zhanlu-code" value={zhanluCodeRef} onChange={setZhanluCodeRef} /><RefField repository="zhanlu-core" value={zhanluCoreRef} onChange={setZhanluCoreRef} /><RefField repository="zhanlu-vs" value={zhanluVsRef} onChange={setZhanluVsRef} /></div>
          </div>
        </div>
        <div className="check-grid">
          <label className="checkbox-label"><input type="checkbox" checked={bundleCodexRuntime} onChange={(event) => setBundleCodexRuntime(event.target.checked)} />打包 Codex runtime</label>
          {kind === "formal" && <label className="checkbox-label"><input type="checkbox" checked={syncGitLab} onChange={(event) => setSyncGitLab(event.target.checked)} />同步 GitLab 组件 Release</label>}
          {kind === "formal" && <label className="checkbox-label warning-check"><input type="checkbox" checked={publish} onChange={(event) => setPublish(event.target.checked)} />正式发布（需要输入确认短语）</label>}
        </div>
        <div className="form-footer"><p className="form-message" role="status">{message}</p><button type="submit" disabled={pending}>{pending ? "已提交…" : "生成同步预览"}</button></div>
      </form>
    </section>
    <section className="panel recent-panel"><div className="panel-heading"><div><h2>最近派发</h2><p className="muted">Actions 状态和日志请从详情页进入 GitHub 查看。</p></div><span className="count-pill">{builds.length}</span></div>{builds.length ? <div className="build-list">{builds.map((build) => <a className="build-row" href={`/builds/${build.id}`} key={build.id}><span className={`status status-${build.phase}`}>{statusLabels[build.phase] ?? build.phase}</span><span className="build-main"><strong>{build.resolved?.releaseVersion ?? build.spec.version}</strong><span>{build.spec.kind === "formal" ? "正式版" : "开发版"} · {build.spec.platform === "all" ? "全部平台" : build.spec.platform} · {formatDate(build.created_at)}</span></span><span className="build-arrow">→</span></a>)}</div> : <div className="empty-state">还没有构建记录。</div>}</section>
  </div>;
}
