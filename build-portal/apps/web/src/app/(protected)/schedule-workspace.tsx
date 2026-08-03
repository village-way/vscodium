"use client";

import { FormEvent, useEffect, useState } from "react";
import { apiJson, writeHeaders } from "../lib/api-client";
import { useAuth } from "./auth-context";

type Schedule = { id: string; name: string; cron: string; timezone: string; enabled: boolean; spec: { version: string; platform: string; outputMode: string }; revision: number; next_run_at?: string | null };
type Draft = { name: string; cron: string; version: string; platform: string; outputMode: string; enabled: boolean };
const emptyDraft: Draft = { name: "", cron: "5 1 * * *", version: "", platform: "linux", outputMode: "workflow-artifact", enabled: true };
const date = (value?: string | null) => value ? new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium", timeStyle: "short", timeZone: "Asia/Tokyo" }).format(new Date(value)) : "未安排";

function specFor(draft: Draft) { return { kind: "development", version: draft.version, platform: draft.platform, sourceBranch: "develop", deliveryProfile: "default", zhanluCoreRef: "develop", zhanluVsRef: "develop", bundleCodexRuntime: false, outputMode: draft.outputMode, triggerOnly: false, syncGitLab: false, publish: false }; }

export function ScheduleWorkspace() {
  const { csrfToken } = useAuth();
  const [items, setItems] = useState<Schedule[]>([]);
  const [draft, setDraft] = useState<Draft>(emptyDraft);
  const [editing, setEditing] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState("");
  const [confirmAction, setConfirmAction] = useState<{ type: "run" | "archive"; schedule: Schedule } | null>(null);

  async function refresh() { try { const data = await apiJson<{ schedules: Schedule[] }>("/api/schedules"); setItems(data.schedules); } catch (error) { setMessage(error instanceof Error ? error.message : "定时任务加载失败"); } }
  useEffect(() => { void refresh(); }, []);

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setPending(true); setMessage("");
    try { const url = editing ? `/api/schedules/${editing}` : "/api/schedules"; const method = editing ? "PATCH" : "POST"; await apiJson(url, { method, headers: writeHeaders(csrfToken), body: JSON.stringify({ name: draft.name, cron: draft.cron, timezone: "Asia/Tokyo", enabled: draft.enabled, spec: specFor(draft) }) }); setMessage(editing ? "规则已更新" : "规则已创建"); setDraft(emptyDraft); setEditing(null); await refresh(); }
    catch (error) { setMessage(error instanceof Error ? error.message : "保存失败，请检查输入"); }
    finally { setPending(false); }
  }

  async function mutateSchedule(schedule: Schedule, type: "run" | "archive") {
    setPending(true); setMessage("");
    try { if (type === "run") await apiJson(`/api/schedules/${schedule.id}/run-now`, { method: "POST", headers: writeHeaders(csrfToken), body: "{}" }); else await apiJson(`/api/schedules/${schedule.id}`, { method: "DELETE", headers: writeHeaders(csrfToken), body: "{}" }); setMessage(type === "run" ? "已创建一次性构建任务" : "规则已归档"); setConfirmAction(null); await refresh(); }
    catch (error) { setMessage(error instanceof Error ? error.message : "操作失败，请重试"); }
    finally { setPending(false); }
  }

  async function toggle(schedule: Schedule) {
    setPending(true); setMessage("");
    try { await apiJson(`/api/schedules/${schedule.id}`, { method: "PATCH", headers: writeHeaders(csrfToken), body: JSON.stringify({ enabled: !schedule.enabled }) }); await refresh(); }
    catch (error) { setMessage(error instanceof Error ? error.message : "更新失败，请重试"); }
    finally { setPending(false); }
  }

  function edit(schedule: Schedule) { setEditing(schedule.id); setDraft({ name: schedule.name, cron: schedule.cron, version: schedule.spec.version, platform: schedule.spec.platform, outputMode: schedule.spec.outputMode, enabled: schedule.enabled }); window.scrollTo({ top: 0, behavior: "smooth" }); }

  return <main className="schedule-page"><section className="page-heading"><div><p className="eyebrow">Asia/Tokyo scheduler</p><h1>Development 定时任务</h1><p className="muted">定时任务只允许创建 Development draft；归档会保留 revision 和 occurrence 审计记录。</p></div><a className="outline-button" href="/">返回构建</a></section><section className="panel schedule-form-panel"><div className="panel-heading"><div><h2>{editing ? "编辑规则" : "创建规则"}</h2><p className="muted">当前时区固定为 Asia/Tokyo。</p></div>{editing && <button className="ghost-button" type="button" onClick={() => { setEditing(null); setDraft(emptyDraft); }}>取消编辑</button>}</div><form onSubmit={save}><div className="fields"><label>名称<input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} required placeholder="每日 Development" /></label><label>Cron<input value={draft.cron} onChange={(event) => setDraft({ ...draft, cron: event.target.value })} required placeholder="5 1 * * *" /></label><label>版本<input value={draft.version} onChange={(event) => setDraft({ ...draft, version: event.target.value })} required placeholder="1.4.1" /></label><label>平台<select value={draft.platform} onChange={(event) => setDraft({ ...draft, platform: event.target.value })}><option value="linux">Linux</option><option value="all">全部平台</option><option value="macos">macOS</option><option value="windows">Windows</option></select></label><label>输出<select value={draft.outputMode} onChange={(event) => setDraft({ ...draft, outputMode: event.target.value })}><option value="workflow-artifact">Workflow artifact</option><option value="release">Draft release</option></select></label></div><div className="form-footer"><p className="form-message" role="status">{message}</p><button type="submit" disabled={pending}>{pending ? "保存中…" : editing ? "保存修改" : "创建规则"}</button></div></form></section><section className="panel schedule-list-panel"><div className="panel-heading"><div><h2>已启用规则</h2><p className="muted">Scheduler 每 30 秒扫描一次，Occurrence 使用唯一约束去重。</p></div><span className="count-pill">{items.length}</span></div>{items.length ? <div className="schedule-list">{items.map((schedule) => <article className={`schedule-row ${schedule.enabled ? "" : "is-disabled"}`} key={schedule.id}><div className="schedule-summary"><div className="schedule-title"><strong>{schedule.name}</strong><span className={schedule.enabled ? "enabled-badge" : "disabled-badge"}>{schedule.enabled ? "运行中" : "已停用"}</span></div><div className="schedule-meta"><code>{schedule.cron}</code><span>{schedule.spec.version} · {schedule.spec.platform === "all" ? "全部平台" : schedule.spec.platform}</span><span>下次：{schedule.enabled ? date(schedule.next_run_at) : "已停用"}</span></div></div><div className="schedule-actions"><button className="ghost-button" disabled={pending} onClick={() => void toggle(schedule)}>{schedule.enabled ? "停用" : "启用"}</button><button className="ghost-button" disabled={pending} onClick={() => edit(schedule)}>编辑</button><button className="secondary" disabled={pending || !schedule.enabled} onClick={() => setConfirmAction({ type: "run", schedule })}>立即运行</button><button className="danger-button" disabled={pending} onClick={() => setConfirmAction({ type: "archive", schedule })}>归档</button></div></article>)}</div> : <div className="empty-state">还没有定时规则。</div>}</section>{confirmAction && <div className="modal-backdrop" role="presentation"><div className="confirm-dialog" role="dialog" aria-modal="true" aria-labelledby="schedule-confirm-title"><h2 id="schedule-confirm-title">{confirmAction.type === "run" ? "立即运行规则？" : "归档这条规则？"}</h2><p>{confirmAction.type === "run" ? `将为「${confirmAction.schedule.name}」创建一次 Development 构建，不会修改原规则。` : `归档「${confirmAction.schedule.name}」后不会再触发新的 occurrence，但历史记录会保留。`}</p><div className="action-bar"><button disabled={pending} onClick={() => void mutateSchedule(confirmAction.schedule, confirmAction.type)}>{pending ? "处理中…" : confirmAction.type === "run" ? "确认运行" : "确认归档"}</button><button className="secondary" disabled={pending} onClick={() => setConfirmAction(null)}>返回</button></div></div></div>}</main>;
}
