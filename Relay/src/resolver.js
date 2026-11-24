import {
  parseModelJSON,
  validateModelOutput,
  validateResolveRequest,
} from "./schema.js";

const systemPrompt = `你是表格字段消歧器。你只能为每个字段从 allowedCandidateIds 中选择一个 candidateId。
禁止生成、改写或拼接候选值。没有足够依据时可以不返回该字段。
只输出 JSON：{"resolutions":[{"fieldKey":"school","candidateId":"UUID","confidence":0.8,"reasonCode":"CONTEXT_MATCH"}]}`;

function userPrompt(request) {
  return JSON.stringify({
    templateId: request.templateId,
    fields: request.fields,
    candidates: request.candidates,
  });
}

export async function resolveWithFallback(request, options) {
  validateResolveRequest(request);
  const primaryModel = options.primaryModel ?? "deepseek-flash";
  const fallbackModel = options.fallbackModel ?? "deepseek-v4-pro";
  const baseMessages = [
    { role: "system", content: systemPrompt },
    { role: "user", content: userPrompt(request) },
  ];

  let primaryContent = "";
  try {
    const result = await options.callModel({
      model: primaryModel,
      messages: baseMessages,
    });
    primaryContent = result.content;
    const parsed = parseModelJSON(result.content);
    const validated = validateModelOutput(parsed, request);
    return {
      requestId: request.requestId,
      modelUsed: primaryModel,
      resolutions: validated.resolutions,
      usage: result.usage,
      attempts: 1,
    };
  } catch (firstError) {
    try {
      const correctionMessages = [
        ...baseMessages,
        { role: "assistant", content: primaryContent || "{}" },
        {
          role: "user",
          content:
            "上一次输出未通过 JSON/白名单校验。只修正格式，并确保 candidateId 来自对应 allowedCandidateIds。",
        },
      ];
      const result = await options.callModel({
        model: primaryModel,
        messages: correctionMessages,
      });
      const parsed = parseModelJSON(result.content);
      const validated = validateModelOutput(parsed, request);
      return {
        requestId: request.requestId,
        modelUsed: primaryModel,
        resolutions: validated.resolutions,
        usage: result.usage,
        attempts: 2,
      };
    } catch (correctionError) {
      try {
        const result = await options.callModel({
          model: fallbackModel,
          messages: baseMessages,
        });
        const parsed = parseModelJSON(result.content);
        const validated = validateModelOutput(parsed, request);
        return {
          requestId: request.requestId,
          modelUsed: fallbackModel,
          resolutions: validated.resolutions,
          usage: result.usage,
          attempts: 3,
        };
      } catch (fallbackError) {
        const error = new Error("所有模型消歧尝试均失败");
        error.name = "ModelResolutionError";
        error.statusCode = 502;
        error.cause = fallbackError;
        throw error;
      }
    }
  }
}
