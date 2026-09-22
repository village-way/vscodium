// zhanlu_change - new file
/* Encrypt cross-job source archives and authenticate them before exposing plaintext. */

import { createCipheriv, createDecipheriv, hkdfSync, randomBytes, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { appendFile, open, rename, rm, stat, writeFile } from 'node:fs/promises';
import { pipeline } from 'node:stream/promises';

const magic = Buffer.from('SRCENC01');
async function main() {
  const [mode, input, output] = process.argv.slice(2);
  const secret = process.env.SOURCE_ARTIFACT_KEY || '';
  if (!/^[a-fA-F0-9]{64}$/.test(secret)) throw new Error('SOURCE_ARTIFACT_KEY must be a random 32-byte hex secret');
  if (mode === 'check') return;
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
