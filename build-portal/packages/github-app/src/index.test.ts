import test from "node:test";
import assert from "node:assert/strict";
import { installationToken } from "./index.js";

test("installation token broker fails closed without app configuration", async () => {
  const saved = { app: process.env.GITHUB_APP_ID, installation: process.env.GITHUB_APP_INSTALLATION_ID };
  delete process.env.GITHUB_APP_ID;
  delete process.env.GITHUB_APP_INSTALLATION_ID;
  await assert.rejects(() => installationToken(), /GITHUB_APP_ID and GITHUB_APP_INSTALLATION_ID are required/);
  if (saved.app) process.env.GITHUB_APP_ID = saved.app;
  if (saved.installation) process.env.GITHUB_APP_INSTALLATION_ID = saved.installation;
});
