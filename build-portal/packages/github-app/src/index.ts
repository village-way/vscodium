import { createServer, type Server } from "node:net";
import { readFile, chmod, unlink } from "node:fs/promises";
import { createAppAuth } from "@octokit/auth-app";
import { Octokit } from "@octokit/rest";

type CachedToken = { token: string; expiresAt: number };
let cached: CachedToken | undefined;

async function privateKey(): Promise<string> {
  const path = process.env.GITHUB_APP_PRIVATE_KEY_FILE;
  if (!path) throw new Error("GITHUB_APP_PRIVATE_KEY_FILE is required");
  return readFile(path, "utf8");
}

export async function installationToken(): Promise<string> {
  if (cached && cached.expiresAt - Date.now() > 5 * 60_000) return cached.token;
  const appId = process.env.GITHUB_APP_ID;
  const installationId = process.env.GITHUB_APP_INSTALLATION_ID;
  if (!appId || !installationId) throw new Error("GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID are required");
  const auth = createAppAuth({ appId, privateKey: await privateKey(), installationId });
  const result = await auth({ type: "installation" });
  cached = { token: result.token, expiresAt: new Date(result.expiresAt).getTime() };
  return cached.token;
}

export async function github(): Promise<Octokit> { return new Octokit({ auth: await installationToken() }); }

export async function gitCredentialToken(): Promise<string> {
  return process.env.GITHUB_GIT_TOKEN || installationToken();
}

export async function assertRepositoryAccess(repositories: string[]): Promise<void> {
  const client = await github();
  const installed = await client.paginate(client.apps.listReposAccessibleToInstallation, { per_page: 100 });
  const names = new Set(installed.map((repo) => repo.full_name));
  const missing = repositories.filter((repo) => !names.has(repo));
  if (missing.length) throw new Error(`GitHub App is not installed for: ${missing.join(", ")}`);
}

export async function startCredentialBroker(socketPath = process.env.GITHUB_CREDENTIAL_SOCKET ?? "/run/zhanlu-credentials/github.sock"): Promise<Server> {
  await unlink(socketPath).catch((error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; });
  const server = createServer(async (socket) => {
    try { socket.end(`${await gitCredentialToken()}\n`); }
    catch { socket.end(); }
  });
  await new Promise<void>((resolve, reject) => server.listen(socketPath, resolve).once("error", reject));
  await chmod(socketPath, 0o600);
  return server;
}
