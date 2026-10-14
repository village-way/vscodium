import assert from 'node:assert/strict';
import test from 'node:test';
import { batchStatus, validateBatch, verifyMetadata, waitForRelease } from '../wait-release-runs.mjs';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const context = { repository: 'example/build', sourceCommit: 'a'.repeat(40), workflowCommit: 'b'.repeat(40), version: '1.6.4', kind: 'formal', requestId: 'request-1', metadataAsset: 'delivery.json', runs: ['macos', 'linux', 'windows'].map((platform, index) => ({ workflow: `stable-${platform}.yml`, runId: index + 1 })) };
const detail = (run, status = 'completed', conclusion = 'success') => ({ id: run.runId, repository: { full_name: context.repository }, path: `.github/workflows/${run.workflow}`, event: 'workflow_dispatch', head_sha: context.workflowCommit, display_title: `${run.workflow.replace('.yml', '')} · ${context.version} · ${context.requestId}`, status, conclusion });
const metadata = { releaseVersion: context.version, sourceCommit: context.sourceCommit, deliveryProfile: 'default', assetsRepository: context.repository };

test('waits for every selected platform and then validates the fixed release source', async () => {
  let completed = false;
  let metadataRead = false;
  await waitForRelease(context, async route => {
    if (route.startsWith('/actions/runs/')) return detail(context.runs.find(run => route.endsWith(`/${run.runId}`)), completed ? 'completed' : 'in_progress');
    assert.equal(completed, true);
    if (route.startsWith('/releases/tags/')) return { assets: [{ name: 'delivery.json', id: 9 }] };
    metadataRead = true;
    return metadata;
  }, { sleep: async () => { completed = true; } });
  assert.equal(metadataRead, true);
  const single = { ...context, runs: context.runs.slice(0, 1) };
  assert.doesNotThrow(() => validateBatch(single));
  assert.equal(batchStatus(single, [detail(single.runs[0])]), true);
});

test('failed, cancelled and timed-out platforms block package publication', () => {
  for (const conclusion of ['failure', 'cancelled', 'timed_out', 'skipped']) {
    assert.throws(() => batchStatus(context, context.runs.map(run => detail(run, 'completed', conclusion))), /Platform publication failed/);
  }
});

test('rejects an unrelated run, duplicate platforms, source mismatch and customer profile', () => {
  assert.throws(() => batchStatus(context, context.runs.map(run => ({ ...detail(run), head_sha: 'c'.repeat(40) }))), /does not belong/);
  assert.throws(() => validateBatch({ ...context, runs: [context.runs[0], context.runs[0]] }), /Duplicate/);
  for (const changed of [{ sourceCommit: 'c'.repeat(40) }, { deliveryProfile: 'customer' }, { releaseVersion: '1.6.5' }]) assert.throws(() => verifyMetadata(context, { ...metadata, ...changed }), /does not match/);
});

test('a stalled platform times out without reading or publishing the release', async () => {
  await assert.rejects(waitForRelease(context, async route => detail(context.runs.find(run => route.endsWith(`/${run.runId}`)), 'in_progress'), { now: () => 0, timeout: 0 }), /Timed out/);
});

test('release entry dispatches the selected batch and SDK with the same source and explicit channel', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'package-dispatch-'));
  try {
    fs.mkdirSync(path.join(root, 'scripts'));
    fs.mkdirSync(path.join(root, 'bin'));
    const trigger = new URL('../trigger-stable-release.sh', import.meta.url);
    fs.copyFileSync(trigger, path.join(root, 'scripts/trigger-stable-release.sh'));
    fs.writeFileSync(path.join(root, 'scripts/resolve-release-delivery-profile.sh'), `resolve_release_delivery_profile() { export ZHANLU_DELIVERY_SOURCE_COMMIT=${'a'.repeat(40)} ZHANLU_DELIVERY_PROFILE_DIGEST=${'d'.repeat(64)} ZHANLU_DELIVERY_ASSETS_REPOSITORY=example/build; }\nprepare_release_delivery_profile() { resolve_release_delivery_profile; }\n`);
    fs.writeFileSync(path.join(root, 'create-release.sh'), '#!/usr/bin/env bash\nexit 0\n', { mode: 0o755 });
    fs.writeFileSync(path.join(root, 'bin/gh'), `#!/usr/bin/env bash
case "$*" in
  'auth status') exit 0 ;;
  'repo view --json nameWithOwner -q .nameWithOwner') echo example/build ;;
  release\\ download*) exit 1 ;;
  release\\ view*) echo true ;;
  api\\ *dispatches*)
    payload="$(cat)"
    printf '%s\\n' "$payload" >> "$MOCK_DISPATCH_LOG"
    case "$*" in
      *stable-macos.yml*) n=1 ;;
      *stable-linux.yml*) n=2 ;;
      *stable-windows.yml*) n=3 ;;
      *publish-package.yml*) n=4 ;;
    esac
    printf '{"workflow_run_id":%s,"html_url":"https://example.test/%s"}\\n' "$n" "$n" ;;
  *) echo 'unexpected fixture command' >&2; exit 99 ;;
esac
`, { mode: 0o755 });
    const log = path.join(root, 'dispatch.jsonl');
    const run = (args) => {
      fs.writeFileSync(log, '');
      const result = spawnSync('bash', ['./scripts/trigger-stable-release.sh', '--workflow-ref', 'develop', '--release-version', '1.6.4', '--request-id', 'request-1', '--output', 'json', ...args], { cwd: root, encoding: 'utf8', env: { ...process.env, PATH: `${path.join(root, 'bin')}${path.delimiter}${process.env.PATH}`, MOCK_DISPATCH_LOG: log, SOURCE_REPOSITORY: 'example/source', SOURCE_SUBDIR: 'packaging' } });
      assert.equal(result.status, 0, result.stderr + result.stdout);
      const calls = fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
      const document = result.stdout.split('\n').filter(line => line.startsWith('{')).map(JSON.parse).at(-1);
      return { calls, document };
    };
    const formal = run(['--workflow', '--platform', 'all', '--release-kind', 'formal']);
    assert.equal(formal.calls.length, 4);
    const packageInputs = formal.calls.at(-1).inputs;
    assert.equal(packageInputs.release_kind, 'formal');
    assert.equal(packageInputs.source_commit, 'a'.repeat(40));
    assert.deepEqual(JSON.parse(packageInputs.platform_runs).map(run => run.runId), [1, 2, 3]);
    assert.equal(formal.document.npmRun.runId, 4);
    const single = run(['--workflow', '--platform', 'linux']);
    assert.equal(single.calls.length, 2);
    assert.equal(single.calls.at(-1).inputs.release_kind, 'development');
    for (const args of [['--workflow', '--platform', 'linux', '--generate'], ['--workflow', '--platform', 'linux', '--delivery-profile', 'customer']]) {
      const skipped = run(args);
      assert.equal(skipped.calls.length, 1);
      assert.equal(skipped.document.npmRun, undefined);
    }
    const all = run(['--dispatch', '--platform', 'linux', '--bundle-codex-runtime', '1']);
    assert.equal(all.calls.length, 4);
    assert.ok(all.calls.slice(0, 3).every(call => call.inputs.bundle_codex_runtime === '1'));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
