import assert from "node:assert/strict";
import test from "node:test";
import { extractReleaseUrl } from "./release-url.js";

test("extracts draft and published GitHub Release URLs", () => {
  assert.equal(extractReleaseUrl("GitHub Release (draft): https://github.com/village-way/vscodium/releases/tag/untagged-example"), "https://github.com/village-way/vscodium/releases/tag/untagged-example");
  assert.equal(extractReleaseUrl("GitHub Release (published): https://github.com/village-way/vscodium/releases/tag/1.4.15181"), "https://github.com/village-way/vscodium/releases/tag/1.4.15181");
});

test("ignores unrelated or non-GitHub lines", () => {
  assert.equal(extractReleaseUrl("https://github.com/village-way/vscodium/releases/tag/1.4.15181"), undefined);
  assert.equal(extractReleaseUrl("GitHub Release (draft): https://example.invalid/release"), undefined);
});
