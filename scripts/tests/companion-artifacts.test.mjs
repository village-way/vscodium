import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const workflow = name => readFileSync(new URL(`../../.github/workflows/${name}.yml`, import.meta.url), 'utf8');

test('optional companion artifacts remain blocking children of the selected platform run', () => {
  for (const platform of ['macos', 'linux', 'windows']) {
    const source = workflow(`stable-${platform}`);
    const child = source.slice(source.indexOf('\n  companion:'));
    assert.match(child, /needs: build/);
    assert.match(child, /uses: \.\/\.github\/workflows\/companion-artifacts.yml/);
    assert.match(child, /inputs\.companion_commit/);
    assert.match(child, /source_commit:.*inputs\.source_commit/);
    assert.match(child, /release_kind:/);
    assert.match(child, /generate_assets:/);
    assert.doesNotMatch(child, /continue-on-error/);
  }
  const source = workflow('companion-artifacts');
  assert.match(source, /python:3\.11-bullseye/);
  assert.match(source, /linux-arm64/);
  assert.match(source, /path: delivery-assets\.tar\.enc/);
  assert.doesNotMatch(source, /path: assets/);
});
