export function createDeepSeekModelCaller(env = process.env, fetchImpl = fetch) {
  const apiKey = env.DEEPSEEK_API_KEY;
  const baseURL = (env.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com").replace(
    /\/$/,
    "",
  );
  const timeoutMilliseconds = Number(env.MODEL_TIMEOUT_MS ?? 20000);

  return async function callModel({ model, messages, timeoutMs, maxTokens, thinking }) {
    if (!apiKey) {
      const error = new Error("DEEPSEEK_API_KEY 未配置");
      error.statusCode = 503;
      throw error;
    }
    const requestTimeoutMilliseconds = Number(timeoutMs ?? timeoutMilliseconds);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), requestTimeoutMilliseconds);
    try {
      const response = await fetchImpl(`${baseURL}/chat/completions`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          messages,
          temperature: 0,
          ...(maxTokens ? { max_tokens: maxTokens } : {}),
          ...(thinking === 'disabled' ? { thinking: { type: 'disabled' } } : {}),
          response_format: { type: "json_object" },
        }),
        signal: controller.signal,
      });
      if (!response.ok) {
        const error = new Error(`模型服务返回 ${response.status}`);
        error.statusCode = response.status;
        throw error;
      }
      const payload = await response.json();
      const content = payload?.choices?.[0]?.message?.content;
      if (typeof content !== "string") {
        const error = new Error("模型服务未返回正文");
        error.statusCode = 502;
        throw error;
      }
      return { content, usage: payload.usage ?? null, finishReason: payload?.choices?.[0]?.finish_reason };
    } finally {
      clearTimeout(timeout);
    }
  };
}
