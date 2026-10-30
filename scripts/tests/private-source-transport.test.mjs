// Verify private intermediate isolation, complete publication and integrity before restore.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { uploadArtifact, downloadArtifact, validateManifest } from '../../.build-entry/private-source-artifact.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const identity = {
  repository: 'example/private-build', runId: '12345', sourceCommit: 'a'.repeat(40),
  workflowCommit: 'b'.repeat(40), profileDigest: 'c'.repeat(64),
};
const git = (cwd, ...args) => {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
};

test('private store round trips chunks, keeps source refs intact, and supports a consumer-only retry', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'private-transport-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const remote = path.join(directory, 'private.git');
  git(directory, 'init', '--bare', '--quiet', remote);
  const input = path.join(directory, 'ciphertext');
  const bytes = Buffer.from('protected intermediate bytes; no public artifact endpoint\n'.repeat(300));
  fs.writeFileSync(input, bytes);
  const stored = uploadArtifact(input, identity, { remote, chunkBytes: 4096, batchChunks: 2 });
  assert.ok(stored.manifest.chunks.length > 2);
  const restored = path.join(directory, 'restored');
  const fetched = downloadArtifact(restored, identity, { remote });
  assert.equal(fetched.commit, stored.commit);
  assert.deepEqual(fs.readFileSync(restored), bytes);
  assert.equal(git(directory, '--git-dir', remote, 'for-each-ref', '--format=%(refname)'), 'refs/heads/build-artifacts/12345');
  assert.throws(() => downloadArtifact(path.join(directory, 'wrong-run'), { ...identity, runId: '23456' }, { remote }));
  assert.throws(() => downloadArtifact(path.join(directory, 'wrong-source'), { ...identity, sourceCommit: 'd'.repeat(40) }, { remote }));
  assert.throws(() => downloadArtifact(restored, identity, { remote }), /already exists/);
  // A retry republishes by normal fast-forward and cannot replace the manifest's source identity.
  const again = uploadArtifact(input, identity, { remote, chunkBytes: 4096, batchChunks: 2 });
  assert.notEqual(again.commit, stored.commit);
  assert.equal(git(directory, '--git-dir', remote, 'merge-base', stored.commit, again.commit), stored.commit);
});

test('tampered chunks and incomplete uploads never produce a restored file', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'private-corruption-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const remote = path.join(directory, 'private.git');
  git(directory, 'init', '--bare', '--quiet', remote);
  const input = path.join(directory, 'ciphertext');
  fs.writeFileSync(input, 'protected bytes');
  uploadArtifact(input, identity, { remote, chunkBytes: 4, batchChunks: 2 });
  const checkout = path.join(directory, 'edit');
  git(directory, 'clone', '--quiet', '--branch', 'build-artifacts/12345', remote, checkout);
  fs.writeFileSync(path.join(checkout, 'chunk-00000'), 'oops');
  git(checkout, 'add', '--all');
  git(checkout, '-c', 'user.name=test', '-c', 'user.email=test@example.invalid', 'commit', '--quiet', '-m', 'corrupt');
  git(checkout, 'push', '--quiet');
  const output = path.join(directory, 'restored');
  assert.throws(() => downloadArtifact(output, identity, { remote }), /checksum mismatch/);
  assert.equal(fs.existsSync(output), false);
  assert.equal(fs.readdirSync(directory).some(name => name.includes('.private-')), false);
  fs.rmSync(path.join(checkout, 'manifest.json'));
  git(checkout, 'add', '--all');
  git(checkout, '-c', 'user.name=test', '-c', 'user.email=test@example.invalid', 'commit', '--quiet', '-m', 'incomplete');
  git(checkout, 'push', '--quiet');
  assert.throws(() => downloadArtifact(output, identity, { remote }), /completion manifest/);
  assert.equal(fs.existsSync(output), false);
});

test('manifest rejects cross-build identity, traversal, excess chunk size and inconsistent totals', () => {
  const good = { schemaVersion: 1, ...identity, size: 4, sha256: 'e'.repeat(64), chunks: [{ name: 'chunk-00000', size: 4, sha256: 'f'.repeat(64) }] };
  validateManifest(good, identity);
  for (const change of [
    { runId: '999' }, { sourceCommit: 'f'.repeat(40) }, { workflowCommit: 'e'.repeat(40) },
    { profileDigest: 'd'.repeat(64) }, { size: 5 }, { chunks: [] },
    { chunks: [{ ...good.chunks[0], name: '../secret' }] },
    { chunks: [{ ...good.chunks[0], size: 33 * 1024 * 1024 }] },
  ]) assert.throws(() => validateManifest({ ...good, ...change }, identity));
});

test('public repository visibility is refused before loading any private key', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'private-visibility-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const bin = path.join(directory, 'bin'); fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, 'curl'), '#!/bin/sh\nprintf 200\n', { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'ssh-agent'), '#!/bin/sh\nprintf unexpected-agent-start\\n\nexit 99\n', { mode: 0o755 });
  const canary = 'not-a-real-private-key';
  const result = spawnSync('bash', [path.join(root, '.build-entry/private-git.sh').replaceAll('\\', '/'), 'git', 'version'], {
    encoding: 'utf8', env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, PRIVATE_SOURCE_REPOSITORY: identity.repository, PRIVATE_SOURCE_DEPLOY_KEY: canary },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /visibility/);
  assert.equal((result.stdout + result.stderr).includes(canary), false);
  assert.equal((result.stdout + result.stderr).includes('unexpected-agent-start'), false);
});

