const cloudFieldKeys = new Set(["school", "college", "major"]);
const formFieldKinds = new Set([
  "singleLineText", "multilineText", "date", "singleChoice", "multipleChoice",
]);
const explanationCanonicalKeys = new Set([
  "fullName", "englishName", "gender", "birthDate", "school", "college",
  "major", "studentID", "phone", "email", "address", "educationLevel",
  "employer",
]);
const profileCategories = new Set([
  "identity", "contact", "education", "course", "skill", "language",
  "certificate", "award", "project", "internship", "work", "campus",
  "volunteer", "selfIntroduction", "other",
]);
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = "ValidationError";
    this.statusCode = 400;
  }
}

function assert(condition, message) {
  if (!condition) {
    throw new ValidationError(message);
  }
}

function assertExactKeys(object, allowedKeys, path) {
  assert(object && typeof object === "object" && !Array.isArray(object), `${path} 必须是对象`);
  const unknown = Object.keys(object).filter((key) => !allowedKeys.includes(key));
  assert(unknown.length === 0, `${path} 含未知字段：${unknown.join(",")}`);
}

export function validateResolveRequest(body) {
  assertExactKeys(
    body,
    ["schemaVersion", "requestId", "templateId", "fields", "candidates"],
    "request",
  );
  assert([1, 2].includes(body.schemaVersion), "仅支持 schemaVersion=1或2");
  assert(uuidPattern.test(body.requestId), "requestId 必须是 UUID");
  assert(
    body.templateId === "competition-registration-v1",
    "templateId 不受支持",
  );
  assert(
    Array.isArray(body.fields) && body.fields.length >= 1 && body.fields.length <= 3,
    "fields 数量必须为 1–3",
  );
  assert(
    Array.isArray(body.candidates) &&
      body.candidates.length >= 1 &&
      body.candidates.length <= 30,
    "candidates 数量必须为 1–30",
  );

  const fieldKeys = new Set();
  const allowedByField = new Map();
  for (const [index, field] of body.fields.entries()) {
    assertExactKeys(field, ["key", "label", "allowedCandidateIds"], `fields[${index}]`);
    assert(cloudFieldKeys.has(field.key), `禁止向云端发送字段 ${field.key}`);
    assert(!fieldKeys.has(field.key), `字段 ${field.key} 重复`);
    fieldKeys.add(field.key);
    assert(typeof field.label === "string" && field.label.length <= 12, "字段标签无效");
    assert(
      Array.isArray(field.allowedCandidateIds) &&
        field.allowedCandidateIds.length >= 1 &&
        field.allowedCandidateIds.length <= 10,
      "allowedCandidateIds 数量无效",
    );
    assert(
      field.allowedCandidateIds.every((id) => uuidPattern.test(id)),
      "allowedCandidateIds 必须为 UUID",
    );
    allowedByField.set(field.key, new Set(field.allowedCandidateIds));
  }

  const candidateIDs = new Set();
  for (const [index, candidate] of body.candidates.entries()) {
    assertExactKeys(
      candidate,
      ["id", "value", "redactedContext", "localConfidence"],
      `candidates[${index}]`,
    );
    assert(uuidPattern.test(candidate.id), "candidate.id 必须为 UUID");
    assert(!candidateIDs.has(candidate.id), "candidate.id 重复");
    candidateIDs.add(candidate.id);
    assert(
      typeof candidate.value === "string" &&
        candidate.value.length >= 1 &&
        candidate.value.length <= 80,
      "candidate.value 长度无效",
    );
    assert(
      typeof candidate.redactedContext === "string" &&
        candidate.redactedContext.length <= 120,
      "redactedContext 过长",
    );
    assert(
      typeof candidate.localConfidence === "number" &&
        candidate.localConfidence >= 0 &&
        candidate.localConfidence <= 1,
      "localConfidence 必须在 0–1",
    );
  }

  for (const [key, allowedIDs] of allowedByField.entries()) {
    for (const id of allowedIDs) {
      assert(candidateIDs.has(id), `${key} 引用了不存在的候选 ID`);
    }
  }
  return { allowedByField, candidateIDs };
}

