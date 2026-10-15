import { appendFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

export async function findPackageArtifact(env, request = fetch) {
  const name = `package-publication-${env.GITHUB_RUN_ID}`;
  const response = await request(`${env.GITHUB_API_URL}/repos/${env.GITHUB_REPOSITORY}/actions/runs/${env.GITHUB_RUN_ID}/artifacts?per_page=100`, {
    headers: { Authorization: `Bearer ${env.GITHUB_TOKEN}`, Accept: 'application/vnd.github+json' },
  });
  if (!response.ok) throw new Error(`Artifact lookup failed (${response.status})`);
  const { artifacts } = await response.json();
  const matches = artifacts.filter(artifact => artifact.name === name);
  if (matches.length > 1 || matches.some(artifact => artifact.expired)) throw new Error('Publication artifact unavailable');
  return matches[0]?.id ?? '';
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const id = await findPackageArtifact(process.env);
  await appendFile(process.env.GITHUB_OUTPUT, `artifact-id=${id}\n`);
}
