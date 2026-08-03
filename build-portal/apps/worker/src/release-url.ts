const releaseUrlPattern = /^GitHub Release \((?:draft|published)\):\s+(https:\/\/github\.com\/\S+)$/;

export function extractReleaseUrl(line: string): string | undefined {
  return line.trim().match(releaseUrlPattern)?.[1];
}
