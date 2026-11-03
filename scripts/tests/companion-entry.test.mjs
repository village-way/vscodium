import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const read = (name) => readFileSync(new URL(`../../${name}`, import.meta.url), 'utf8');

test('new entries register through credential-free validation and gate execution on manual dispatch', () => {
  for (const name of ['build-release', 'build-companion']) {
    const workflow = read(`.github/workflows/${name}.yml`);
    assert.match(workflow, /pull_request:/);
    assert.doesNotMatch(workflow, /pull_request_target:/);
    assert.match(workflow, /if: github.event_name == 'workflow_dispatch'/);
    const validation = workflow.split('  validate:\n')[1].split(/\n  (?:plan|dispatch):/)[0];
    assert.doesNotMatch(validation, /secrets\.|contents: write|id-token:/);
  }
  const parent = read('.github/workflows/build-release.yml');
  assert.match(parent, /publish_npm: \{type: boolean, default: false/);
  assert.match(parent, /companion_ref:/);
  assert.match(parent, /source_ref:/);
  assert.match(parent, /scripts\/release-entry\.py/);
});

test('native matrix includes both Linux CPUs and separate real Windows ARM64 execution', () => {
  const workflow = read('.github/workflows/build-companion.yml');
  for (const label of ['macos-15', 'windows-2025', 'windows-11-arm', 'ubuntu-22.04', 'ubuntu-24.04-arm', 'python:3.11-bullseye']) {
    assert.ok(workflow.includes(label), `missing ${label}`);
  }
  assert.match(workflow, /needs: \[plan, native, linux, windows-arm-smoke\]/);
  assert.match(workflow, /needs\.windows-arm-smoke\.result == 'success'/);
  assert.match(workflow, /--distribution/);
  assert.doesNotMatch(workflow, /npm publish|publish-package\.yml|--allow-unsigned/);
  assert.match(workflow, /https:\/\/archive\.debian\.org\//);
  assert.doesNotMatch(workflow, /--allow-unauthenticated|trusted=yes|Check-Valid-Until.*false|Verify-Peer.*false/i);
  assert.match(workflow, /name: companion-delivery-\$\{\{ github.run_id \}\}/);
});

test('source credentials are separate and stable compile source never enters public artifacts', () => {
  const inputs = read('.build-entry/checkout-build-inputs/action.yml');
  assert.match(inputs, /permission-contents: read/);
  assert.match(inputs, /deploy-key: \$\{\{ inputs.companion-key \}\}/);
  assert.match(read('.build-entry/checkout-source/action.yml'), /persist-credentials: false/);
  for (const platform of ['windows', 'linux']) {
    const workflow = read(`.github/workflows/stable-${platform}.yml`);
    assert.doesNotMatch(workflow, /\n          name: vscode\s*\n/);
    assert.match(workflow, /SOURCE_STORAGE_REPOSITORY:/);
    assert.match(workflow, /private-source-artifact\.mjs upload/);
    assert.match(workflow, /private-source-artifact\.mjs download/);
  }
});

test('source visibility uses scoped authentication and never accepts an inconclusive or public response', t => {
  const directory = mkdtempSync(path.join(os.tmpdir(), 'source-visibility-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const bin = path.join(directory, 'bin');
  mkdirSync(bin);
  writeFileSync(path.join(bin, 'curl'), `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
if (args[args.indexOf('--header') + 1] !== 'Authorization: Bearer fixture-token') process.exit(17);
fs.writeFileSync(args[args.indexOf('--output') + 1], JSON.stringify({private: process.env.FIXTURE_PRIVATE === 'true'}));
process.stdout.write(process.env.FIXTURE_STATUS);
`, {mode: 0o755});
  const script = fileURLToPath(new URL('../../.build-entry/checkout-source/verify-private.sh', import.meta.url));
  const workspace = path.join(directory, 'container workspace');
  const actionDirectory = path.join(workspace, '.build-entry/checkout-source');
  mkdirSync(actionDirectory, {recursive: true});
  writeFileSync(path.join(actionDirectory, 'verify-private.sh'), readFileSync(script));
  const run = read('.build-entry/checkout-source/action.yml').match(/^      run: (.+)$/m)[1]
    .replaceAll('${{ github.action_path }}', '/host-only/action');
  for (const [status, privateRepository, deployKey, accepted] of [
    ['200', 'true', 'false', true], ['200', 'false', 'true', false],
    ['403', 'false', 'true', false], ['404', 'false', 'false', false], ['404', 'false', 'true', true],
  ]) {
    const result = spawnSync('bash', ['-c', run], {encoding: 'utf8', env: {...process.env,
      GITHUB_WORKSPACE: workspace, GITHUB_ACTION_PATH: '/host-only/action',
      PATH: `${bin}${path.delimiter}${process.env.PATH}`, SELECTED_REPOSITORY: 'example/private',
      VISIBILITY_TOKEN: 'fixture-token', HAS_DEPLOY_KEY: deployKey, FIXTURE_STATUS: status, FIXTURE_PRIVATE: privateRepository,
    }});
    assert.equal(result.status === 0, accepted, result.stderr);
    assert.doesNotMatch(result.stdout + result.stderr, /fixture-token/);
  }
});
