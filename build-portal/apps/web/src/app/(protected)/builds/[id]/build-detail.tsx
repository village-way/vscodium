"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { apiJson, writeHeaders, ApiError } from "../../../lib/api-client";
import { useAuth } from "../../auth-context";

type Snapshot = { repository: string; provider: string; ref: string; sha: string; sync_status: string; captured_at: string };
type Build = { id: string; request_id: string; spec: Record<string, any>; resolved: Record<string, any>; confirmation_hash?: string; phase: string; phase_reason?: string; release_url?: string; created_at: string; updated_at: string; requested_by_username?: string };
type Run = { platform: string; workflow: string; run_id?: string; run_url?: string; status: string; conclusion?: string; failed_jobs?: string[] };
type Event = { id: string; level: string; event: string; data: Record<string, unknown>; created_at: string };
type Detail = { build: Build; runs: Run[]; events: Event[] };

const labels: Record<string, string> = { awaiting_confirmation: "待确认", queued: "排队中", source_sync_preview: "同步预检", source_sync: "同步中", preflight: "发布预检", release_prepare: "准备 Release", dispatching: "触发工作流", running: "构建中", succeeded: "构建成功", failed: "构建失败", cancelled: "已取消", needs_attention: "需人工处理", preview_queued: "准备预览", previewing: "生成预览" };
const terminal = new Set(["succeeded", "failed", "cancelled", "needs_attention"]);
const date = (value?: string) => value ? new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Tokyo" }).format(new Date(value)) : "—";
const jsonValue = (value: unknown) => typeof value === "string" ? value : JSON.stringify(value);

