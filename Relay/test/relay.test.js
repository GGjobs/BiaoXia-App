import assert from "node:assert/strict";
import test from "node:test";

import { handleRequest, handler } from "../src/index.js";
import { createDeepSeekModelCaller } from "../src/provider.js";
import { resolveWithFallback } from "../src/resolver.js";
import { extractProfileWithFallback } from "../src/profile-extractor.js";
import { explainFieldsWithFallback } from "../src/field-explainer.js";
import {
  validateExplainFieldsRequest,
  validateExtractProfileRequest,
  validateResolveRequest,
} from "../src/schema.js";

const schoolCandidate = "22222222-2222-4222-8222-222222222222";
const requestId = "11111111-1111-4111-8111-111111111111";
const validRequest = {
  schemaVersion: 1,
  requestId,
  templateId: "competition-registration-v1",
  fields: [
    {
      key: "school",
      label: "学校",
      allowedCandidateIds: [schoolCandidate],
    },
  ],
  candidates: [
    {
      id: schoolCandidate,
      value: "云岭未来大学",
      redactedContext: "学校：云岭未来大学",
      localConfidence: 0.72,
    },
  ],
};

const validModelJSON = JSON.stringify({
  resolutions: [
    {
      fieldKey: "school",
      candidateId: schoolCandidate,
      confidence: 0.91,
      reasonCode: "CONTEXT_MATCH",
    },
  ],
});

const validExplanationRequest = {
  schemaVersion: 1,
  requestId,
  fields: [{
    id: "field-1",
    label: "最高学历毕业院校",
    section: "教育信息",
    kind: "singleLineText",
    options: [],
  }],
};

test("accepts only the three cloud-safe fields", () => {
  assert.doesNotThrow(() => validateResolveRequest(validRequest));
  assert.throws(() =>
    validateResolveRequest({
      ...validRequest,
      fields: [
        {
          key: "fullName",
          label: "姓名",
          allowedCandidateIds: [schoolCandidate],
        },
      ],
    }),
  );
});

test("explain-fields accepts only the anonymous allowlisted schema", () => {
  assert.doesNotThrow(() => validateExplainFieldsRequest(validExplanationRequest));
  assert.throws(() => validateExplainFieldsRequest({
    ...validExplanationRequest,
    fields: [{ ...validExplanationRequest.fields[0], answer: "云岭未来大学" }],
  }));
  assert.throws(() => validateExplainFieldsRequest({
    ...validExplanationRequest,
    fileName: "个人报名表.pdf",
  }));
});

test("explain-fields rejects unknown meanings and falls back safely", async () => {
  const models = [];
  const result = await explainFieldsWithFallback(validExplanationRequest, {
    callModel: async ({ model }) => {
      models.push(model);
      return {
        content: JSON.stringify({
          explanations: [{
            fieldId: "field-1",
            canonicalKey: model.includes("pro") ? "school" : "inventedKey",
            summary: "毕业院校",
            confidence: 0.88,
            reasonCode: "LABEL_MATCH",
          }],
        }),
        usage: null,
      };
    },
  });
  assert.deepEqual(models, ["deepseek-flash", "deepseek-v4-pro"]);
  assert.equal(result.explanations[0].canonicalKey, "school");
});

