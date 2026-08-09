import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);

export const DEFAULT_RELEASE_GIT_USER_NAME = "village-way";
export const DEFAULT_RELEASE_GIT_USER_EMAIL = "wandepen@163.com";

export type ReleaseGitIdentity = { name: string; email: string };

type StringEnvironment = Readonly<Record<string, string | undefined>>;

export function releaseGitIdentity(env: StringEnvironment = process.env): ReleaseGitIdentity {
  const name = env.RELEASE_GIT_USER_NAME ?? DEFAULT_RELEASE_GIT_USER_NAME;
  const email = env.RELEASE_GIT_USER_EMAIL ?? DEFAULT_RELEASE_GIT_USER_EMAIL;
  if (!name.trim() || !email.trim()) throw new Error("RELEASE_GIT_USER_NAME and RELEASE_GIT_USER_EMAIL are required");
  return { name, email };
}

export async function configureReleaseGitIdentity(path: string, env: StringEnvironment = process.env): Promise<ReleaseGitIdentity> {
  const identity = releaseGitIdentity(env);
  const commandEnv = { ...process.env, ...env };
  await exec("git", ["-C", path, "config", "--local", "user.name", identity.name], { env: commandEnv });
  await exec("git", ["-C", path, "config", "--local", "user.email", identity.email], { env: commandEnv });
  const author = await exec("git", ["-C", path, "var", "GIT_AUTHOR_IDENT"], { env: commandEnv });
  if (!author.stdout.includes(`${identity.name} <${identity.email}>`)) {
    throw new Error(`release checkout Git identity mismatch: expected ${identity.name} <${identity.email}>`);
  }
  return identity;
}
