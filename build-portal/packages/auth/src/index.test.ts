import test from "node:test";
import assert from "node:assert/strict";
import { csrfTokenFor, sessionCookie, verifyCsrf, verifyOrigin } from "./index.js";

process.env.CSRF_HMAC_SECRET = "auth-test-csrf-secret";
process.env.PUBLIC_ORIGIN = "https://portal.test";

test("CSRF token is stable for a session and isolated between sessions", () => {
  const first = csrfTokenFor("session-one");
  assert.equal(first, csrfTokenFor("session-one"));
  assert.notEqual(first, csrfTokenFor("session-two"));
  assert.equal(verifyCsrf({ sessionId: "session-one", csrfHash: "legacy", userId: "u", username: "admin" }, first), true);
  assert.equal(verifyCsrf({ sessionId: "session-one", csrfHash: "legacy", userId: "u", username: "admin" }, csrfTokenFor("session-two")), false);
});

test("session cookie keeps the secure browser boundary", () => {
  const cookie = sessionCookie("session-value");
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /Secure/);
  assert.match(cookie, /SameSite=Lax/);
  assert.match(cookie, /Max-Age=43200/);
});

test("origin validation accepts only the configured origin", () => {
  assert.equal(verifyOrigin("https://portal.test"), true);
  assert.equal(verifyOrigin("https://portal.test.evil"), false);
  assert.equal(verifyOrigin(null), false);
});
