// zhanlu_change - new file
/*
 * Exercise credential isolation, authenticated archives and workflow publication boundaries.
 */

import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { rootCertificates } from 'node:tls';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { afterEach, test } from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const roots = [];
const temporary = () => { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'build-security-')); roots.push(dir); return dir; };
afterEach(() => roots.splice(0).forEach(dir => fs.rmSync(dir, { recursive: true, force: true })));
const canary = 'fake-security-canary-token-never-a-real-secret';
function run(command, args, options = {}) {
  return spawnSync(command, args, { encoding: 'utf8', ...options, env: { ...process.env, ...options.env } });
}
function cryptoFixture() {
  const cwd = temporary();
  fs.writeFileSync(path.join(cwd, 'source'), `private source ${canary}\n`.repeat(10000));
  const env = { SOURCE_ARTIFACT_KEY: randomBytes(32).toString('hex'), GITHUB_REPOSITORY: 'example/build', GITHUB_RUN_ID: '123' };
  const invoke = (mode, input = 'source', output = 'encrypted', overrides = {}) => run(process.execPath,
    [path.join(root, 'scripts/source-artifact.mjs'), mode, input, output], { cwd, env: { ...env, ...overrides } });
  return { cwd, env, invoke };
}
test('round trips a source archive without exposing plaintext in ciphertext', () => {
  const { cwd, invoke } = cryptoFixture();
  assert.equal(invoke('encrypt').status, 0);
  assert.equal(fs.readFileSync(path.join(cwd, 'encrypted')).includes(Buffer.from(canary)), false);
  assert.equal(invoke('decrypt', 'encrypted', 'restored').status, 0);
  assert.deepEqual(fs.readFileSync(path.join(cwd, 'restored')), fs.readFileSync(path.join(cwd, 'source')));
});
for (const scenario of ['missing key', 'wrong key', 'different run', 'tampering', 'plaintext']) {
  test(`fails closed for ${scenario} without leaving decrypted output`, () => {
    const { cwd, invoke } = cryptoFixture();
    assert.equal(invoke('encrypt').status, 0);
    const overrides = scenario === 'missing key' ? { SOURCE_ARTIFACT_KEY: '' }
      : scenario === 'wrong key' ? { SOURCE_ARTIFACT_KEY: randomBytes(32).toString('hex') }
      : scenario === 'different run' ? { GITHUB_RUN_ID: '456' } : {};
    if (scenario === 'tampering') {
      const bytes = fs.readFileSync(path.join(cwd, 'encrypted')); bytes[45] ^= 1;
      fs.writeFileSync(path.join(cwd, 'encrypted'), bytes);
    }
    const result = invoke('decrypt', scenario === 'plaintext' ? 'source' : 'encrypted', 'restored', overrides);
    assert.notEqual(result.status, 0);
    assert.equal(fs.existsSync(path.join(cwd, 'restored')), false);
    assert.equal(fs.readdirSync(cwd).some(name => name.endsWith('.partial')), false);
    assert.equal((result.stdout + result.stderr).includes(canary), false);
  });
}
test('Git receives ephemeral credentials only for the exact HTTPS host', () => {
  const cwd = temporary();
  const script = path.join(root, 'scripts/secure-git.sh').replaceAll('\\', '/');
  const env = { HOME: cwd, XDG_CONFIG_HOME: cwd, ZHANLU_GITHUB_TOKEN: canary };
  for (const [protocol, host, allowed] of [['https', 'github.com', true], ['http', 'github.com', false], ['https', 'github.com.evil.test', false]]) {
    const result = run('bash', ['-c', 'source "$1"; secure_git credential fill', 'test', script],
      { cwd, env, input: `protocol=${protocol}\nhost=${host}\n\n` });
    assert.equal(result.status === 0, allowed);
    assert.equal(result.stdout.includes(canary), allowed);
    assert.equal(result.stderr.includes(canary), false);
  }
});
test('Git does not persist credentials through a configured store helper', () => {
  const cwd = temporary();
  const env = { HOME: cwd, XDG_CONFIG_HOME: cwd, ZHANLU_GITHUB_TOKEN: canary };
  run('git', ['config', '--global', 'credential.helper', 'store'], { cwd, env });
  const result = run('bash', ['-c', 'source "$1"; secure_git credential approve', 'test', path.join(root, 'scripts/secure-git.sh').replaceAll('\\', '/')],
    { cwd, env, input: `protocol=https\nhost=github.com\nusername=x-access-token\npassword=${canary}\n\n` });
  assert.equal(result.status, 0);
  assert.equal(fs.existsSync(path.join(cwd, '.git-credentials')), false);
  assert.equal(fs.readFileSync(path.join(cwd, '.gitconfig'), 'utf8').includes(canary), false);
});
test('rejects credential-bearing and ambiguous repository URLs without echoing them', () => {
  for (const url of [`https://${canary}@github.com/example/repo.git`, `https://github.com/example/repo?token=${canary}`, `https://github.com/example/repo\n${canary}`]) {
    const result = run('bash', ['-c', 'source "$1"; validate_source_url "$SOURCE_URL_FIXTURE"', 'test', path.join(root, 'scripts/secure-git.sh').replaceAll('\\', '/')], { env: { SOURCE_URL_FIXTURE: url } });
    assert.notEqual(result.status, 0);
    assert.equal((result.stdout + result.stderr).includes(canary), false);
  }
});
test('every source artifact upload is ciphertext and every consumer authenticates before use', () => {
  let producers = 0, consumers = 0;
  for (const file of fs.readdirSync(path.join(root, '.github/workflows')).filter(name => name.endsWith('.yml'))) {
    const source = fs.readFileSync(path.join(root, '.github/workflows', file), 'utf8').replaceAll('\r\n', '\n');
    const steps = source.split(/\n      - /);
    for (let index = 0; index < steps.length; index++) {
      const step = steps[index];
      if (/uses: actions\/upload-artifact@/.test(step) && /\n          name: vscode\s*\n/.test(step)) {
        producers++;
        assert.match(step, /path: \.\/vscode\.tar\.gz\.enc\b/);
        assert.match(steps[index - 1], /source-artifact\.mjs encrypt/);
        assert.doesNotMatch(steps[index - 1], /echo "vscode\/\.git"/);
      }
      if (/uses: actions\/download-artifact@/.test(step) && /\n          name: vscode\s*\n/.test(step)) {
        consumers++;
        assert.match(steps[index + 1], /source-artifact\.mjs decrypt/);
        assert.equal(step.match(/\n        if: (.+)/)?.[1], steps[index + 1].match(/\n        if: (.+)/)?.[1]);
      }
      if (/uses: actions\/checkout@/.test(step)) assert.match(step, /persist-credentials: false/);
      if (/uses: actions-rust-lang\/setup-rust-toolchain@/.test(step)) assert.match(step, /cache: false/);
    }
    assert.doesNotMatch(source, /run: \.\/(?:prepare_src|upload_sourcemaps)\.sh/);
  }
  assert.equal(producers, 4);
  assert.equal(consumers, 8);
});
test('real archive recipe excludes nested credentials and Git metadata', () => {
  const cwd = temporary();
  for (const name of ['vscode/src/source.ts', 'vscode/.env', 'vscode/.git/config', 'vscode/.build/extensions/node_modules/pkg/.env', 'vscode/.build/extensions/node_modules/pkg/index.js']) {
    fs.mkdirSync(path.dirname(path.join(cwd, name)), { recursive: true });
    fs.writeFileSync(path.join(cwd, name), name.endsWith('.js') || name.endsWith('.ts') ? 'source' : canary);
  }
  const workflow = fs.readFileSync(path.join(root, '.github/workflows/stable-linux.yml'), 'utf8').replaceAll('\r\n', '\n');
  const block = workflow.split('      - name: Compress vscode artifact\n')[1].split('\n      - name:')[0];
  const script = block.split('        run: |\n')[1].split('\n        if:')[0].replace(/^          /gm, '').replaceAll('scripts/source-artifact.mjs', JSON.stringify(path.join(root, 'scripts/source-artifact.mjs').replaceAll('\\', '/')));
  fs.writeFileSync(path.join(cwd, 'vscode/.npmrc'), 'target=42.4.1\nruntime=electron\n');
  fs.mkdirSync(path.join(cwd, 'vscode/remote'));
  fs.writeFileSync(path.join(cwd, 'vscode/remote/.npmrc'), 'target=24.15.0\nruntime=node\n');
  fs.writeFileSync(path.join(cwd, 'vscode/public-ca.pem'), rootCertificates[0]);
  fs.writeFileSync(path.join(cwd, 'vscode/private.pem'), `-----BEGIN PRIVATE KEY-----\n${canary}\n-----END PRIVATE KEY-----`);
  fs.writeFileSync(path.join(cwd, 'vscode/mixed.pem'), rootCertificates[0] + canary);
  fs.writeFileSync(path.join(cwd, 'vscode/.build/extensions/node_modules/pkg/cert.pem'), rootCertificates[0]);
  const env = { SOURCE_ARTIFACT_KEY: randomBytes(32).toString('hex') };
  const result = run('bash', ['-ec', script], { cwd, env });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.existsSync(path.join(cwd, 'vscode.tar.gz')), false);
  assert.equal(run(process.execPath, [path.join(root, 'scripts/source-artifact.mjs'), 'decrypt', 'vscode.tar.gz.enc', 'restored.tar.gz'], { cwd, env }).status, 0);
  const listing = run('tar', ['-tzf', 'restored.tar.gz'], { cwd });
  assert.equal(listing.status, 0);
  assert.match(listing.stdout, /src\/source.ts/);
  assert.doesNotMatch(listing.stdout, /\.git\/|\.env/);
  assert.match(listing.stdout, /vscode\/\.npmrc/);
  assert.match(listing.stdout, /vscode\/remote\/\.npmrc/);
  assert.match(listing.stdout, /vscode\/public-ca\.pem/);
  assert.match(listing.stdout, /node_modules\/pkg\/cert\.pem/);
  assert.doesNotMatch(listing.stdout, /private\.pem|mixed\.pem/);
  assert.equal(run('tar', ['-xOzf', 'restored.tar.gz', 'vscode/public-ca.pem'], { cwd }).stdout, rootCertificates[0]);
  assert.equal(run('tar', ['-xOzf', 'restored.tar.gz', 'vscode/remote/.npmrc'], { cwd }).stdout, 'target=24.15.0\nruntime=node\n');
});

