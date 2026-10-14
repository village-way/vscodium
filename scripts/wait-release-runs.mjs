// Verify a pinned release batch before allowing its package publication.
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const workflows = new Set(['stable-macos.yml', 'stable-linux.yml', 'stable-windows.yml']);
export function validateBatch(context) {
  if (!/^[0-9a-f]{40}$/.test(context.sourceCommit) || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(context.requestId)) throw new Error('Invalid release identity');
  if (!/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(context.version) || !['formal', 'development'].includes(context.kind)) throw new Error('Invalid release version or kind');
  if (!Array.isArray(context.runs) || !context.runs.length || context.runs.length > 3) throw new Error('Missing selected platform runs');
  if (new Set(context.runs.map(run => run.workflow)).size !== context.runs.length || new Set(context.runs.map(run => run.runId)).size !== context.runs.length) throw new Error('Duplicate platform runs');
  for (const run of context.runs) if (!workflows.has(run.workflow) || !Number.isSafeInteger(run.runId) || run.runId <= 0) throw new Error('Invalid platform run');
}

export function batchStatus(context, details) {
  for (let index = 0; index < context.runs.length; index++) {
    const expected = context.runs[index];
    const run = details[index];
    const title = `${expected.workflow.replace('.yml', '')} · ${context.version} · ${context.requestId}`;
    if (run.id !== expected.runId || run.repository?.full_name !== context.repository || run.path !== `.github/workflows/${expected.workflow}` || run.event !== 'workflow_dispatch' || run.head_sha !== context.workflowCommit || run.display_title !== title) throw new Error('Platform run does not belong to this release batch');
    if (run.status === 'completed' && run.conclusion !== 'success') throw new Error(`Platform publication failed: ${expected.workflow} (${run.conclusion})`);
  }
  return details.every(run => run.status === 'completed');
}

export function verifyMetadata(context, metadata) {
  if (metadata.releaseVersion !== context.version || metadata.sourceCommit !== context.sourceCommit || metadata.deliveryProfile !== 'default' || metadata.assetsRepository !== context.repository) throw new Error('Release metadata does not match the pinned package source');
}

export async function waitForRelease(context, api, { sleep = ms => new Promise(resolve => setTimeout(resolve, ms)), now = Date.now, timeout = 340 * 60_000 } = {}) {
  validateBatch(context);
  const deadline = now() + timeout;
  while (true) {
    const details = await Promise.all(context.runs.map(run => api(`/actions/runs/${run.runId}`)));
    if (batchStatus(context, details)) break;
    if (now() >= deadline) throw new Error('Timed out waiting for all selected platforms');
    await sleep(60_000);
  }
  const release = await api(`/releases/tags/${encodeURIComponent(context.version)}`);
  const asset = release.assets?.find(asset => asset.name === context.metadataAsset);
  if (!asset) throw new Error('Release delivery metadata is missing');
  verifyMetadata(context, await api(`/releases/assets/${asset.id}`, true));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const env = process.env;
  const context = { sourceCommit: env.SOURCE_COMMIT, requestId: env.REQUEST_ID, version: env.RELEASE_VERSION, kind: env.RELEASE_KIND, runs: JSON.parse(env.PLATFORM_RUNS || 'null'), repository: env.GITHUB_REPOSITORY, workflowCommit: env.GITHUB_SHA, metadataAsset: env.RELEASE_METADATA_ASSET };
  if (!context.metadataAsset) throw new Error('Configure RELEASE_METADATA_ASSET before publishing packages');
  const api = async (route, asset = false) => {
    const response = await fetch(`https://api.github.com/repos/${context.repository}${route}`, { headers: { Authorization: `Bearer ${env.GITHUB_TOKEN}`, Accept: asset ? 'application/octet-stream' : 'application/vnd.github+json', 'X-GitHub-Api-Version': '2026-03-10' }, signal: AbortSignal.timeout(30_000) });
    if (!response.ok) throw new Error(`GitHub release lookup failed (${response.status})`);
    return response.json();
  };
  await waitForRelease(context, api);
  if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, `All selected platform runs succeeded for ${context.version}.\n\n` + context.runs.map(run => `- [${run.workflow}](https://github.com/${context.repository}/actions/runs/${run.runId})`).join('\n') + '\n');
}