export function BuildDetail() {
  const { csrfToken } = useAuth();
  const params = useParams<{ id: string }>();
  const router = useRouter();
  const [detail, setDetail] = useState<Detail | null>(null);
  const [message, setMessage] = useState("");
  const [pending, setPending] = useState(false);
  const [phrase, setPhrase] = useState("");
  const [confirming, setConfirming] = useState(false);

  const refresh = useCallback(async () => { try { setDetail(await apiJson<Detail>(`/api/builds/${params.id}`)); } catch (error) { if (!(error instanceof ApiError && error.status === 401)) setMessage(error instanceof Error ? error.message : "构建详情加载失败"); } }, [params.id]);
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => { if (!detail || terminal.has(detail.build.phase)) return; const timer = window.setInterval(() => void refresh(), 10_000); return () => window.clearInterval(timer); }, [detail, refresh]);

  const snapshot = useMemo(() => Array.isArray(detail?.build.resolved?.refSnapshot) ? detail?.build.resolved?.refSnapshot as Snapshot[] : [], [detail]);
  if (!detail) return <main className="detail-page"><div className="loading-state">正在加载构建详情…</div></main>;
  const { build, runs, events } = detail;
  const spec = build.spec;
  const resolved = build.resolved ?? {};

  async function action(operation: "confirm" | "cancel" | "retry") {
    setPending(true); setMessage("");
    try {
      const payload = operation === "confirm" ? { confirmationHash: build.confirmation_hash, ...(spec.publish ? { phrase } : {}) } : operation === "retry" ? { platforms: runs.filter((run) => ["failure", "cancelled"].includes(run.conclusion ?? "")).map((run) => run.platform) } : {};
      await apiJson(`/api/builds/${build.id}/${operation}`, { method: "POST", headers: writeHeaders(csrfToken), body: JSON.stringify(payload) });
      setConfirming(false); setPhrase(""); await refresh();
    } catch (error) { setMessage(error instanceof Error ? error.message : "操作失败，请重试"); }
    finally { setPending(false); }
  }

  const retryable = runs.some((run) => ["failure", "cancelled"].includes(run.conclusion ?? ""));
  return <main className="detail-page"><div className="detail-topbar"><a className="back-link" href="/">← 返回构建列表</a><button className="ghost-button" onClick={() => void refresh()}>刷新详情</button></div><section className="panel detail-hero"><div><p className="eyebrow">Build request · {build.request_id.slice(0, 8)}</p><h1>{resolved.releaseVersion ?? spec.version}</h1><p className="muted">{spec.kind === "formal" ? "Formal" : "Development"} · {spec.platform === "all" ? "全部平台" : spec.platform} · 创建于 {date(build.created_at)}</p></div><span className={`status status-large status-${build.phase}`}>{labels[build.phase] ?? build.phase}</span></section>{message && <p className="form-error detail-message" role="alert">{message}</p>}<div className="detail-grid"><section className="panel"><div className="panel-heading"><h2>不可变预览</h2><span className="muted">操作者：{build.requested_by_username ?? "管理员"}</span></div><div className="detail-facts"><div><span>版本 / time patch</span><strong>{resolved.releaseVersion ?? "—"} / {resolved.timePatch ?? "—"}</strong></div><div><span>Delivery Profile</span><strong>{resolved.deliveryProfile ?? spec.deliveryProfile}</strong></div><div><span>同步范围</span><strong>{resolved.syncScope ?? "—"}</strong></div><div><span>Release</span><strong>{resolved.githubVisibility ?? (spec.publish ? "published" : "draft")}</strong></div></div><h3>请求参数</h3><dl className="key-values">{Object.entries(spec).map(([key, value]) => <div key={key}><dt>{key}</dt><dd>{jsonValue(value)}</dd></div>)}</dl><h3>远端 ref 快照</h3>{snapshot.length ? <div className="snapshot-list">{snapshot.map((item) => <div className="snapshot-row" key={`${item.repository}:${item.provider}:${item.ref}`}><strong>{item.repository}</strong><code>{item.ref}</code><span>{item.sha.slice(0, 12)} · {item.provider} · {item.sync_status}</span><small>{date(item.captured_at)}</small></div>)}</div> : <p className="muted">该预览没有可用的 ref 快照。</p>}</section><section className="panel"><div className="panel-heading"><h2>平台运行</h2><span className="muted">更新于 {date(build.updated_at)}</span></div>{runs.length ? <div className="run-list">{runs.map((run) => <div className="run-card" key={run.platform}><div><strong>{run.platform}</strong><span>{run.workflow}</span></div><span className={`run-state ${run.conclusion ?? run.status}`}>{run.conclusion ?? run.status}</span>{run.run_url && <a href={run.run_url} target="_blank" rel="noreferrer">打开 GitHub Actions →</a>}{run.failed_jobs?.length ? <ul>{run.failed_jobs.map((job) => <li key={job}>{job}</li>)}</ul> : null}</div>)}</div> : <p className="muted">Worker 尚未创建平台运行记录。</p>}<div className="action-bar">{build.phase === "awaiting_confirmation" && <button disabled={pending} onClick={() => setConfirming(true)}>确认构建</button>}{["preview_queued", "previewing", "awaiting_confirmation", "queued"].includes(build.phase) && <button className="secondary" disabled={pending} onClick={() => void action("cancel")}>取消构建</button>}{build.phase === "failed" && retryable && <button className="secondary" disabled={pending} onClick={() => void action("retry")}>重试失败平台</button>}</div></section></div><section className="panel timeline-panel"><div className="panel-heading"><h2>事件时间线</h2><span className="muted">{events.length} 条事件</span></div>{events.length ? <ol className="timeline">{events.map((item) => <li key={item.id}><span className={`timeline-dot ${item.level}`} /><div><strong>{item.event}</strong><time>{date(item.created_at)}</time>{Object.keys(item.data ?? {}).length > 0 && <code>{JSON.stringify(item.data)}</code>}</div></li>)}</ol> : <p className="muted">暂无事件。</p>}</section>{confirming && <div className="modal-backdrop" role="presentation"><div className="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="confirm-title"><h2 id="confirm-title">确认构建</h2><p>确认后 Worker 将执行源码同步并触发选定平台的工作流。</p>{spec.publish && <label>输入确认短语 <strong>FORMAL {resolved.releaseVersion}</strong><input value={phrase} onChange={(event) => setPhrase(event.target.value)} autoFocus /></label>}<div className="action-bar"><button disabled={pending || (Boolean(spec.publish) && !phrase)} onClick={() => void action("confirm")}>{pending ? "确认中…" : "确认并排队"}</button><button className="secondary" disabled={pending} onClick={() => setConfirming(false)}>返回检查</button></div></div></div>}</main>;
}
