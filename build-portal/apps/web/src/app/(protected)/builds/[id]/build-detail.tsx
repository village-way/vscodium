"use client";

import { useCallback, useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { apiJson, writeHeaders, ApiError } from "../../../lib/api-client";
import { useAuth } from "../../auth-context";

type SourcePlanRow = { repository: string; requestedRef: string; destinationRef: string; gitlabSha: string; gitlabObjectSha: string; previousGithubSha: string; action: string };
type Build = { id: string; request_id: string; spec: Record<string, any>; resolved: Record<string, any>; confirmation_hash?: string; phase: string; phase_reason?: string; release_url?: string; created_at: string; updated_at: string; requested_by_username?: string };
type Run = { platform: string; workflow: string; run_id: string; run_url: string; status: string };
type Detail = { build: Build; runs: Run[] };

const labels: Record<string, string> = { awaiting_confirmation: "待确认", queued: "排队中", source_sync: "同步源码", preflight: "发布预检", dispatching: "触发工作流", succeeded: "已派发", failed: "失败", preview_queued: "等待预览", previewing: "生成预览" };
const terminal = new Set(["succeeded", "failed"]);
const date = (value?: string) => value ? new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Shanghai" }).format(new Date(value)) : "—";
const shortSha = (value?: string) => value ? value.slice(0, 12) : "<不存在>";

export function BuildDetail() {
  const { csrfToken } = useAuth();
  const params = useParams<{ id: string }>();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [message, setMessage] = useState("");
  const [pending, setPending] = useState(false);
  const [phrase, setPhrase] = useState("");
  const [confirming, setConfirming] = useState(false);

  const refresh = useCallback(async () => {
    try { setDetail(await apiJson<Detail>(`/api/builds/${params.id}`)); }
    catch (error) { if (!(error instanceof ApiError && error.status === 401)) setMessage(error instanceof Error ? error.message : "构建详情加载失败"); }
  }, [params.id]);
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => { if (!detail || terminal.has(detail.build.phase)) return; const timer = window.setInterval(() => void refresh(), 3000); return () => window.clearInterval(timer); }, [detail, refresh]);
  if (!detail) return <main className="detail-page"><div className="loading-state">正在加载构建详情…</div></main>;

  const { build, runs } = detail;
  const spec = build.spec;
  const resolved = build.resolved ?? {};
  const mirrorPlan = (resolved.mirrorPlan ?? []) as SourcePlanRow[];

  async function confirm() {
    setPending(true); setMessage("");
    try {
      await apiJson(`/api/builds/${build.id}/confirm`, { method: "POST", headers: writeHeaders(csrfToken), body: JSON.stringify({ confirmationHash: build.confirmation_hash, ...(spec.publish ? { phrase } : {}) }) });
      setConfirming(false); setPhrase(""); await refresh();
    } catch (error) { setMessage(error instanceof Error ? error.message : "确认失败，请重试"); }
    finally { setPending(false); }
  }

  return <main className="detail-page">
    <div className="detail-topbar"><a className="back-link" href="/">← 返回构建</a><button className="ghost-button" onClick={() => void refresh()}>刷新</button></div>
    <section className="panel detail-hero"><div><span className="request-id">请求 {build.request_id.slice(0, 8)}</span><h1>{resolved.releaseVersion ?? spec.version}</h1><p className="muted">{spec.kind === "formal" ? "正式版" : "开发版"} · {spec.platform === "all" ? "全部平台" : spec.platform} · {date(build.created_at)}</p></div><span className={`status status-large status-${build.phase}`}>{labels[build.phase] ?? build.phase}</span></section>
    {message && <p className="form-error detail-message" role="alert">{message}</p>}
    {build.phase === "failed" && <section className="failure-summary"><strong>门户处理失败</strong><span>未完成全部派发，请根据技术信息处理后创建新请求。</span><details><summary>技术信息</summary><code>{build.phase_reason}</code></details></section>}

    <section className="panel build-summary-panel">
      <div className="panel-heading"><h2>确认内容</h2><span className="muted">{build.requested_by_username ?? "系统"}</span></div>
      <div className="detail-facts compact-facts"><div><span>版本 / time patch</span><strong>{resolved.releaseVersion ?? "—"} / {resolved.timePatch ?? "—"}</strong></div><div><span>交付配置</span><strong>{resolved.deliveryProfile ?? spec.deliveryProfile}</strong></div><div><span>产物</span><strong>{spec.outputMode === "workflow-artifact" ? "工作流制品" : "Release"}</strong></div><div><span>源码策略</span><strong>五仓 develop + 选定 Ref</strong></div></div>
      <div className="section-heading"><h3>不可变同步计划</h3><span>GitLab SHA → GitHub 目标 Ref（精确 lease）</span></div>
      {mirrorPlan.length ? <div className="source-ref-table" role="table">
        <div className="source-ref-head" role="row"><span>仓库</span><span>请求引用</span><span>GitLab SHA</span><span>同步前 GitHub SHA</span><span>目标 Ref</span></div>
        {mirrorPlan.map((item) => <div className="source-ref-row" role="row" key={`${item.repository}:${item.destinationRef}`}><strong>{item.repository}</strong><code title={item.requestedRef}>{item.requestedRef}</code><code title={item.gitlabSha}>{shortSha(item.gitlabSha)}</code><span className="sha-transition"><code title={item.previousGithubSha}>{shortSha(item.previousGithubSha)}</code><b>→</b><code title={item.gitlabObjectSha}>{shortSha(item.gitlabObjectSha)}</code></span><code title={item.destinationRef}>{item.destinationRef.replace("refs/heads/", "")}</code></div>)}
      </div> : <div className="loading-state">Worker 正在解析远端 Ref 和 GitHub lease…</div>}
      {build.phase === "awaiting_confirmation" && <div className="action-bar"><button disabled={pending} onClick={() => setConfirming(true)}>检查无误，继续派发</button></div>}
    </section>

    <section className="panel runs-panel">
      <div className="panel-heading"><h2>GitHub Actions</h2><span className="muted">门户不复制构建日志</span></div>
      {runs.length ? <div className="run-list">{runs.map((run) => <div className="run-card" key={run.platform}><div><strong>{run.platform}</strong><span>{run.workflow}</span></div><span className="run-state success">已派发 · #{run.run_id}</span><a href={run.run_url} target="_blank" rel="noreferrer">打开 GitHub Actions →</a></div>)}</div> : <p className="muted">确认后将显示每个平台的精确运行链接。</p>}
      {build.release_url && <div className="action-bar"><a className="outline-button" href={build.release_url} target="_blank" rel="noreferrer">打开 GitHub Release</a></div>}
    </section>

    {confirming && <div className="modal-backdrop"><div className="confirm-dialog" role="dialog" aria-modal="true"><h2>确认远端写入与派发</h2><p>将按上表使用精确 force-with-lease 同步 GitLab 源码，并触发选定平台。Actions 状态和日志之后以 GitHub 为准。</p>{spec.publish && <label>输入确认短语 <strong>FORMAL {resolved.releaseVersion}</strong><input value={phrase} onChange={(event) => setPhrase(event.target.value)} autoFocus /></label>}<div className="action-bar"><button disabled={pending || (Boolean(spec.publish) && !phrase)} onClick={() => void confirm()}>{pending ? "确认中…" : "确认并触发"}</button><button className="secondary" disabled={pending} onClick={() => setConfirming(false)}>返回检查</button></div></div></div>}
  </main>;
}
