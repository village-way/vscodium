"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { apiJson, writeHeaders, ApiError } from "../lib/api-client";
import { normalizeBuildForm } from "../lib/build-form";
import { useAuth } from "./auth-context";

type RefSnapshot = { repository: string; provider: string; ref: string; sha: string; sync_status: string; captured_at: string };
type Build = { id: string; spec: { version: string; platform: string; kind: string; publish?: boolean }; resolved?: { releaseVersion?: string }; phase: string; phase_reason?: string; created_at: string; release_url?: string; requested_by_username?: string };
type RefsResponse = { refs: RefSnapshot[] };

const statusLabels: Record<string, string> = { awaiting_confirmation: "待确认", queued: "排队中", source_sync_preview: "同步预检", source_sync: "同步中", preflight: "发布预检", release_prepare: "准备 Release", dispatching: "触发工作流", running: "构建中", succeeded: "构建成功", failed: "构建失败", cancelled: "已取消", needs_attention: "需人工处理", preview_queued: "准备预览", previewing: "生成预览" };
const terminal = new Set(["succeeded", "failed", "cancelled", "needs_attention"]);
const formatDate = (value: string) => new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Tokyo" }).format(new Date(value));

function statusClass(phase: string): string { return `status status-${phase}`; }

export function BuildWorkspace() {
  const { csrfToken } = useAuth();
  const router = useRouter();
  const [kind, setKind] = useState<"development" | "formal">("development");
  const [outputMode, setOutputMode] = useState("workflow-artifact");
  const [platform, setPlatform] = useState("all");
  const [version, setVersion] = useState("");
  const [sourceBranch, setSourceBranch] = useState("develop");
  const [deliveryProfile, setDeliveryProfile] = useState("default");
  const [zhanluCoreRef, setZhanluCoreRef] = useState("develop");
  const [zhanluVsRef, setZhanluVsRef] = useState("develop");
  const [bundleCodexRuntime, setBundleCodexRuntime] = useState(false);
  const [syncGitLab, setSyncGitLab] = useState(true);
  const [publish, setPublish] = useState(false);
  const [refs, setRefs] = useState<RefSnapshot[]>([]);
  const [builds, setBuilds] = useState<Build[]>([]);
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState("");

  useEffect(() => { if (kind === "formal") { setOutputMode("release"); setSyncGitLab(true); } else { setPublish(false); setSyncGitLab(false); setOutputMode((value) => value === "release" ? value : "workflow-artifact"); } }, [kind]);

  async function refresh() {
    try { const [buildData, refData] = await Promise.all([apiJson<{ builds: Build[] }>("/api/builds"), apiJson<RefsResponse>("/api/refs")]); setBuilds(buildData.builds); setRefs(refData.refs); }
    catch (error) { if (!(error instanceof ApiError && error.status === 401)) setMessage(error instanceof Error ? error.message : "加载数据失败"); }
  }
  useEffect(() => { void refresh(); }, []);

  const refOptions = useMemo(() => ({ code: refs.filter((item) => item.repository === "zhanlu-code"), core: refs.filter((item) => item.repository === "zhanlu-core"), vs: refs.filter((item) => item.repository === "zhanlu-vs") }), [refs]);

  async function preview(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setPending(true); setMessage("");
    try {
      const response = await apiJson<{ build: { id: string } }>("/api/build-previews", { method: "POST", headers: writeHeaders(csrfToken), body: JSON.stringify(normalizeBuildForm({ kind, version, platform, outputMode, sourceBranch, deliveryProfile, zhanluCoreRef, zhanluVsRef, bundleCodexRuntime, syncGitLab, publish })) });
      router.push(`/builds/${response.build.id}`);
    } catch (error) { setMessage(error instanceof Error ? error.message : "预览创建失败"); setPending(false); }
  }

  return <div className="workspace"><section className="page-heading"><div><p className="eyebrow">Stable release orchestration</p><h1>创建构建</h1><p className="muted">先生成不可变预览，确认后 Worker 才会同步源码并触发工作流。</p></div><a className="outline-button" href="/schedules">管理定时任务</a></section><div className="workspace-grid"><section className="panel form-panel"><div className="panel-heading"><div><h2>构建参数</h2><p className="muted">Development 可生成 workflow artifact；Formal 固定生成 Release。</p></div><span className="step-label">STEP 1 · PREVIEW</span></div><form onSubmit={preview}><div className="fields"><label>类型<select value={kind} onChange={(event) => setKind(event.target.value as "development" | "formal")}><option value="development">Development</option><option value="formal">Formal</option></select></label><label>版本<input value={version} onChange={(event) => setVersion(event.target.value)} required placeholder="1.4.1" /></label><label>平台<select value={platform} onChange={(event) => setPlatform(event.target.value)}><option value="all">全部平台</option><option value="linux">Linux</option><option value="macos">macOS</option><option value="windows">Windows</option></select></label><label>输出<select value={outputMode} onChange={(event) => setOutputMode(event.target.value)} disabled={kind === "formal"}><option value="workflow-artifact">Workflow artifact</option><option value="release">Draft release</option></select>{kind === "formal" && <small>Formal 构建固定为 Release</small>}</label><label>源码分支<select value={sourceBranch} onChange={(event) => setSourceBranch(event.target.value)}>{refOptions.code.length ? refOptions.code.map((item) => <option key={`${item.provider}:${item.ref}`} value={item.ref}>{item.ref}</option>) : <option value="develop">develop</option>}</select></label><label>Delivery Profile<input value={deliveryProfile} onChange={(event) => setDeliveryProfile(event.target.value)} required /></label><label>zhanlu-core ref<select value={zhanluCoreRef} onChange={(event) => setZhanluCoreRef(event.target.value)}>{refOptions.core.length ? refOptions.core.map((item) => <option key={`${item.provider}:${item.ref}`} value={item.ref}>{item.ref}</option>) : <option value="develop">develop</option>}</select></label><label>zhanlu-vs ref<select value={zhanluVsRef} onChange={(event) => setZhanluVsRef(event.target.value)}>{refOptions.vs.length ? refOptions.vs.map((item) => <option key={`${item.provider}:${item.ref}`} value={item.ref}>{item.ref}</option>) : <option value="develop">develop</option>}</select></label></div><div className="check-grid"><label className="checkbox-label"><input type="checkbox" checked={bundleCodexRuntime} onChange={(event) => setBundleCodexRuntime(event.target.checked)} />打包 Codex runtime</label>{kind === "formal" && <label className="checkbox-label"><input type="checkbox" checked={syncGitLab} onChange={(event) => setSyncGitLab(event.target.checked)} />同步 GitLab 组件 Release</label>}{kind === "formal" && <label className="checkbox-label warning-check"><input type="checkbox" checked={publish} onChange={(event) => setPublish(event.target.checked)} />正式发布（确认时还需输入短语）</label>}</div><div className="form-footer"><p className="form-message" role="status">{message}</p><button type="submit" disabled={pending}>{pending ? "生成中…" : "生成预览"}</button></div></form></section><aside className="panel ref-panel"><div className="panel-heading"><div><h2>源码快照</h2><p className="muted">预览使用最新采集的远端引用。</p></div><button className="ghost-button" type="button" onClick={() => void refresh()}>刷新</button></div>{["zhanlu-code", "zhanlu-core", "zhanlu-vs"].map((repository) => { const items = refs.filter((item) => item.repository === repository); return <div className="ref-group" key={repository}><div className="ref-group-title"><strong>{repository}</strong><span>{items.length ? `${items.length} 个引用` : "暂无快照"}</span></div>{items.slice(0, 3).map((item) => <div className="ref-row" key={`${item.provider}:${item.ref}`}><code>{item.ref}</code><span className="ref-meta">{item.sha.slice(0, 8)} · {item.sync_status} · {formatDate(item.captured_at)}</span></div>)}</div>; })}</aside></div><section className="panel recent-panel"><div className="panel-heading"><div><h2>最近构建</h2><p className="muted">打开详情查看不可变参数、事件和运行链接。</p></div><span className="count-pill">{builds.length}</span></div>{builds.length ? <div className="build-list">{builds.map((build) => <a className="build-row" href={`/builds/${build.id}`} key={build.id}><span className={statusClass(build.phase)}>{statusLabels[build.phase] ?? build.phase}</span><span className="build-main"><strong>{build.resolved?.releaseVersion ?? build.spec.version}</strong><span>{build.spec.kind} · {build.spec.platform === "all" ? "全部平台" : build.spec.platform} · {formatDate(build.created_at)}</span></span><span className="build-arrow" aria-hidden="true">→</span></a>)}</div> : <div className="empty-state">还没有构建记录。先生成一个预览开始吧。</div>}</section></div>;
}
