import test from "node:test";
import assert from "node:assert/strict";
import { gitCredentialToken, installationToken } from "./index.js";

test("installation token broker fails closed without app configuration", async () => {
  const saved = { app: process.env.GITHUB_APP_ID, installation: process.env.GITHUB_APP_INSTALLATION_ID };
  delete process.env.GITHUB_APP_ID;
  delete process.env.GITHUB_APP_INSTALLATION_ID;
  await assert.rejects(() => installationToken(), /GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID are required/);
  if (saved.app) process.env.GITHUB_APP_ID = saved.app;
  if (saved.installation) process.env.GITHUB_APP_INSTALLATION_ID = saved.installation;
});

test("git credential token falls back to a workflow-capable token when app auth is unavailable", async () => {
  const saved = process.env.GITHUB_GIT_TOKEN;
  const savedApp = process.env.GITHUB_APP_ID;
  const savedInstallation = process.env.GITHUB_APP_INSTALLATION_ID;
  delete process.env.GITHUB_APP_ID;
  delete process.env.GITHUB_APP_INSTALLATION_ID;
  process.env.GITHUB_GIT_TOKEN = "workflow-capable-token";
  assert.equal(await gitCredentialToken(), "workflow-capable-token");
  if (savedApp) process.env.GITHUB_APP_ID = savedApp;
  if (savedInstallation) process.env.GITHUB_APP_INSTALLATION_ID = savedInstallation;
  if (saved) process.env.GITHUB_GIT_TOKEN = saved;
  else delete process.env.GITHUB_GIT_TOKEN;
});
