// Store protected compile intermediates exclusively on an isolated private Git branch.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const MAX_CHUNK = 32 * 1024 * 1024;
const SHA256 = /^[a-f0-9]{64}$/;
const SHA1 = /^[a-f0-9]{40}$/;
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function git(cwd, args) {
  const result = spawnSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
  if (result.status !== 0) {
    throw new Error(`Private artifact Git operation failed: ${args[0]}`);
  }
  return result.stdout.trim();
}

export function validateIdentity(identity) {
  if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(identity.repository ?? '') ||
      !/^[0-9]{1,20}$/.test(identity.runId ?? '') || !SHA1.test(identity.sourceCommit ?? '') ||
      !SHA1.test(identity.workflowCommit ?? '') || !SHA256.test(identity.profileDigest ?? '')) {
    throw new Error('Invalid private artifact identity');
  }
}

export function validateManifest(manifest, identity) {
  validateIdentity(identity);
  if (manifest.schemaVersion !== 1 ||
      Object.keys(identity).some(key => manifest[key] !== identity[key]) ||
      !Number.isSafeInteger(manifest.size) || manifest.size <= 0 || !SHA256.test(manifest.sha256 ?? '') ||
      !Array.isArray(manifest.chunks) || manifest.chunks.length === 0 || manifest.chunks.length > 1024) {
    throw new Error('Private artifact manifest does not match this build');
  }
  let size = 0;
  for (const [index, chunk] of manifest.chunks.entries()) {
    if (chunk.name !== `chunk-${String(index).padStart(5, '0')}` ||
        !Number.isSafeInteger(chunk.size) || chunk.size <= 0 || chunk.size > MAX_CHUNK ||
        !SHA256.test(chunk.sha256 ?? '')) {
      throw new Error('Invalid private artifact chunk descriptor');
    }
    size += chunk.size;
  }
  if (size !== manifest.size) {
    throw new Error('Private artifact size mismatch');
  }
}

function storeCheckout(directory, identity, remote) {
  validateIdentity(identity);
  const ref = `refs/heads/build-artifacts/${identity.runId}`;
  git(directory, ['init', '--quiet']);
  // Windows checkout must preserve ciphertext bytes exactly, including small probe files.
  git(directory, ['config', 'core.autocrlf', 'false']);
  git(directory, ['remote', 'add', 'origin', remote]);
  const exists = git(directory, ['ls-remote', '--heads', 'origin', ref]) !== '';
  if (exists) {
    git(directory, ['fetch', '--quiet', '--depth', '1', 'origin', ref]);
    git(directory, ['checkout', '--quiet', '-b', 'artifact', 'FETCH_HEAD']);
  } else {
    git(directory, ['checkout', '--quiet', '--orphan', 'artifact']);
  }
  return { ref, exists };
}