test('failed fetch scrubs legacy remotes without writing or logging the canary token', () => {
  const publicEntry = fs.existsSync(path.join(root, 'fetch_source.sh'));
  const cwd = temporary(), home = path.join(cwd, 'home'), bin = path.join(cwd, 'bin');
  fs.mkdirSync(home); fs.mkdirSync(bin);
  fs.cpSync(path.join(root, 'scripts'), path.join(cwd, 'scripts'), { recursive: true });
  const entry = publicEntry ? 'fetch_source.sh' : 'get_repo.sh';
  fs.copyFileSync(path.join(root, entry), path.join(cwd, entry));
  if (!publicEntry) fs.cpSync(path.join(root, 'upstream'), path.join(cwd, 'upstream'), { recursive: true });
  const realGit = run('bash', ['-c', 'command -v git']).stdout.trim();
  fs.writeFileSync(path.join(bin, 'git'), '#!/usr/bin/env bash\ncase " $* " in *" fetch "*) exit 23 ;; esac\nexec "$REAL_GIT" "$@"\n', { mode: 0o755 });
  const checkout = path.join(cwd, publicEntry ? '.source-repo' : 'vscode');
  fs.mkdirSync(checkout);
  const env = { HOME: home, XDG_CONFIG_HOME: home, CI_BUILD: 'yes', GITHUB_ACTIONS: 'true',
    GITHUB_ENV: '', GITHUB_REPOSITORY: 'example/build', VSCODE_REPO: 'origin', VSCODE_QUALITY: 'stable',
    SOURCE_REPO_URL: 'https://github.com/example/private.git', ZHANLU_GITHUB_TOKEN: canary,
    REAL_GIT: realGit, PATH: `${bin}${path.delimiter}${process.env.PATH}` };
  assert.equal(run('bash', ['-c', '"$REAL_GIT" init -q', 'test'], { cwd: checkout, env }).status, 0);
  assert.equal(run('bash', ['-c', '"$REAL_GIT" remote add origin "$1"', 'test', `https://${canary}@github.com/example/private.git`], { cwd: checkout, env }).status, 0);
  const result = run('bash', ['-x', entry], { cwd, env });
  assert.notEqual(result.status, 0);
  assert.equal((result.stdout + result.stderr).includes(canary), false);
  assert.equal(fs.readFileSync(path.join(checkout, '.git/config'), 'utf8').includes(canary), false);
  assert.equal(fs.existsSync(path.join(home, '.git-credentials')), false);
});

