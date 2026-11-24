#!/bin/bash
set -euo pipefail
# 在 macOS 运行真实 Word 引擎，不启动模拟器；只使用调试集。
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORD_WORK="${1:?Usage: verify_docx_engine.sh EMPTY_OUTPUT_DIRECTORY}"
mkdir -p "$WORD_WORK"
WORD_WORK="$(cd "$WORD_WORK" && pwd)"
if [ -e "$WORD_WORK/checks" ]; then
  echo "Please choose a fresh output directory." >&2
  exit 1
fi
# 从生产文件提取模型与请求构造器，排除依赖 App 网络配置的 actor。
# 未复制或重写受测逻辑；下方编译引擎、匹配器及领域类型的原始源文件。
sed '/^actor RelayFieldExplanationService/,$d' "$REPO_ROOT/BiaoXia/Services/FieldExplanationService.swift" > "$WORD_WORK/ExplanationModels.swift"
cat > "$WORD_WORK/Runner.swift" <<'SWIFT'
import Foundation
@main struct Runner {
    static func main() async throws {
        let count = try await DOCXEngineChecks.run(repository: URL(fileURLWithPath: CommandLine.arguments[1]), output: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("DOCX engine: \(count) checks passed")
        let materials = try DOCXMaterialChecks.run(repository: URL(fileURLWithPath: CommandLine.arguments[1]), output: URL(fileURLWithPath: CommandLine.arguments[2]).appending(path: "materials"))
        print("DOCX materials: \(materials) checks passed")
        let planning = try await FormPlanningChecks.run(repository: URL(fileURLWithPath: CommandLine.arguments[1]), output: URL(fileURLWithPath: CommandLine.arguments[2]).appending(path: "planning"))
        print("Form planning: \(planning) checks passed")
        let sharing = try await ProfileAISharingChecks.run()
        print("Profile AI sharing: \(sharing) checks passed")
    }
}
SWIFT
xcrun swiftc -swift-version 6 -D DOCX_STANDALONE -module-cache-path "$WORD_WORK/module-cache" \
  "$REPO_ROOT/BiaoXia/Core/DomainModels.swift" \
  "$REPO_ROOT/BiaoXia/Core/PersonalProfile.swift" \
  "$REPO_ROOT/BiaoXia/Core/ProfileAISharing.swift" \
  "$REPO_ROOT/BiaoXia/Core/ProfileAIRequestBoundary.swift" \
  "$REPO_ROOT/BiaoXia/Core/GeneralFormContracts.swift" \
  "$REPO_ROOT/BiaoXia/Core/FormAssistanceModels.swift" \
  "$REPO_ROOT/BiaoXia/Core/FormPlanningModels.swift" \
  "$REPO_ROOT/BiaoXia/Core/FormPlanBatchRules.swift" \
  "$REPO_ROOT/BiaoXia/Services/FormRecordMatcher.swift" \
  "$WORD_WORK/ExplanationModels.swift" \
  "$REPO_ROOT/BiaoXia/Services/LocalRuleAnswerMatcher.swift" \
  "$REPO_ROOT/BiaoXia/Services/WordPackage.swift" \
  "$REPO_ROOT/BiaoXia/Services/DOCXFormEngine.swift" \
  "$REPO_ROOT/BiaoXia/Services/DOCXMaterialReader.swift" \
  "$REPO_ROOT/BiaoXia/Services/FieldExtractionService.swift" \
  "$REPO_ROOT/BiaoXiaTests/DOCXEngineChecks.swift" \
  "$REPO_ROOT/BiaoXiaTests/DOCXMaterialChecks.swift" \
  "$REPO_ROOT/BiaoXiaTests/FormPlanningChecks.swift" \
  "$REPO_ROOT/BiaoXiaTests/ProfileAISharingChecks.swift" \
  "$WORD_WORK/Runner.swift" -o "$WORD_WORK/checks"
"$WORD_WORK/checks" "$REPO_ROOT" "$WORD_WORK/artifacts"