test("explain-fields handler does not log or echo field text", async () => {
  const logs = [];
  const response = await handleRequest(
    new Request("https://relay.test/v1/explain-fields", {
      method: "POST",
      headers: {
        Authorization: "Bearer demo-token",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(validExplanationRequest),
    }),
    {
      env: { RELAY_CLIENT_TOKEN: "demo-token" },
      callModel: async () => ({
        content: JSON.stringify({
          explanations: [{
            fieldId: "field-1",
            canonicalKey: "school",
            summary: "毕业院校",
            confidence: 0.88,
            reasonCode: "LABEL_MATCH",
          }],
        }),
        usage: null,
      }),
      logger: {
        info(value) { logs.push(value); },
        error(value) { logs.push(value); },
      },
    },
  );
  assert.equal(response.status, 200);
  const responseText = await response.text();
  assert.equal(responseText.includes("最高学历毕业院校"), false);
  assert.equal(logs.join("\n").includes("最高学历毕业院校"), false);
});

test("returns a valid DeepSeek result on the first attempt", async () => {
  const calls = [];
  const result = await resolveWithFallback(validRequest, {
    callModel: async ({ model }) => {
      calls.push(model);
      return { content: validModelJSON, usage: { total_tokens: 12 } };
    },
  });
  assert.equal(result.modelUsed, "deepseek-flash");
  assert.equal(result.attempts, 1);
  assert.deepEqual(calls, ["deepseek-flash"]);
});

test("asks DeepSeek to correct invalid JSON once", async () => {
  let callCount = 0;
  const result = await resolveWithFallback(validRequest, {
    callModel: async () => {
      callCount += 1;
      return {
        content: callCount === 1 ? "not json" : validModelJSON,
        usage: null,
      };
    },
  });
  assert.equal(result.attempts, 2);
  assert.equal(callCount, 2);
});

test("falls back to DeepSeek Pro after two invalid Flash responses", async () => {
  const models = [];
  const result = await resolveWithFallback(validRequest, {
    callModel: async ({ model }) => {
      models.push(model);
      return {
        content: model === "deepseek-v4-pro" ? validModelJSON : "{}",
        usage: null,
      };
    },
  });
  assert.equal(result.modelUsed, "deepseek-v4-pro");
  assert.equal(result.attempts, 3);
  assert.deepEqual(models, [
    "deepseek-flash",
    "deepseek-flash",
    "deepseek-v4-pro",
  ]);
});

test("rejects a model candidate outside the allowlist", async () => {
  await assert.rejects(
    resolveWithFallback(validRequest, {
      callModel: async () => ({
        content: JSON.stringify({
          resolutions: [
            {
              fieldKey: "school",
              candidateId: "33333333-3333-4333-8333-333333333333",
              confidence: 0.99,
              reasonCode: "MADE_UP",
            },
          ],
        }),
        usage: null,
      }),
    }),
  );
});

test("HTTP handler authenticates and never echoes the request body", async () => {
  const response = await handleRequest(
    new Request("https://relay.test/v1/resolve-fields", {
      method: "POST",
      headers: {
        Authorization: "Bearer demo-token",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(validRequest),
    }),
    {
      env: { RELAY_CLIENT_TOKEN: "demo-token" },
      callModel: async () => ({ content: validModelJSON, usage: null }),
      logger: { info() {}, error() {} },
    },
  );
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.requestId, requestId);
  assert.equal(JSON.stringify(body).includes("redactedContext"), false);
});

test("HTTP handler rejects authentication failures and oversized requests", async () => {
  const unauthorized = await handleRequest(
    new Request("https://relay.test/v1/resolve-fields", {
      method: "POST",
      headers: { Authorization: "Bearer wrong-token" },
      body: JSON.stringify(validRequest),
    }),
    {
      env: { RELAY_CLIENT_TOKEN: "demo-token" },
      logger: { info() {}, error() {} },
    },
  );
  assert.equal(unauthorized.status, 401);

  const oversized = await handleRequest(
    new Request("https://relay.test/v1/resolve-fields", {
      method: "POST",
      headers: {
        Authorization: "Bearer demo-token",
        "Content-Length": String(33 * 1024),
      },
      body: "{}",
    }),
    {
      env: { RELAY_CLIENT_TOKEN: "demo-token" },
      logger: { info() {}, error() {} },
    },
  );
  assert.equal(oversized.status, 413);
});

test("Function Compute 3.0 event is mapped to an HTTP response", async () => {
  const previousToken = process.env.RELAY_CLIENT_TOKEN;
  process.env.RELAY_CLIENT_TOKEN = "demo-token";
  try {
    const response = await handler({
      version: "v1",
      rawPath: "/v1/resolve-fields",
      body: JSON.stringify(validRequest),
      isBase64Encoded: false,
      headers: {
        Authorization: "Bearer wrong-token",
        "Content-Type": "application/json",
      },
      queryParameters: {},
      requestContext: {
        domainName: "relay.test",
        http: { method: "POST", path: "/v1/resolve-fields" },
      },
    });
    assert.equal(response.statusCode, 401);
    assert.equal(response.headers["content-type"], "application/json; charset=utf-8");
    assert.equal(response.isBase64Encoded, false);
  } finally {
    if (previousToken === undefined) delete process.env.RELAY_CLIENT_TOKEN;
    else process.env.RELAY_CLIENT_TOKEN = previousToken;
  }
});

test("DeepSeek caller surfaces 429 without logging or retrying internally", async () => {
  const caller = createDeepSeekModelCaller(
    { DEEPSEEK_API_KEY: "test-only" },
    async () => new Response("rate limited", { status: 429 }),
  );
  await assert.rejects(
    caller({ model: "deepseek-flash", messages: [] }),
    /429/,
  );
});

test("DeepSeek caller aborts a timed-out request", async () => {
  const caller = createDeepSeekModelCaller(
    {
      DEEPSEEK_API_KEY: "test-only",
      MODEL_TIMEOUT_MS: "5",
    },
    async (_url, options) =>
      new Promise((_resolve, reject) => {
        options.signal.addEventListener("abort", () => {
          reject(new DOMException("aborted", "AbortError"));
        });
      }),
  );
  await assert.rejects(
    caller({ model: "deepseek-flash", messages: [] }),
    (error) => error.name === "AbortError",
  );
});

test("extract-profile accepts grounded whitelisted items", async () => {
  const blockId = "44444444-4444-4444-8444-444444444444";
  const request = {
    schemaVersion: 1,
    requestId,
    blocks: [{ id: blockId, text: "技能：Swift、Python" }],
  };
  assert.doesNotThrow(() => validateExtractProfileRequest(request));
  const modelOutput = JSON.stringify({
    items: [{
      category: "skill",
      fieldID: "skill",
      label: "技能",
      value: "Swift、Python",
      components: {},
      sourceBlockIDs: [blockId],
      confidence: 0.96,
    }],
  });
  const result = await extractProfileWithFallback(request, {
    callModel: async () => ({ content: modelOutput, usage: null }),
  });
  assert.equal(result.items.length, 1);
  assert.equal(result.items[0].value, "Swift、Python");
});

test("extract-profile drops invented values without failing the batch", async () => {
  const blockId = "44444444-4444-4444-8444-444444444444";
  const request = {
    schemaVersion: 1,
    requestId,
    blocks: [{ id: blockId, text: "技能：Swift" }],
  };
  const result = await extractProfileWithFallback(request, {
    callModel: async () => ({
      content: JSON.stringify({
        items: [{
          category: "skill",
          fieldID: "skill",
          label: "技能",
          value: "Python",
          components: {},
          sourceBlockIDs: [blockId],
          confidence: 0.99,
        }],
      }),
      usage: null,
    }),
  });
  assert.deepEqual(result.items, []);
  assert.equal(result.attempts, 2);
});

test("extract-profile keeps grounded items when another item is invalid", async () => {
  const blockId = "44444444-4444-4444-8444-444444444444";
  const request = {
    schemaVersion: 1,
    requestId,
    blocks: [{ id: blockId, text: "技能：Swift" }],
  };
  const result = await extractProfileWithFallback(request, {
    callModel: async () => ({
      content: JSON.stringify({
        items: [
          {
            category: "skill",
            fieldID: "skill",
            label: "技能",
            value: "Swift",
            components: {},
            sourceBlockIDs: [blockId],
            confidence: 0.96,
          },
          {
            category: "skill",
            fieldID: "skill",
            label: "技能",
            value: "Python",
            components: {},
            sourceBlockIDs: [blockId],
            confidence: 0.99,
          },
        ],
      }),
      usage: null,
    }),
  });
  assert.equal(result.items.length, 1);
  assert.equal(result.items[0].value, "Swift");
  assert.equal(result.attempts, 1);
});

test("extract-profile safely returns no items after repeated malformed model JSON", async () => {
  const blockId = "44444444-4444-4444-8444-444444444444";
  const request = {
    schemaVersion: 1,
    requestId,
    blocks: [{ id: blockId, text: "技能：Swift" }],
  };
  const calls = [];
  const result = await extractProfileWithFallback(request, {
    callModel: async ({ model, messages, timeoutMs }) => {
      calls.push({ model, messages, timeoutMs });
      return { content: "不是 JSON", usage: null };
    },
  });

  assert.deepEqual(result.items, []);
  assert.equal(result.attempts, 2);
  assert.equal(calls[1].messages.length, 3);
  assert.match(calls[1].messages[2].content, /只返回包含 items 数组的 JSON/);
  assert.equal(calls[0].timeoutMs, 30_000);
});

test("extract-profile still fails when the upstream model service is unavailable", async () => {
  const blockId = "44444444-4444-4444-8444-444444444444";
  const request = {
    schemaVersion: 1,
    requestId,
    blocks: [{ id: blockId, text: "技能：Swift" }],
  };
  const upstreamError = new Error("provider unavailable");
  upstreamError.statusCode = 503;

  await assert.rejects(
    extractProfileWithFallback(request, {
      callModel: async () => { throw upstreamError; },
    }),
    (error) => error.name === "ModelExtractionError" && error.statusCode === 502,
  );
});

test("extract-profile HTTP response does not echo OCR blocks", async () => {
  const blockId = "44444444-4444-4444-8444-444444444444";
  const body = {
    schemaVersion: 1,
    requestId,
    blocks: [{ id: blockId, text: "技能：Swift" }],
  };
  const response = await handleRequest(
    new Request("https://relay.test/v1/extract-profile", {
      method: "POST",
      headers: { Authorization: "Bearer demo-token", "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
    {
      env: { RELAY_CLIENT_TOKEN: "demo-token" },
      callModel: async () => ({ content: JSON.stringify({ items: [] }), usage: null }),
      logger: { info() {}, error() {} },
    },
  );
  assert.equal(response.status, 200);
  assert.equal((await response.text()).includes("技能：Swift"), false);
});
