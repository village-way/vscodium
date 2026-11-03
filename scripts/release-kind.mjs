// zhanlu_change - new file
/*
 * Derives the package release channel from the public version and rejects
 * conflicting caller hints before release mutations begin.
 */

import { pathToFileURL } from 'node:url';

export function releaseKind(version, requested = 'auto') {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-insider|-ci1232\.(?:0|[1-9]\d*))?$/.exec(version);
  if (!match) throw new Error('Expected a numeric public release version');
  const kind = match[3].length > 4 || match[4] ? 'development' : 'formal';
  if (!['auto', 'formal', 'development'].includes(requested)) throw new Error('Invalid release kind');
  if (requested !== 'auto' && requested !== kind) {
    throw new Error(`Release kind ${requested} conflicts with public version ${version}: expected ${kind}`);
  }
  return kind;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.stdout.write(`${releaseKind(process.argv[2], process.argv[3])}\n`);
}
