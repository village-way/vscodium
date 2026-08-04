"use client";

import { useCallback, useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { apiJson, writeHeaders, ApiError } from "../../../lib/api-client";
import { useAuth } from "../../auth-context";

type SourceRefResult = { repository: string; refType: string; requestedRef: string; sourceRef: string; destinationRef: string; gitlabSha: string; gitlabObjectSha: string; previousGithubSha: string; action: string };
type Build = { id: string; request_id: string; spec: Record<string, any>; resolved: Record<string, any>; confirmation_hash?: string; phase: string; phase_reason?: string; release_url?: string; created_at: string; updated_at: string; requested_by_username?: string };
type Run = { platform: string; workflow: string; run_id?: string; run_url?: string; status: string; conclusion?: string };
type Detail = { build: Build; runs: Run[] };

const repositories = ["zhanlu-code", "zhanlu-core", "zhanlu-vs"] as const;
const labels: Record<string, string> = { awaiting_confirmation: "待确认", queued: "排队中", source_sync_preview: "源码预检", source_sync: "源码同步", preflight: "发布预检", release_prepare: "准备 Release", dispatching: "触发工作流", running: "平台构建", succeeded: "构建成功", failed: "构建失败", cancelled: "已取消", needs_attention: "需人工处理", preview_queued: "准备预览", previewing: "生成预览" };
const terminal = new Set(["succeeded", "failed", "cancelled", "needs_attention"]);
const date = (value?: string) => value ? new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Tokyo" }).format(new Date(value)) : "—";
const shortSha = (value?: string) => value ? value.slice(0, 12) : "—";

function requestedRef(spec: Record<string, any>, repository: string): string {
  if (repository === "zhanlu-code") return spec.sourceBranch ?? "—";
  if (repository === "zhanlu-core") return spec.zhanluCoreRef ?? "—";
  return spec.zhanluVsRef ?? "—";
}

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
  useEffect(() => { if (!detail || terminal.has(detail.build.phase)) return; const timer = window.setInterval(() => void refresh(), 10_000); return () => window.clearInterval(timer); }, [detail, refresh]);

  if (!detail) return <main className="detail-page"><div className="loading-state">正在加载构建详情…</div></main>;

  const { build, runs } = detail;
  const spec = build.spec;
  const resolved = build.resolved ?? {};
  const sourceRefs = (resolved.sourceRefs ?? {}) as Record<string, SourceRefResult>;
  const hasActionsRun = runs.some((run) => Boolean(run.run_url));

  async function action(operation: "confirm" | "cancel" | "retry") {
    setPending(true); setMessage("");
    try {
      const failedPlatforms = runs.filter((run) => ["failure", "cancelled"].includes(run.conclusion ?? "")).map((run) => run.platform);
      const payload = operation === "confirm" ? { confirmationHash: build.confirmation_hash, ...(spec.publish ? { phrase } : {}) } : operation === "retry" ? { platforms: failedPlatforms } : {};
      await apiJson(`/api/builds/${build.id}/${operation}`, { method: "POST", headers: writeHeaders(csrfToken), body: JSON.stringify(payload) });
      setConfirming(false); setPhrase(""); await refresh();
    } catch (error) { setMessage(error instanceof Error ? error.message : "操作失败，请重试"); }
    finally { setPending(false); }
  }

  const retryable = runs.some((run) => ["failure", "cancelled"].includes(run.conclusion ?? ""));
  const preDispatchRetryable = build.phase === "failed" && runs.length === 0;
  return <main className="detail-page">
    <div className="detail-topbar"><a className="back-link" href="/">← 返回构建</a><button className="ghost-button" onClick={() => void refresh()}>刷新</button></div>
    <section className="panel detail-hero"><div><span className="request-id">请求 {build.request_id.slice(0, 8)}</span><h1>{resolved.releaseVersion ?? spec.version}</h1><p className="muted">{spec.kind === "formal" ? "正式版" : "开发版"} · {spec.platform === "all" ? "全部平台" : spec.platform} · {date(build.created_at)}</p></div><span className={`status status-large status-${build.phase}`}>{labels[build.phase] ?? build.phase}</span></section>
    {message && <p className="form-error detail-message" role="alert">{message}</p>}
    {build.phase_reason && ["failed", "needs_attention"].includes(build.phase) && <section className="failure-summary" role="status"><strong>{build.phase === "needs_attention" ? "构建需人工处理" : "构建失败"}</strong><span>{hasActionsRun ? "操作未完成，请前往 GitHub Actions 查看执行详情。" : "尚未创建 GitHub Actions 运行，请查看技术信息。"}</span><details><summary>技术信息</summary><code>{build.phase_reason}</code></details></section>}

    <div className="detail-grid">
      <section className="panel build-summary-panel">
        <div className="panel-heading"><h2>构建设置</h2><span className="muted">{build.requested_by_username ?? "系统"}</span></div>
        <div className="detail-facts compact-facts"><div><span>版本 / time patch</span><strong>{resolved.releaseVersion ?? "—"} / {resolved.timePatch ?? "—"}</strong></div><div><span>交付配置</span><strong>{resolved.deliveryProfile ?? spec.deliveryProfile}</strong></div><div><span>产物</span><strong>{spec.outputMode === "workflow-artifact" ? "工作流制品" : "Release"}</strong></div><div><span>工作流</span><strong>vscodium@master</strong></div></div>
        <div className="section-heading"><h3>源码版本</h3><span>GitLab → GitHub</span></div>
        <div className="source-ref-table" role="table" aria-label="源码同步结果">
          <div className="source-ref-head" role="row"><span role="columnheader">仓库</span><span role="columnheader">请求引用</span><span role="columnheader">GitLab SHA</span><span role="columnheader">同步前 GitHub SHA</span><span role="columnheader">构建 SHA</span></div>
          {repositories.map((repository) => {
            const item = sourceRefs[repository];
            return <div className="source-ref-row" role="row" key={repository}><strong role="cell">{repository}</strong><code role="cell" data-label="请求引用" title={requestedRef(spec, repository)}>{requestedRef(spec, repository)}</code><code role="cell" data-label="GitLab SHA" title={item?.gitlabSha}>{shortSha(item?.gitlabSha)}</code><span role="cell" data-label="同步前 GitHub SHA" className="sha-transition"><code title={item?.previousGithubSha}>{shortSha(item?.previousGithubSha)}</code><b aria-label="同步到">→</b><code title={item?.gitlabObjectSha}>{shortSha(item?.gitlabObjectSha)}</code></span><code role="cell" data-label="构建 SHA" title={item?.gitlabSha}>{shortSha(item?.gitlabSha)}</code></div>;
          })}
        </div>
      </section>

      <section className="panel runs-panel">
        <div className="panel-heading"><h2>平台运行</h2><span className="muted">{date(build.updated_at)}</span></div>
        {runs.length ? <div className="run-list">{runs.map((run) => <div className="run-card" key={run.platform}><div><strong>{run.platform}</strong><span>{run.workflow}</span></div><span className={`run-state ${run.conclusion ?? run.status}`}>{run.conclusion ?? run.status}</span>{run.run_url && <a href={run.run_url} target="_blank" rel="noreferrer">打开 GitHub Actions →</a>}</div>)}</div> : <p className="muted">尚未创建平台运行。</p>}
        <div className="action-bar">{build.phase === "awaiting_confirmation" && <button disabled={pending} onClick={() => setConfirming(true)}>确认构建</button>}{["preview_queued", "previewing", "awaiting_confirmation", "queued"].includes(build.phase) && <button className="secondary" disabled={pending} onClick={() => void action("cancel")}>取消构建</button>}{preDispatchRetryable && <button className="secondary" disabled={pending} onClick={() => void action("retry")}>重试构建</button>}{build.phase === "failed" && retryable && <button className="secondary" disabled={pending} onClick={() => void action("retry")}>重试失败平台</button>}</div>
      </section>
    </div>

    {confirming && <div className="modal-backdrop" role="presentation"><div className="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="confirm-title"><h2 id="confirm-title">确认构建</h2><p>确认后会将选定 GitLab 引用同步到 GitHub，并触发构建。</p>{spec.publish && <label>输入确认短语 <strong>FORMAL {resolved.releaseVersion}</strong><input value={phrase} onChange={(event) => setPhrase(event.target.value)} autoFocus /></label>}<div className="action-bar"><button disabled={pending || (Boolean(spec.publish) && !phrase)} onClick={() => void action("confirm")}>{pending ? "确认中…" : "确认并排队"}</button><button className="secondary" disabled={pending} onClick={() => setConfirming(false)}>返回检查</button></div></div></div>}
  </main>;
}