export function validateModelOutput(output, request) {
  assertExactKeys(output, ["resolutions"], "modelOutput");
  assert(Array.isArray(output.resolutions), "resolutions 必须是数组");
  assert(output.resolutions.length <= request.fields.length, "resolutions 数量过多");

  const fieldByKey = new Map(request.fields.map((field) => [field.key, field]));
  const seen = new Set();
  for (const [index, resolution] of output.resolutions.entries()) {
    assertExactKeys(
      resolution,
      ["fieldKey", "candidateId", "confidence", "reasonCode"],
      `resolutions[${index}]`,
    );
    assert(fieldByKey.has(resolution.fieldKey), "返回了未请求的字段");
    assert(!seen.has(resolution.fieldKey), "返回字段重复");
    seen.add(resolution.fieldKey);
    assert(
      fieldByKey
        .get(resolution.fieldKey)
        .allowedCandidateIds.includes(resolution.candidateId),
      "模型选择了白名单之外的候选 ID",
    );
    assert(
      typeof resolution.confidence === "number" &&
        resolution.confidence >= 0 &&
        resolution.confidence <= 1,
      "模型置信度无效",
    );
    assert(
      typeof resolution.reasonCode === "string" &&
        /^[A-Z0-9_]{2,40}$/.test(resolution.reasonCode),
      "reasonCode 格式无效",
    );
  }
  return output;
}

export function parseModelJSON(content) {
  assert(typeof content === "string", "模型正文必须是字符串");
  const trimmed = content
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "");
  try {
    return JSON.parse(trimmed);
  } catch {
    throw new ValidationError("模型返回的 JSON 无法解析");
  }
}

function assertOptionalText(value, maximumLength, path) {
  assert(
    value === undefined ||
      (typeof value === "string" && value.length >= 1 && value.length <= maximumLength),
    `${path} 无效`,
  );
}

export function validateExplainFieldsRequest(body) {
  assertExactKeys(body, ["schemaVersion", "requestId", "fields"], "request");
  assert([1, 2].includes(body.schemaVersion), "仅支持 schemaVersion=1或2");
  assert(uuidPattern.test(body.requestId), "requestId 必须是 UUID");
  assert(
    Array.isArray(body.fields) && body.fields.length >= 1 && body.fields.length <= 30,
    "fields 数量必须为 1–30",
  );
  const fieldIDs = new Set();
  for (const [index, field] of body.fields.entries()) {
    assertExactKeys(
      field,
      ["id", "label", "section", "instructions", "kind", "options"],
      `fields[${index}]`,
    );
    assert(
      typeof field.id === "string" &&
        /^[A-Za-z0-9._-]{1,80}$/.test(field.id) &&
        !fieldIDs.has(field.id),
      "field.id 无效或重复",
    );
    fieldIDs.add(field.id);
    assertOptionalText(field.label, 80, "field.label");
    assertOptionalText(field.section, 80, "field.section");
    assertOptionalText(field.instructions, 300, "field.instructions");
    assert(formFieldKinds.has(field.kind), "field.kind 无效");
    assert(Array.isArray(field.options) && field.options.length <= 30, "field.options 无效");
    const optionIDs = new Set();
    for (const [optionIndex, option] of field.options.entries()) {
      assertExactKeys(option, ["id", "label"], `options[${optionIndex}]`);
      assert(
        typeof option.id === "string" &&
          /^[A-Za-z0-9._-]{1,80}$/.test(option.id) &&
          !optionIDs.has(option.id),
        "option.id 无效或重复",
      );
      optionIDs.add(option.id);
      assert(typeof option.label === "string" && option.label.length >= 1 && option.label.length <= 80, "option.label 无效");
    }
    assert(
      field.label !== undefined ||
        field.section !== undefined ||
        field.instructions !== undefined ||
        field.options.length > 0,
      "字段没有可解释文本",
    );
  }
  return { fieldIDs };
}

export function validateExplainFieldsOutput(output, request) {
  assertExactKeys(output, ["explanations"], "modelOutput");
  assert(
    Array.isArray(output.explanations) &&
      output.explanations.length <= request.fields.length,
    "explanations 数量无效",
  );
  const requestedIDs = new Set(request.fields.map((field) => field.id));
  const seen = new Set();
  for (const [index, explanation] of output.explanations.entries()) {
    assertExactKeys(
      explanation,
      ["fieldId", "canonicalKey", "summary", "confidence", "reasonCode"],
      `explanations[${index}]`,
    );
    assert(
      requestedIDs.has(explanation.fieldId) && !seen.has(explanation.fieldId),
      "fieldId 未请求或重复",
    );
    seen.add(explanation.fieldId);
    assert(
      explanation.canonicalKey === null ||
        (explanationCanonicalKeys.has(explanation.canonicalKey) || (request.schemaVersion === 2 && extendedExplanationKeys.has(explanation.canonicalKey))),
      "canonicalKey 不在白名单",
    );
    assert(
      typeof explanation.summary === "string" && explanation.summary.length <= 80,
      "summary 无效",
    );
    assert(
      typeof explanation.confidence === "number" &&
        explanation.confidence >= 0 &&
        explanation.confidence <= 1,
      "confidence 无效",
    );
    assert(
      typeof explanation.reasonCode === "string" &&
        /^[A-Z0-9_]{2,40}$/.test(explanation.reasonCode),
      "reasonCode 无效",
    );
  }
  return output;
}