export function uploadArtifact(input, identity, { remote, chunkBytes = MAX_CHUNK, batchChunks = 4 } = {}) {
  validateIdentity(identity);
  if (!Number.isSafeInteger(chunkBytes) || chunkBytes < 1 || chunkBytes > MAX_CHUNK ||
      !Number.isSafeInteger(batchChunks) || batchChunks < 1 || batchChunks > 4 ||
      !fs.lstatSync(input).isFile() || fs.statSync(input).size <= 0) {
    throw new Error('Invalid private artifact upload');
  }
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'private-build-store-'));
  let descriptor;
  try {
    const { ref } = storeCheckout(directory, identity, remote ?? `https://github.com/${identity.repository}.git`);
    git(directory, ['config', 'user.name', 'build-storage']);
    git(directory, ['config', 'user.email', 'build-storage@users.noreply.github.com']);
    for (const entry of fs.readdirSync(directory)) {
      if (entry === '.git') continue;
      if (entry !== 'manifest.json' && !/^chunk-[0-9]{5}$/.test(entry)) {
        throw new Error('Refusing to replace unrelated private storage files');
      }
      fs.rmSync(path.join(directory, entry));
    }
    const manifest = { schemaVersion: 1, ...identity, size: 0, sha256: '', chunks: [] };
    const hash = crypto.createHash('sha256');
    descriptor = fs.openSync(input, 'r');
    const buffer = Buffer.allocUnsafe(chunkBytes);
    for (;;) {
      let used = 0;
      while (used < buffer.length) {
        const length = fs.readSync(descriptor, buffer, used, buffer.length - used, null);
        if (length === 0) break;
        used += length;
      }
      if (used === 0) break;
      const bytes = buffer.subarray(0, used);
      const name = `chunk-${String(manifest.chunks.length).padStart(5, '0')}`;
      fs.writeFileSync(path.join(directory, name), bytes);
      manifest.chunks.push({ name, size: used, sha256: digest(bytes) });
      manifest.size += used;
      hash.update(bytes);
      if (manifest.chunks.length % batchChunks === 0) {
        git(directory, ['add', '--all']);
        git(directory, ['commit', '--quiet', '-m', 'build: stage protected intermediate chunks']);
        git(directory, ['push', '--quiet', 'origin', `HEAD:${ref}`]);
      }
    }
    manifest.sha256 = hash.digest('hex');
    validateManifest(manifest, identity);
    fs.writeFileSync(path.join(directory, 'manifest.json'), `${JSON.stringify(manifest)}\n`);
    git(directory, ['add', '--all']);
    git(directory, ['commit', '--quiet', '-m', 'build: finalize protected intermediate manifest']);
    git(directory, ['push', '--quiet', 'origin', `HEAD:${ref}`]);
    return { manifest, commit: git(directory, ['rev-parse', 'HEAD']) };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

export function downloadArtifact(output, identity, { remote } = {}) {
  validateIdentity(identity);
  if (fs.existsSync(output)) throw new Error('Private artifact output already exists');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'private-build-read-'));
  const temporary = `${output}.private-${process.pid}`;
  let descriptor;
  try {
    const { exists } = storeCheckout(directory, identity, remote ?? `https://github.com/${identity.repository}.git`);
    if (!exists) throw new Error('Private compile artifact is not available');
    let manifest;
    try {
      const file = path.join(directory, 'manifest.json');
      if (!fs.lstatSync(file).isFile() || fs.statSync(file).size > 1024 * 1024) throw new Error();
      manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      throw new Error('Private compile artifact has no valid completion manifest');
    }
    validateManifest(manifest, identity);
    descriptor = fs.openSync(temporary, 'wx', 0o600);
    const hash = crypto.createHash('sha256');
    for (const chunk of manifest.chunks) {
      const file = path.join(directory, chunk.name);
      if (!fs.lstatSync(file).isFile() || fs.statSync(file).size !== chunk.size) {
        throw new Error('Private artifact chunk size mismatch');
      }
      const bytes = fs.readFileSync(file);
      if (digest(bytes) !== chunk.sha256) throw new Error('Private artifact chunk checksum mismatch');
      hash.update(bytes);
      fs.writeSync(descriptor, bytes);
    }
    if (fs.fstatSync(descriptor).size !== manifest.size || hash.digest('hex') !== manifest.sha256) {
      throw new Error('Private artifact checksum mismatch');
    }
    fs.closeSync(descriptor);
    descriptor = undefined;
    fs.renameSync(temporary, output);
    return { manifest, commit: git(directory, ['rev-parse', 'HEAD']) };
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    fs.rmSync(temporary, { force: true });
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const identity = {
      repository: process.env.PRIVATE_SOURCE_REPOSITORY,
      runId: process.env.GITHUB_RUN_ID,
      sourceCommit: process.env.SOURCE_COMMIT,
      workflowCommit: process.env.GITHUB_SHA,
      profileDigest: process.env.ZHANLU_DELIVERY_PROFILE_DIGEST,
    };
    if (process.env.PRIVATE_SOURCE_TRANSPORT_VERIFIED !== identity.repository) {
      throw new Error('Verified private transport is required');
    }
    const [mode, file] = process.argv.slice(2);
    if (mode === 'probe' && process.argv.length === 3) {
      const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'private-build-probe-'));
      try {
        const input = path.join(directory, 'probe');
        const output = path.join(directory, 'restored');
        const bytes = crypto.randomBytes(32);
        fs.writeFileSync(input, bytes);
        uploadArtifact(input, identity);
        downloadArtifact(output, identity);
        if (!fs.readFileSync(output).equals(bytes)) throw new Error('Private transport probe mismatch');
        console.log('Private intermediate transport read/write probe passed');
      } finally {
        fs.rmSync(directory, { recursive: true, force: true });
      }
    } else if (!file || !['upload', 'download'].includes(mode) || process.argv.length !== 4) {
      throw new Error('Expected upload|download and one protected artifact path');
    } else {
      const result = mode === 'upload' ? uploadArtifact(file, identity) : downloadArtifact(file, identity);
      console.log(`Protected intermediate ${mode} complete: ${result.commit}`);
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
