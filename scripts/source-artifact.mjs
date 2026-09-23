// zhanlu_change - new file
/*
 * Encrypt cross-job source archives and authenticate them before exposing plaintext.
 */

import { createCipheriv, createDecipheriv, hkdfSync, randomBytes, randomUUID, X509Certificate } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { appendFile, open, rename, rm, stat, writeFile, readdir, readFile } from 'node:fs/promises';
import { pipeline } from 'node:stream/promises';
import path from 'node:path';

const magic = Buffer.from('SRCENC01');
// Preserve native build settings while rejecting credentials before archiving.
async function checkNpmConfigs(directory, certificates) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name === '.git' || entry.name === '.env' || entry.name.startsWith('.env.')) continue;
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) await checkNpmConfigs(file, certificates);
    else if (entry.isFile() && entry.name.endsWith('.pem')) {
      // PEM is a container, not a secret type: preserve only complete public certificates.
      const contents = await readFile(file, 'utf8');
      const blocks = contents.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) || [];
      if (blocks.length && !contents.replace(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g, '').trim()) {
        try {
          for (const block of blocks) new X509Certificate(block);
          certificates.push(file.split(path.sep).join('/'));
        } catch { /* Invalid PEM stays excluded from the archive. */ }
      }
    } else if (entry.name === '.npmrc') {
      if (!entry.isFile()) throw new Error('Linked npm configuration is forbidden');
      for (const line of (await readFile(file, 'utf8')).split(/\r?\n/)) {
        if (/^\s*(?:[;#]|$)/.test(line)) continue;
        const separator = line.indexOf('=');
        if (separator < 0) throw new Error('Invalid npm configuration');
        const key = line.slice(0, separator).trim();
        const value = line.slice(separator + 1).trim();
        if (/(?:auth|token|password|username|cert|keyfile)/i.test(key)
            || /https?:\/\/[^/\s]*@/i.test(value)
            || /[?&](?:token|key|api[_-]?key|password)=/i.test(value)) {
          throw new Error('Credential-bearing npm configuration is forbidden');
        }
      }
    }
  }
}

async function main() {
  const [mode, input, output] = process.argv.slice(2);
  const secret = process.env.SOURCE_ARTIFACT_KEY || '';
  if (!/^[a-fA-F0-9]{64}$/.test(secret)) throw new Error('SOURCE_ARTIFACT_KEY must be a random 32-byte hex secret');
  if (mode === 'check') {
    const certificates = [];
    if (input) await checkNpmConfigs(input, certificates);
    if (output) await writeFile(output, certificates.length ? certificates.join('\0') + '\0' : '', { mode: 0o600 });
    return;
  }
  if (!['encrypt', 'decrypt'].includes(mode) || !input || !output || input === output) throw new Error('Invalid archive operation');
  const context = `${process.env.GITHUB_REPOSITORY || 'local'}:${process.env.GITHUB_RUN_ID || 'local'}`;
  const temporary = `${output}.${randomUUID()}.partial`;
  try {
    if (mode === 'encrypt') {
      const salt = randomBytes(16), nonce = randomBytes(12);
      const header = Buffer.concat([magic, salt, nonce]);
      const key = hkdfSync('sha256', Buffer.from(secret, 'hex'), salt, Buffer.from(context), 32);
      const cipher = createCipheriv('aes-256-gcm', key, nonce);
      cipher.setAAD(header);
      await writeFile(temporary, header, { mode: 0o600, flag: 'wx' });
      await pipeline(createReadStream(input), cipher, createWriteStream(temporary, { flags: 'a' }));
      await appendFile(temporary, cipher.getAuthTag());
    } else {
      const size = (await stat(input)).size;
      if (size < 52) throw new Error('Invalid archive');
      const file = await open(input, 'r');
      const header = Buffer.alloc(36), tag = Buffer.alloc(16);
      try {
        await file.read(header, 0, 36, 0);
        await file.read(tag, 0, 16, size - 16);
      } finally { await file.close(); }
      if (!header.subarray(0, 8).equals(magic)) throw new Error('Unencrypted source archives are forbidden');
      const key = hkdfSync('sha256', Buffer.from(secret, 'hex'), header.subarray(8, 24), Buffer.from(context), 32);
      const decipher = createDecipheriv('aes-256-gcm', key, header.subarray(24, 36));
      decipher.setAAD(header);
      decipher.setAuthTag(tag);
      await pipeline(createReadStream(input, { start: 36, end: size - 17 }), decipher,
        createWriteStream(temporary, { mode: 0o600, flags: 'wx' }));
    }
    await rename(temporary, output);
  } finally { await rm(temporary, { force: true }); }
}
main().catch(() => {
  // Neither paths, configuration values nor crypto errors belong in public logs.
  console.error('Source archive protection failed; no artifact may be published. Check key and run context.');
  process.exitCode = 1;
});
