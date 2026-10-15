import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { findPackageArtifact } from '../package-artifact.mjs';

const env = { GITHUB_RUN_ID: '42', GITHUB_API_URL: 'https://api.github.com', GITHUB_REPOSITORY: 'owner/repo', GITHUB_TOKEN: 'fixture' };
const reply = artifacts => async url => {
  assert.equal(url, 'https://api.github.com/repos/owner/repo/actions/runs/42/artifacts?per_page=100');
  return { ok: true, json: async () => ({ artifacts }) };
};

test('publication recovery selects only the preserved bundle in this run', async () => {
  assert.equal(await findPackageArtifact(env, reply([])), '');
  assert.equal(await findPackageArtifact(env, reply([{ id: 7, name: 'package-publication-42', expired: false }, { id: 8, name: 'other' }])), 7);
});

test('publication recovery fails closed on expired, duplicate or unreadable artifacts', async () => {
  await assert.rejects(findPackageArtifact(env, reply([{ id: 7, name: 'package-publication-42', expired: true }])));
  await assert.rejects(findPackageArtifact(env, reply([{ id: 7, name: 'package-publication-42' }, { id: 8, name: 'package-publication-42' }])));
  await assert.rejects(findPackageArtifact(env, async () => ({ ok: false, status: 403 })));
});

test('the workflow preserves prepared public packages before the first npm mutation', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/publish-package.yml', import.meta.url), 'utf8');
  const stages = ['Find preserved publication', 'Restore preserved publication', 'Prepare verified publication', 'Preserve verified publication', 'Publish verified package with OIDC'];
  const positions = stages.map(stage => workflow.indexOf(`- name: ${stage}`));
  assert(positions.every((position, index) => position > -1 && (index === 0 || position > positions[index - 1])));
  assert.match(workflow, /PACKAGE_PUBLICATION_PHASE: prepare/);
  assert(workflow.indexOf('- name: Verify publication contract') < positions[2]);
  assert.match(workflow, /run: test "\$PUBLICATION_FORMAT" = 1/);
  assert.match(workflow, /PACKAGE_PUBLICATION_PHASE: publish/);
  assert.match(workflow, /path: package-publication\//);
  assert.match(workflow, /if-no-files-found: error/);
  assert.doesNotMatch(workflow.slice(positions[3], positions[4]), /continue-on-error/);
});
