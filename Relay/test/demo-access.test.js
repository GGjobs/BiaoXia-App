import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";
import { mkdtemp, readFile, stat, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DemoAccess, DemoAccessError, tokenID, parseDemoConfig } from "../src/demo-access.js";
import { runAdmin } from "../scripts/demo-access.mjs";
import { handleRequest } from "../src/index.js";
import { createDeepSeekModelCaller } from "../src/provider.js";

const token = "bx_demo_" + "a".repeat(64);
const payload = { schemaVersion: 1, requestId: "11111111-1111-4111-8111-111111111111",
  fields: [{ id: "field-1", label: "姓名", kind: "singleLineText", options: [] }] };
const output = { content: JSON.stringify({ explanations: [{ fieldId: "field-1", canonicalKey: "fullName", summary: "姓名", confidence: 0.9, reasonCode: "LABEL_MATCH" }] }) };
const logger = { info() {}, error() {} };
let env, config, state, now, access;
function sync() { env.DEMO_ACCESS_CONFIG = JSON.stringify(config); }
beforeEach(() => {
  now = 1800000000000;
  env = { RELAY_CLIENT_TOKEN: "legacy-test" };
  config = { enabled: true, credentials: { [tokenID(token)]: { expiresAt: now / 1000 + 604800, minuteLimit: 5, revoked: false } } };
  sync(); state = new Map(); access = new DemoAccess({ env, state, now: () => now });
});
function request(path = "/v1/explain-fields", value = token, body = payload) {
  return new Request("https://example.invalid" + path, { method: "POST", headers: { Authorization: "Bearer " + value }, body: JSON.stringify(body) });
}
function rejectsCode(promise, code) { return assert.rejects(promise, e => e instanceof DemoAccessError && e.code === code); }

