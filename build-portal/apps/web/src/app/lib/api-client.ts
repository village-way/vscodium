export class ApiError extends Error {
  constructor(message: string, readonly status: number, readonly data: unknown = {}) { super(message); }
}

function loginUrl(): string {
  const next = `${location.pathname}${location.search}`;
  return `/login?reason=expired&next=${encodeURIComponent(next || "/")}`;
}

export async function apiJson<T>(url: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(url, { ...init, headers: { accept: "application/json", ...(init.headers ?? {}) } });
  const data = await response.json().catch(() => ({}));
  if (response.status === 401) { location.href = loginUrl(); throw new ApiError("登录状态已过期", 401, data); }
  if (!response.ok) throw new ApiError(typeof data?.error === "string" ? data.error : "请求失败，请稍后重试", response.status, data);
  return data as T;
}

export function writeHeaders(csrfToken: string): HeadersInit {
  return { "content-type": "application/json", "x-csrf-token": csrfToken, origin: location.origin };
}