if (fs.existsSync(path.join(root, 'prepare_src.sh'))) test('source release entrypoints and mixed binary/source publication fail before network access', () => {
  const cwd = temporary();
  for (const entry of ['prepare_src.sh', 'upload_sourcemaps.sh']) {
    assert.notEqual(run('bash', [path.join(root, entry)], { cwd }).status, 0);
  }
  fs.mkdirSync(path.join(cwd, 'assets'));
  fs.writeFileSync(path.join(cwd, 'assets', 'App-1-src.tar.gz'), 'private source');
  fs.writeFileSync(path.join(cwd, 'assets', 'App-1.zip'), 'binary');
  const result = run('bash', ['-x', path.join(root, 'release.sh')], { cwd,
    env: { GITHUB_TOKEN: canary, APP_NAME: 'App', RELEASE_VERSION: '1', ALLOW_SOURCE_ONLY_RELEASE: 'yes' } });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /source or credential assets cannot be published/);
  assert.equal((result.stdout + result.stderr).includes(canary), false);
});


test('source tokens use pinned read-only repository scope without a long-lived fallback', () => {
  let tokenJobs = 0;
  for (const file of fs.readdirSync(path.join(root, '.github/workflows')).filter(name => name.endsWith('.yml'))) {
    const source = fs.readFileSync(path.join(root, '.github/workflows', file), 'utf8').replaceAll('\r\n', '\n');
    assert.doesNotMatch(source, /secrets\.ZHANLU_GITHUB_TOKEN/);
    const sharedInputs = source.match(/with: &source-read-inputs\n((?:          .+\n)+)/)?.[1];
    for (const step of source.split(/\n      - /).filter(step => /id: source-token\n/.test(step))) {
      tokenJobs++;
      assert.match(step, /uses: actions\/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1\b/);
      const inputs = step.includes('with: *source-read-inputs') ? sharedInputs : step;
      assert.ok(inputs);
      assert.match(inputs, /client-id: \$\{\{ vars\.SOURCE_APP_CLIENT_ID \}\}/);
      assert.doesNotMatch(inputs, /\bapp-id:/);
      assert.match(inputs, /permission-contents: read/);
      assert.match(inputs, /repositories: \$\{\{ vars\.SOURCE_APP_REPOSITORIES \|\| '__missing_source_repository_configuration__' \}\}/);
      assert.match(inputs, /private-key: \$\{\{ secrets\.SOURCE_APP_PRIVATE_KEY \}\}/);
      assert.doesNotMatch(inputs, /permission-[\w-]+: write/);
    }
  }
  assert.ok(tokenJobs > 0);
});