export function validateExtractProfileRequest(body) {
  assertExactKeys(body, ["schemaVersion", "requestId", "blocks"], "request");
  assert([1, 2].includes(body.schemaVersion), "仅支持 schemaVersion=1或2");
  assert(uuidPattern.test(body.requestId), "requestId 必须是 UUID");
  assert(
    Array.isArray(body.blocks) && body.blocks.length >= 1 && body.blocks.length <= 60,
    "blocks 数量必须为 1–60",
  );
  const ids = new Set();
  for (const [index, block] of body.blocks.entries()) {
    assertExactKeys(block, ["id", "text"], `blocks[${index}]`);
    assert(uuidPattern.test(block.id) && !ids.has(block.id), "block.id 无效或重复");
    ids.add(block.id);
    assert(typeof block.text === "string" && block.text.length >= 1 && block.text.length <= 2000, "block.text 长度无效");
  }
  return { blockById: new Map(body.blocks.map((block) => [block.id, block])) };
}

function normalized(value) {
  return value.replace(/\s+/gu, "");
}

export function validateExtractProfileOutput(output, request) {
  assertExactKeys(output, ["items"], "modelOutput");
  assert(Array.isArray(output.items) && output.items.length <= 80, "items 数量无效");
  const blockById = new Map(request.blocks.map((block) => [block.id, block]));
  for (const [index, item] of output.items.entries()) {
    validateExtractProfileItem(item, index, blockById);
  }
  return output;
}

function validateExtractProfileItem(item, index, blockById) {
  assertExactKeys(
    item,
    ["category", "fieldID", "label", "value", "components", "sourceBlockIDs", "confidence"],
    `items[${index}]`,
  );
  assert(profileCategories.has(item.category), "category 不在白名单");
  assert(typeof item.fieldID === "string" && /^[A-Za-z][A-Za-z0-9._-]{0,79}$/.test(item.fieldID), "fieldID 无效");
  assert(typeof item.label === "string" && item.label.length >= 1 && item.label.length <= 40, "label 无效");
  assert(typeof item.value === "string" && item.value.length >= 1 && item.value.length <= 2000, "value 无效");
  assert(item.components && typeof item.components === "object" && !Array.isArray(item.components), "components 无效");
  assert(Object.keys(item.components).length <= 12, "components 过多");
  assert(Array.isArray(item.sourceBlockIDs) && item.sourceBlockIDs.length >= 1 && item.sourceBlockIDs.length <= 12, "sourceBlockIDs 无效");
  const sourceTexts = item.sourceBlockIDs.map((id) => blockById.get(id)?.text).filter(Boolean);
  assert(sourceTexts.length === item.sourceBlockIDs.length, "引用了未知 block");
  const grounded = (value) => sourceTexts.some((text) => normalized(text).includes(normalized(value)));
  assert(grounded(item.value), "value 不存在于来源原文");
  for (const value of Object.values(item.components)) {
    assert(typeof value === "string" && value.length <= 1000 && grounded(value), "component 不存在于来源原文");
  }
  assert(typeof item.confidence === "number" && item.confidence >= 0 && item.confidence <= 1, "confidence 无效");
}

// A model can return several useful facts and one malformed fact in the same
// response. Keep the strict per-item safety boundary, but reject only the bad
// item so one hallucination cannot make the entire OCR page unavailable.
export function sanitizeExtractProfileOutput(output, request) {
  assertExactKeys(output, ["items"], "modelOutput");
  assert(Array.isArray(output.items) && output.items.length <= 80, "items 数量无效");
  const blockById = new Map(request.blocks.map((block) => [block.id, block]));
  const items = [];
  let rejectedItemCount = 0;
  for (const [index, item] of output.items.entries()) {
    try {
      validateExtractProfileItem(item, index, blockById);
      items.push(item);
    } catch (error) {
      if (!(error instanceof ValidationError)) throw error;
      rejectedItemCount += 1;
    }
  }
  return { items, rejectedItemCount };
}

export const extendedExplanationKeys = new Set(["skills", "certificates", "awards", "coreCourses", "projectName", "projectRole", "projectSummary", "selfIntroduction", "experienceHighlights"]);
