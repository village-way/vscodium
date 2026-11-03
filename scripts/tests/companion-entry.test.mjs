import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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