test('release Git authentication prefers the portal push token and preserves API credentials', () => {
  for (const portal of [true, false]) {
    const cwd = temporary();
    fs.cpSync(path.join(root, 'scripts'), path.join(cwd, 'scripts'), { recursive: true });
    fs.copyFileSync(path.join(root, 'create-release.sh'), path.join(cwd, 'create-release.sh'));
    fs.writeFileSync(path.join(cwd, 'utils.sh'), `
credential="$(printf 'protocol=https\\nhost=github.com\\n\\n' | secure_git credential fill)"
[[ "$credential" == *"password=$EXPECTED_GIT_TOKEN"* ]] || exit 21
[[ "$GH_TOKEN" == "$EXPECTED_API_TOKEN" ]] || exit 22
exit 0
`);
    const apiToken = 'fake-api-token';
    const result = run('bash', ['-x', 'create-release.sh'], { cwd, env: {
      GITHUB_GIT_TOKEN: portal ? canary : '', GH_TOKEN: apiToken, GITHUB_TOKEN: 'fake-workflow-token',
      EXPECTED_GIT_TOKEN: portal ? canary : apiToken, EXPECTED_API_TOKEN: apiToken,
      HOME: cwd, XDG_CONFIG_HOME: cwd,
    } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal((result.stdout + result.stderr).includes(canary), false);
    assert.equal((result.stdout + result.stderr).includes(apiToken), false);
    assert.equal(fs.existsSync(path.join(cwd, '.git-credentials')), false);
  }
});


test('archive preflight rejects nested npm credentials without echoing their values', () => {
  const cwd = temporary();
  const nested = path.join(cwd, 'vscode/.build/extensions/node_modules/pkg');
  fs.mkdirSync(nested, { recursive: true });
  const env = { SOURCE_ARTIFACT_KEY: randomBytes(32).toString('hex') };
  for (const content of [`//registry.npmjs.org/:_authToken=${canary}`, `registry=https://${canary}@example.test/`, `_password=${canary}`]) {
    fs.writeFileSync(path.join(nested, '.npmrc'), content);
    const result = run(process.execPath, [path.join(root, 'scripts/source-artifact.mjs'), 'check', 'vscode'], { cwd, env });
    assert.notEqual(result.status, 0);
    assert.equal((result.stdout + result.stderr).includes(canary), false);
  }
});


test('Windows toolchain setup waits for installation and rejects unsuccessful or incomplete installs', { skip: process.platform !== 'win32' }, () => {
  for (const workflow of ['stable-windows.yml', 'insider-windows.yml']) {
    const contents = fs.readFileSync(path.join(root, '.github/workflows', workflow), 'utf8').replaceAll('\r\n', '\n');
    const step = contents.split('      - name: Install Visual Studio 2022 C++ build tools\n')[1].split('      # zhanlu_change end')[0];
    const setup = step.split('        run: |\n')[1].replace(/^          /gm, '');
    for (const [exitCode, complete, success] of [[0, true, true], [3010, true, true], [1, true, false], [0, false, false]]) {
      const cwd = temporary();
      const output = path.join(cwd, 'github-env');
      const fixture = `
$env:GITHUB_ENV = '${output.replaceAll("'", "''")}'
$script:installed = $false
function Test-Path { param($Path) return ($script:installed -and $${complete}) }
function Invoke-WebRequest { param($Uri, $OutFile) }
function Start-Process {
  param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
  if (-not $Wait -or -not $PassThru -or '--wait' -notin $ArgumentList) { throw 'Installer was not awaited' }
  $script:installed = $true
  return [pscustomobject]@{ ExitCode = ${exitCode} }
}
${setup}
`;
      fs.writeFileSync(path.join(cwd, 'setup.ps1'), fixture);
      const result = run('pwsh', ['-NoProfile', '-File', path.join(cwd, 'setup.ps1')], { cwd });
      assert.equal(result.status === 0, success, result.stdout + result.stderr);
      assert.equal(fs.existsSync(output), success);
      if (success) assert.match(fs.readFileSync(output, 'utf8'), /vs2022_install=.*BuildTools/);
    }
  }
});
