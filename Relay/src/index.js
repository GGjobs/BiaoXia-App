import { FormPlanningError, planFormWithFallback, validatePlanRequest } from "./form-planner.js";
import { composeAnswerWithFallback, validateCompositionRequest } from "./answer-composer.js";
import { timingSafeEqual } from "node:crypto";
import { createDeepSeekModelCaller } from "./provider.js";
import { resolveWithFallback } from "./resolver.js";
import { extractProfileWithFallback } from "./profile-extractor.js";
import { explainFieldsWithFallback } from "./field-explainer.js";
import { ValidationError, validateExplainFieldsRequest } from "./schema.js";
import { DemoAccess, DemoAccessError, demoPrefix } from "./demo-access.js";

const maximumBodyBytes = 32 * 1024;

function tokenMatches(provided, expected) {
  if (!provided || !expected) return false;
  const providedBuffer = Buffer.from(provided);
  const expectedBuffer = Buffer.from(expected);
  return (
    providedBuffer.length === expectedBuffer.length &&
    timingSafeEqual(providedBuffer, expectedBuffer)
  );
}

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

export async function handleRequest(
  request,
  {
    env = process.env,
    callModel = createDeepSeekModelCaller(env),
    logger = console,
    demoAccess = new DemoAccess({ env }),
  } = {},
) {
  const path = new URL(request.url).pathname;
  if (request.method !== "POST" || !new Set([
    "/v1/resolve-fields", "/v1/extract-profile", "/v1/explain-fields", "/v2/explain-fields", "/v1/compose-answer", "/v1/plan-form", "/v1/demo-access/status",
  ]).has(path)) {
    return jsonResponse(404, { error: "NOT_FOUND" });
  }

  const authorization = request.headers.get("authorization") ?? "";
  const providedToken = authorization.startsWith("Bearer ")
    ? authorization.slice(7)
    : "";
  const isDemo = providedToken.startsWith(demoPrefix);
  if (isDemo && !["/v1/explain-fields", "/v2/explain-fields", "/v1/compose-answer", "/v1/plan-form", "/v1/demo-access/status"].includes(path)) {
    return jsonResponse(403, { error: "DEMO_SCOPE_DENIED" });
  }
  // Once demo access is configured, the shared key cannot bypass its quotas
  // on the new route. Old client routes retain their separate compatibility policy.
  const sharedAllowed = path !== "/v1/demo-access/status"
    && !(["/v1/explain-fields", "/v2/explain-fields", "/v1/compose-answer", "/v1/plan-form"].includes(path) && env.DEMO_ACCESS_CONFIG !== undefined && env.ALLOW_SHARED_EXPLANATION !== "true");
  if (!isDemo && (!sharedAllowed || !tokenMatches(providedToken, env.RELAY_CLIENT_TOKEN))) {
    return jsonResponse(401, { error: "UNAUTHORIZED" });
  }

  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (contentLength > maximumBodyBytes) {
    return jsonResponse(413, { error: "PAYLOAD_TOO_LARGE" });
  }

  const startedAt = Date.now();
  let requestId = "unknown";
  let lease;
  try {
    if (path === "/v1/demo-access/status") return jsonResponse(200, await demoAccess.status(providedToken));
    const text = await request.text();
    if (Buffer.byteLength(text, "utf8") > maximumBodyBytes) {
      return jsonResponse(413, { error: "PAYLOAD_TOO_LARGE" });
    }
    const body = JSON.parse(text);
    requestId = typeof body?.requestId === "string" && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(body.requestId) ? body.requestId : "unknown";
    if (["/v1/explain-fields", "/v2/explain-fields"].includes(path)) {
      if (body.schemaVersion !== (path.startsWith("/v2/") ? 2 : 1)) throw new ValidationError("协议版本与接口不符");
      validateExplainFieldsRequest(body);
    }
    if (path === "/v1/compose-answer") validateCompositionRequest(body);
    if (path === "/v1/plan-form") validatePlanRequest(body);
    let scopedCallModel = callModel;
    if (isDemo) {
      lease = await demoAccess.acquire(providedToken);
      scopedCallModel = async options => {
        await lease.consume();
        try {
          return await callModel({ ...options, timeoutMs: path === "/v1/plan-form" ? 30000 : 20000, maxTokens: path === "/v1/plan-form" ? 4096 : 2048 });
        } catch (error) {
          if (error.statusCode === 402) throw new DemoAccessError("UPSTREAM_BALANCE", 503);
          if ([401, 403].includes(error.statusCode)) throw new DemoAccessError("UPSTREAM_AUTH", 503);
          if (error.statusCode === 429) throw new DemoAccessError("UPSTREAM_RATE_LIMIT", 503);
          throw error;
        }
      };
    }
    const result = path === "/v1/extract-profile"
      ? await extractProfileWithFallback(body, {
          callModel,
          primaryModel: env.AI_PRIMARY_MODEL,
          fallbackModel: env.AI_FALLBACK_MODEL,
        })
      : path === "/v1/plan-form"
        ? await planFormWithFallback(body, { callModel: scopedCallModel, primaryModel: env.AI_PRIMARY_MODEL, fallbackModel: env.AI_FALLBACK_MODEL })
      : path === "/v1/compose-answer"
        ? await composeAnswerWithFallback(body, { callModel: scopedCallModel, primaryModel: env.AI_PRIMARY_MODEL, fallbackModel: env.AI_FALLBACK_MODEL })
      : ["/v1/explain-fields", "/v2/explain-fields"].includes(path)
        ? await explainFieldsWithFallback(body, {
            callModel: scopedCallModel,
            primaryModel: env.AI_PRIMARY_MODEL,
            fallbackModel: env.AI_FALLBACK_MODEL,
          })
        : await resolveWithFallback(body, {
          callModel,
          primaryModel: env.AI_PRIMARY_MODEL,
          fallbackModel: env.AI_FALLBACK_MODEL,
        });
    logger.info(
      JSON.stringify({
        requestId,
        durationMs: Date.now() - startedAt,
        statusCode: 200,
        model: result.modelUsed,
        attempts: result.attempts,
        tokenUsage: result.usage ?? null,
        ...(result.attemptFailures?.length ? { attemptFailures: result.attemptFailures } : {}),
      }),
    );
    return jsonResponse(200, path === "/v1/extract-profile" ? {
      requestId: result.requestId,
      modelUsed: result.modelUsed,
      items: result.items,
    } : path === "/v1/plan-form" ? {
      schemaVersion: result.schemaVersion, requestId: result.requestId, suggestions: result.suggestions,
    } : path === "/v1/compose-answer" ? {
      schemaVersion: result.schemaVersion, requestId: result.requestId, answer: result.answer,
      sourceIDs: result.sourceIDs, missingInformation: result.missingInformation,
    } : ["/v1/explain-fields", "/v2/explain-fields"].includes(path) ? {
      schemaVersion: result.schemaVersion,
      requestId: result.requestId,
      explanations: result.explanations,
    } : {
      requestId: result.requestId,
      modelUsed: result.modelUsed,
      resolutions: result.resolutions,
    });
  } catch (error) {
    const statusCode =
      error instanceof SyntaxError || error instanceof ValidationError
        ? 400
        : error.statusCode ?? 502;
    logger.error(
      JSON.stringify({
        requestId,
        durationMs: Date.now() - startedAt,
        statusCode,
        errorType: error.name,
        ...(error instanceof DemoAccessError ? { errorCode: error.code } : {}),
        ...(error instanceof FormPlanningError ? { errorCode: error.code, attemptFailures: error.attemptFailures } : {}),
      }),
    );
    return jsonResponse(statusCode, {
      error: error instanceof DemoAccessError || error instanceof FormPlanningError ? error.code : statusCode === 400 ? "INVALID_REQUEST" : "RESOLUTION_UNAVAILABLE",
      requestId,
    });
  } finally {
    // Lease expiration is the crash recovery path. Failure to release must not
    // turn a completed request into a retry that could incur another charge.
    if (lease) await lease.release().catch(() => {});
  }
}

