import { chmod, mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

type StringEnvironment = Record<string, string | undefined>;

export function gitlabCliHost(env: StringEnvironment): { url: string; hostname: string } {
  const raw = env.GITLAB_HOST?.trim() ?? "";
  const apiHost = env.GITLAB_API_HOST?.trim() ?? "";
  const protocol = env.GITLAB_API_PROTOCOL?.trim() ?? "";
  if (raw.startsWith("http://") || raw.startsWith("https://")) {
    try {
      return { url: raw.replace(/\/$/, ""), hostname: new URL(raw).hostname };
    } catch {
      return { url: raw, hostname: apiHost };
    }
  }
  const hostname = apiHost || raw;
  if (!hostname) return { url: raw, hostname: "" };
  return { url: `${protocol || "https"}://${hostname}`, hostname };
}

export async function prepareGitlabCliEnvironment(env: StringEnvironment = process.env, root = env.XDG_CONFIG_HOME ?? path.join(env.WORKSPACE_ROOT ?? "/tmp", ".zhanlu-cli", "config")): Promise<void> {
  const token = env.GITLAB_TOKEN || env.GITLAB_ACCESS_TOKEN;
  const { url, hostname } = gitlabCliHost(env);
  if (url) env.GITLAB_HOST = url;
  if (!token || !hostname) return;
  const configHome = env.XDG_CONFIG_HOME ?? root;
  const cacheHome = env.XDG_CACHE_HOME ?? path.join(path.dirname(configHome), "cache");
  env.XDG_CONFIG_HOME = configHome;
  env.XDG_CACHE_HOME = cacheHome;
  const configDir = path.join(configHome, "glab-cli");
  await mkdir(configDir, { recursive: true });
  await mkdir(cacheHome, { recursive: true });
  const configPath = path.join(configDir, "config.yml");
  const protocol = url.startsWith("http://") ? "http" : "https";
  await writeFile(configPath, `hosts:\n    ${hostname}:\n        token: ${token}\n        api_host: ${hostname}\n        api_protocol: ${protocol}\n`, { mode: 0o600 });
  await chmod(configPath, 0o600);
}