test("status exposes process scope without pretending to offer daily quotas", async () => {
  assert.deepEqual(await access.status(token), { expiresAt: now / 1000 + 604800, limitScope: "process", requestsPerMinute: 5 });
  assert.equal(state.size, 0);
});
test("invalid, expired and revoked tokens fail before model calls", async () => {
  await rejectsCode(access.status("bx_demo_bad"), "DEMO_INVALID");
  await rejectsCode(access.status("bx_demo_" + "b".repeat(64)), "DEMO_INVALID");
  config.credentials[tokenID(token)].expiresAt = now / 1000; sync();
  await rejectsCode(access.acquire(token), "DEMO_EXPIRED");
  config.credentials[tokenID(token)].revoked = true; sync();
  await rejectsCode(access.acquire(token), "DEMO_REVOKED");
});
test("missing, malformed and disabled configuration fail closed", async () => {
  for (const raw of [undefined, "", "null", "{}", '{"enabled":true,"credentials":[]}', 'x'.repeat(32769)]) {
    env.DEMO_ACCESS_CONFIG = raw;
    await rejectsCode(access.acquire(token), "DEMO_UNAVAILABLE");
  }
  config.enabled = false; sync(); await rejectsCode(access.acquire(token), "DEMO_DISABLED");
  config.credentials[tokenID(token)].minuteLimit = 0;
  assert.throws(() => parseDemoConfig(JSON.stringify(config)));
});
test("one process allows a single simultaneous request per credential", async () => {
  const instances = Array.from({ length: 10 }, () => new DemoAccess({ env, state, now: () => now }));
  const results = await Promise.allSettled(instances.map(x => x.acquire(token)));
  assert.equal(results.filter(x => x.status === "fulfilled").length, 1);
  for (const result of results) if (result.status === "fulfilled") await result.value.release();
  await (await access.acquire(token)).release();
});
test("rate limit resets at minute boundary and independently after process restart", async () => {
  config.credentials[tokenID(token)].minuteLimit = 1; sync();
  await (await access.acquire(token)).release();
  await rejectsCode(access.acquire(token), "DEMO_RATE_LIMIT");
  await (await new DemoAccess({ env, state: new Map(), now: () => now }).acquire(token)).release();
  now += 60000; await (await access.acquire(token)).release();
});
test("stale lease cannot release its replacement; process crash lease expires", async () => {
  const old = await access.acquire(token); now += 180001;
  const next = await access.acquire(token); await old.release();
  await rejectsCode(old.consume(), "DEMO_BUSY"); await next.consume(); await next.release();
});
test("revocation and pause are rechecked before fallback", async () => {
  const lease = await access.acquire(token); await lease.consume();
  config.credentials[tokenID(token)].revoked = true; sync();
  await rejectsCode(lease.consume(), "DEMO_REVOKED");
  config.credentials[tokenID(token)].revoked = false; config.enabled = false; sync();
  await rejectsCode(lease.consume(), "DEMO_DISABLED"); await lease.release();
});
test("per-request attempt cap remains two", async () => {
  const lease = await access.acquire(token); await lease.consume(); await lease.consume();
  await rejectsCode(lease.consume(), "DEMO_RATE_LIMIT"); await lease.release();
});
test("fallback remains bounded with timeout and output cap", async () => {
  let calls = 0;
  const response = await handleRequest(request(), { env, logger, demoAccess: access, callModel: async options => {
    assert.equal(options.maxTokens, 2048); assert.equal(options.timeoutMs, 20000);
    return ++calls === 1 ? { content: "invalid JSON" } : output;
  } });
  assert.equal(response.status, 200); assert.equal(calls, 2); await (await access.acquire(token)).release();
});
test("billing/auth/rate errors do not retry another paid model", async () => {
  for (const statusCode of [402, 401, 403, 429]) {
    let calls = 0;
    const response = await handleRequest(request(), { env, logger, demoAccess: access, callModel: async () => {
      calls++; throw Object.assign(new Error("private upstream"), { statusCode });
    } });
    assert.equal(calls, 1); assert.equal(response.status, 503); assert.match((await response.json()).error, /^UPSTREAM_/);
  }
});
test("demo access cannot call old routes; shared key cannot bypass configured access", async () => {
  for (const path of ["/v1/resolve-fields", "/v1/extract-profile"]) {
    assert.equal((await handleRequest(request(path), { env, logger, demoAccess: access, callModel: () => assert.fail() })).status, 403);
  }
  assert.equal((await handleRequest(request(undefined, "legacy-test"), { env, logger, callModel: () => assert.fail() })).status, 401);
});
test("invalid text and IDs are neither sent nor logged", async () => {
  const logs = [];
  const response = await handleRequest(request(undefined, token, { ...payload, requestId: "private-value" }), {
    env, logger: { info: x => logs.push(x), error: x => logs.push(x) }, demoAccess: access, callModel: () => assert.fail()
  });
  assert.equal(response.status, 400); assert.ok(!logs.join("").includes("private-value")); assert.equal(state.size, 0);
  assert.throws(() => tokenID(token + "\n"));
});
test("status and missing config do not call model", async () => {
  const response = await handleRequest(request("/v1/demo-access/status"), { env, logger, demoAccess: access, callModel: () => assert.fail() });
  assert.equal(response.status, 200); assert.equal((await response.json()).limitScope, "process");
  env.DEMO_ACCESS_CONFIG = "broken";
  const unavailable = await handleRequest(request(), { env, logger, demoAccess: access, callModel: () => assert.fail() });
  assert.equal(unavailable.status, 503); assert.equal((await unavailable.json()).error, "DEMO_UNAVAILABLE");
});
test("provider sends maximum output tokens", async () => {
  const call = createDeepSeekModelCaller({ DEEPSEEK_API_KEY: "synthetic" }, async (_url, options) => {
    assert.equal(JSON.parse(options.body).max_tokens, 2048);
    assert.equal(JSON.parse(options.body).thinking, undefined);
    return { ok: true, json: async () => ({ choices: [{ message: { content: "{}" } }] }) };
  });
  await call({ model: "test", messages: [], maxTokens: 2048 });
});
test("local admin securely issues, extends, revokes and pauses; never claims cloud application", async () => {
  const dir = await mkdtemp(join(tmpdir(), "biaoxia-config-test-"));
  try {
    const file = join(dir, "review.demo-config.json"), secret = join(dir, "phone.demo-access.json");
    const reports = [];
    await runAdmin(["issue", file, "https://example.invalid", secret, "30"], x => reports.push(x));
    const issued = JSON.parse(await readFile(secret, "utf8"));
    const id = tokenID(issued.token);
    assert.equal((await stat(secret)).mode & 0o777, 0o600); assert.equal((await stat(file)).mode & 0o777, 0o600);
    assert.ok(!reports.join("").includes(issued.token)); assert.equal(JSON.parse(reports[0]).appliedToCloud, false);
    assert.ok(!(await readFile(file, "utf8")).includes(issued.token));
    const before = JSON.parse(await readFile(file, "utf8")).credentials[id].expiresAt;
    await assert.rejects(runAdmin(["issue", file, "https://example.invalid", secret], () => {}));
    await runAdmin(["enable", file], () => {});
    const issuedEnv = { DEMO_ACCESS_CONFIG: await readFile(file, "utf8") };
    const issuedAccess = new DemoAccess({ env: issuedEnv, state: new Map() });
    assert.equal((await issuedAccess.status(issued.token)).expiresAt, before);
    await runAdmin(["extend", file, id, "2"], () => {});
    await runAdmin(["revoke", file, id], () => {});
    await runAdmin(["extend", file, id, "7"], () => {});
    issuedEnv.DEMO_ACCESS_CONFIG = await readFile(file, "utf8");
    await rejectsCode(issuedAccess.status(issued.token), "DEMO_REVOKED");
    assert.equal(JSON.parse(issuedEnv.DEMO_ACCESS_CONFIG).credentials[id].expiresAt, before + 9 * 86400);
    await runAdmin(["disable", file], () => {});
    assert.equal(JSON.parse(await readFile(file, "utf8")).enabled, false);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