test('custom SSH clients require explicit OpenSSH port semantics', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'private-ssh-variant-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const remote = path.join(directory, 'remote.git');
  git(directory, 'init', '--bare', '--quiet', remote);
  const client = path.join(directory, 'custom SSH client.sh');
  fs.writeFileSync(client, '#!/bin/sh\ncase " $* " in *" -G "*) exit 1;; esac\nexec git upload-pack "$PRIVATE_TEST_REMOTE"\n', { mode: 0o755 });
  const env = {
    ...process.env, PRIVATE_TEST_REMOTE: remote.replaceAll('\\', '/'),
    GIT_SSH_COMMAND: `"${client.replaceAll('\\', '/')}"`,
  };
  delete env.GIT_SSH_VARIANT;
  const args = ['ls-remote', 'ssh://git@ssh.github.com:443/example/private.git'];
  const automatic = spawnSync('git', args, { cwd: directory, env, encoding: 'utf8' });
  assert.notEqual(automatic.status, 0);
  assert.match(automatic.stderr, /variant 'simple' does not support setting port/);
  const transport = fs.readFileSync(path.join(root, '.build-entry/private-git.sh'), 'utf8');
  const variant = transport.match(/^export GIT_SSH_VARIANT=(\w+)$/m)?.[1];
  const explicit = spawnSync('git', args, { cwd: directory, env: { ...env, GIT_SSH_VARIANT: variant }, encoding: 'utf8' });
  assert.equal(explicit.status, 0, explicit.stderr);
});

test('private store CLI applies repository rewrite per command without modern Git environment config', t => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'private-rewrite-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const remote = path.join(directory, 'remote.git');
  git(directory, 'init', '--bare', '--quiet', remote);
  const client = path.join(directory, 'SSH store server.sh');
  fs.writeFileSync(client, '#!/bin/sh\ncase "$*" in *git-receive-pack*) exec git receive-pack "$PRIVATE_TEST_REMOTE";; *) exec git upload-pack "$PRIVATE_TEST_REMOTE";; esac\n', { mode: 0o755 });
  const env = {
    ...process.env, PRIVATE_TEST_REMOTE: remote.replaceAll('\\', '/'),
    PRIVATE_SOURCE_REPOSITORY: identity.repository, PRIVATE_SOURCE_TRANSPORT_VERIFIED: identity.repository,
    GITHUB_RUN_ID: identity.runId, GITHUB_SHA: identity.workflowCommit,
    SOURCE_COMMIT: identity.sourceCommit, ZHANLU_DELIVERY_PROFILE_DIGEST: identity.profileDigest,
    GIT_SSH_COMMAND: `"${client.replaceAll('\\', '/')}"`, GIT_SSH_VARIANT: 'ssh', GIT_TERMINAL_PROMPT: '0',
  };
  delete env.GIT_CONFIG_COUNT;
  const result = spawnSync(process.execPath, [path.join(root, '.build-entry/private-source-artifact.mjs'), 'probe'], { cwd: directory, env, encoding: 'utf8', timeout: 30000 });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /read\/write probe passed/);
});

test('all stable source producers and consumers choose private storage exclusively when selected', () => {
  let uploads = 0, downloads = 0;
  for (const platform of ['macos', 'linux', 'windows']) {
    const workflow = fs.readFileSync(path.join(root, '.github/workflows', `stable-${platform}.yml`), 'utf8');
    assert.match(workflow, /private_source_repository:/);
    for (const section of workflow.matchAll(/\n    needs:\n([\s\S]*?)(?=\n    [a-z]|\n  [a-z]|$)/g)) {
      const entries = section[1].split('\n').filter(line => line.trim() && !line.trim().startsWith('#'));
      assert.ok(entries.every(line => /^\s*- [A-Za-z0-9_-]+\s*$/.test(line)), 'needs must contain job IDs only');
    }
    if (platform !== 'macos') {
      const compile = workflow.split('\n  compile:')[1].split(/\n  [A-Za-z0-9_-]+:/)[0];
      assert.match(compile, /name: Upload private compile intermediate/);
    }
    if (platform === 'linux') {
      const build = workflow.split('\n  build:')[1].split(/\n  [A-Za-z0-9_-]+:/)[0];
      const prerequisites = build.indexOf('name: Ensure private transport SSH tools');
      assert.ok(prerequisites >= 0 && prerequisites < build.indexOf('name: Fetch source code from private repository'));
      const step = build.slice(prerequisites).split('\n      - ')[0];
      assert.match(step, /openssh-client/);
      assert.doesNotMatch(step, /PRIVATE_SOURCE_DEPLOY_KEY/);
    }
    for (const step of workflow.split(/\n      - /)) {
      if (!/name: (?:vscode|Upload private compile intermediate|Download private compile intermediate)\b/.test(step)) continue;
      if (/actions\/(?:upload|download)-artifact@/.test(step)) {
        assert.match(step, /env\.PRIVATE_SOURCE_REPOSITORY == ''/);
      } else if (step.startsWith('name: Upload private')) {
        uploads++;
        assert.match(step, /env\.PRIVATE_SOURCE_REPOSITORY != ''/);
        assert.match(step, /private-git\.sh node .* upload vscode\.tar\.gz\.enc/);
      } else if (step.startsWith('name: Download private')) {
        downloads++;
        assert.match(step, /env\.PRIVATE_SOURCE_REPOSITORY != ''/);
        assert.match(step, /private-git\.sh node .* download vscode\.tar\.gz\.enc/);
      }
    }
  }
  assert.equal(uploads, 2);
  assert.equal(downloads, 4);
});
