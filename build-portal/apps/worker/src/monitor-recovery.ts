export type MonitorTask = () => Promise<void>;
export type MonitorFailureHandler = (error: unknown) => Promise<void>;

const wait = (milliseconds: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, milliseconds));

export function isAuthFailure(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const value = error as { status?: number; response?: { status?: number }; message?: string };
  return value.status === 401 || value.response?.status === 401 || /(?:401|bad credentials)/i.test(value.message ?? "");
}

export async function runMonitorWithRecovery(task: MonitorTask, onRetry?: (error: unknown) => Promise<void>, retryDelayMs = 1_000): Promise<void> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      await task();
      return;
    } catch (error) {
      lastError = error;
      if (attempt === 0) {
        await onRetry?.(error);
        await wait(retryDelayMs);
      }
    }
  }
  throw lastError instanceof Error ? lastError : new Error("monitor failed");
}

export class MonitorCoordinator {
  private readonly active = new Set<string>();

  start(buildId: string, task: MonitorTask, onFailure: MonitorFailureHandler): boolean {
    if (this.active.has(buildId)) return false;
    this.active.add(buildId);
    void (async () => {
      try {
        await task();
      } catch (error) {
        try {
          await onFailure(error);
        } catch (failure) {
          console.error(`monitor failure handler failed for ${buildId}`, failure instanceof Error ? failure.message : "unknown");
        }
      } finally {
        this.active.delete(buildId);
      }
    })();
    return true;
  }

  isActive(buildId: string): boolean {
    return this.active.has(buildId);
  }
}
