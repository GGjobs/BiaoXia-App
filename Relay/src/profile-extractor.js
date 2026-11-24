import {
  parseModelJSON,
  sanitizeExtractProfileOutput,
  ValidationError,
  validateExtractProfileRequest,
} from "./schema.js";

const systemPrompt = `你是学生材料开放信息整理器。只能从给定 OCR blocks 原文抽取信息，禁止补写、总结、润色或推断。
身份、联系方式和基础学籍已由设备本地完成，本次不要返回 identity、contact 或 education。
category 只能使用：course, skill, language, certificate, award, project, internship, work, campus, volunteer, selfIntroduction, other。
每个 value 以及 components 中的每个值必须逐字出现在至少一个 sourceBlockIDs 对应的 block.text 中；敏感占位符必须原样保留。
最多返回 12 条，只选择对后续填表复用最有价值且来源明确的内容。
只输出 JSON：{"items":[{"category":"project","fieldID":"project","label":"项目经历","value":"原文片段","components":{},"sourceBlockIDs":["UUID"],"confidence":0.9}]}。没有可靠内容时返回 {"items":[]}。`;

export async function extractProfileWithFallback(request, options) {
  validateExtractProfileRequest(request);
  const primaryModel = options.primaryModel ?? "deepseek-flash";
  const fallbackModel = options.fallbackModel ?? "deepseek-v4-pro";
  const messages = [
    { role: "system", content: systemPrompt },
    { role: "user", content: JSON.stringify({ blocks: request.blocks }) },
  ];

  let attempts = 0;
  let lastError;
  let safeEmptyResult;
  let safeValidationFailure;
  let correctionReminder;
  for (const model of [primaryModel, fallbackModel]) {
    attempts += 1;
    try {
      const attemptMessages = correctionReminder
        ? [...messages, { role: "user", content: correctionReminder }]
        : messages;
      const result = await options.callModel({
        model,
        messages: attemptMessages,
        timeoutMs: 30_000,
      });
      const parsed = parseModelJSON(result.content);
      const validated = sanitizeExtractProfileOutput(parsed, request);
      if (validated.items.length === 0 && validated.rejectedItemCount > 0) {
        safeEmptyResult = { model, usage: result.usage };
        lastError = new Error("模型返回项未通过逐字溯源校验");
        continue;
      }
      return {
        requestId: request.requestId,
        modelUsed: model,
        items: validated.items,
        usage: result.usage,
        attempts,
      };
    } catch (error) {
      lastError = error;
      if (error instanceof ValidationError) {
        safeValidationFailure = { model };
        correctionReminder = "上次输出未通过格式或逐字溯源校验。请只返回包含 items 数组的 JSON；每项字段必须完整，且 value 与 components 必须逐字来自对应 block。";
      }
    }
  }
  // Invalid facts have already been rejected locally. Returning an empty,
  // schema-valid result is safer and more useful than turning a recoverable
  // extraction miss into a 502 that blocks the whole profile workflow.
  if (safeEmptyResult || safeValidationFailure) {
    const safeResult = safeEmptyResult ?? safeValidationFailure;
    return {
      requestId: request.requestId,
      modelUsed: safeResult.model,
      items: [],
      usage: safeResult.usage,
      attempts,
    };
  }
  const error = new Error("所有模型信息整理尝试均失败");
  error.name = "ModelExtractionError";
  error.statusCode = 502;
  error.cause = lastError;
  throw error;
}
