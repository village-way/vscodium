import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { gitlabCliHost, prepareGitlabCliEnvironment } from "./gitlab-cli.js";

test("hostname-only GitLab settings keep the HTTP API used by the portal", () => {
  assert.deepEqual(gitlabCliHost({ GITLAB_HOST: "gitlab.cmss.com", GITLAB_API_HOST: "gitlab.cmss.com", GITLAB_API_PROTOCOL: "http" }), {
    url: "http://gitlab.cmss.com",
    hostname: "gitlab.cmss.com",
  });
});

test("an explicit GitLab URL is preserved", () => {
  assert.deepEqual(gitlabCliHost({ GITLAB_HOST: "http://gitlab.cmss.com/" }), {
    url: "http://gitlab.cmss.com",
    hostname: "gitlab.cmss.com",
  });
});

test("prepareGitlabCliEnvironment writes a 600 HTTP glab config", async () => {
  const root = await mkdtemp(`${tmpdir()}/zhanlu-glab-`);
  const env: Record<string, string | undefined> = {
    GITLAB_TOKEN: "never-print-this-token",
    GITLAB_HOST: "gitlab.cmss.com",
    GITLAB_API_HOST: "gitlab.cmss.com",
    GITLAB_API_PROTOCOL: "http",
    XDG_CONFIG_HOME: path.join(root, "config"),
    XDG_CACHE_HOME: path.join(root, "cache"),
  };
  try {
    await prepareGitlabCliEnvironment(env);
    assert.equal(env.GITLAB_HOST, "http://gitlab.cmss.com");
    const configPath = path.join(root, "config", "glab-cli", "config.yml");
    const contents = await readFile(configPath, "utf8");
    assert.match(contents, /api_protocol: http/);
    assert.match(contents, /api_host: gitlab\.cmss\.com/);
    assert.equal((await stat(configPath)).mode & 0o777, 0o600);
    assert.equal(env.XDG_CONFIG_HOME, path.join(root, "config"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