async function readNodeRequest(req) {
  if (typeof req.body === "string") return req.body;
  if (Buffer.isBuffer(req.body)) return req.body.toString("utf8");
  if (req.body && typeof req.body === "object") return JSON.stringify(req.body);
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(Buffer.from(chunk));
    if (chunks.reduce((sum, item) => sum + item.length, 0) > maximumBodyBytes) {
      break;
    }
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function handleNodeRequest(req, resp) {
  const body = await readNodeRequest(req);
  const host = req.headers?.host ?? "localhost";
  const request = new Request(`https://${host}${req.url ?? "/v1/resolve-fields"}`, {
    method: req.method ?? "POST",
    headers: req.headers,
    body,
  });
  const response = await handleRequest(request);
  resp.statusCode = response.status;
  for (const [key, value] of response.headers) {
    resp.setHeader(key, value);
  }
  resp.end(await response.text());
}

function parseFunctionComputeEvent(event) {
  if (Buffer.isBuffer(event)) return JSON.parse(event.toString("utf8"));
  if (typeof event === "string") return JSON.parse(event);
  return event;
}

async function handleFunctionComputeEvent(event) {
  const parsed = parseFunctionComputeEvent(event);
  const method = parsed?.requestContext?.http?.method ?? "POST";
  const path = parsed?.requestContext?.http?.path ?? parsed?.rawPath ?? "/";
  const domain = parsed?.requestContext?.domainName ?? "localhost";
  const query = new URLSearchParams(parsed?.queryParameters ?? {}).toString();
  const url = `https://${domain}${path}${query ? `?${query}` : ""}`;
  const body = parsed?.isBase64Encoded
    ? Buffer.from(parsed.body ?? "", "base64")
    : (parsed?.body ?? "");
  const request = new Request(url, {
    method,
    headers: parsed?.headers ?? {},
    body: method === "GET" || method === "HEAD" ? undefined : body,
  });
  const response = await handleRequest(request);
  return {
    statusCode: response.status,
    headers: Object.fromEntries(response.headers),
    isBase64Encoded: false,
    body: await response.text(),
  };
}

export async function handler(eventOrRequest, contextOrResponse) {
  if (
    contextOrResponse &&
    typeof contextOrResponse.setHeader === "function" &&
    typeof contextOrResponse.end === "function"
  ) {
    return handleNodeRequest(eventOrRequest, contextOrResponse);
  }
  return handleFunctionComputeEvent(eventOrRequest);
}
