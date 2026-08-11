import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { gitCredentialToken, installationToken } from "./index.js";

test("installation token broker fails closed without app configuration", async () => {
  const saved = { app: process.env.GITHUB_APP_ID, installation: process.env.GITHUB_APP_INSTALLATION_ID };
  delete process.env.GITHUB_APP_ID;
  delete process.env.GITHUB_APP_INSTALLATION_ID;
  await assert.rejects(() => installationToken(), /GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID are required/);
  if (saved.app) process.env.GITHUB_APP_ID = saved.app;
  if (saved.installation) process.env.GITHUB_APP_INSTALLATION_ID = saved.installation;
});

test("git credential token always uses the workflow-capable token", async () => {
  const saved = process.env.GITHUB_GIT_TOKEN;
  const savedApp = process.env.GITHUB_APP_ID;
  const savedInstallation = process.env.GITHUB_APP_INSTALLATION_ID;
  try {
    process.env.GITHUB_APP_ID = "configured-app";
    process.env.GITHUB_APP_INSTALLATION_ID = "configured-installation";
    process.env.GITHUB_GIT_TOKEN = " workflow-capable-token ";
    assert.equal(await gitCredentialToken(), "workflow-capable-token");
  } finally {
    if (savedApp === undefined) delete process.env.GITHUB_APP_ID;
    else process.env.GITHUB_APP_ID = savedApp;
    if (savedInstallation === undefined) delete process.env.GITHUB_APP_INSTALLATION_ID;
    else process.env.GITHUB_APP_INSTALLATION_ID = savedInstallation;
    if (saved === undefined) delete process.env.GITHUB_GIT_TOKEN;
    else process.env.GITHUB_GIT_TOKEN = saved;
  }
});

test("git credential token fails closed when the workflow-capable token is missing", async () => {
  const saved = process.env.GITHUB_GIT_TOKEN;
  try {
    delete process.env.GITHUB_GIT_TOKEN;
    await assert.rejects(() => gitCredentialToken(), /GITHUB_GIT_TOKEN is required/);
  } finally {
    if (saved === undefined) delete process.env.GITHUB_GIT_TOKEN;
    else process.env.GITHUB_GIT_TOKEN = saved;
  }
});

test("deployment passes the workflow-capable token to the worker secret", async () => {
  const deployScript = await readFile(new URL("../../../deploy/scripts/deploy.sh", import.meta.url), "utf8");
  const workerEnvironment = deployScript.match(/cat >"\$tmpdir\/worker\.env" <<EOF\n([\s\S]*?)\nEOF/)?.[1] ?? "";
  assert.match(workerEnvironment, /GITHUB_GIT_TOKEN=\$\(require_secret "\$deployment_env" GITHUB_GIT_TOKEN\)/);
});
