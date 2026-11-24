import Foundation

protocol AIResolving: Sendable {
    func resolve(
        candidates: [FieldCandidate],
        blocks: [OCRBlock],
        resolvedFields: [ResolvedField],
        materials: [MaterialAsset]
    ) async throws
}

protocol ProfileAIExtracting: Sendable {
    func extract(
        blocks: [OCRBlock],
        resolvedFields: [ResolvedField]
    ) async throws
}

// T04：旧服务只保留拒绝入口，兼容意外遗留调用。这里不保存 session、配置或个人值，
// 不创建 URLRequest；授权标记不能重新开启个人资料出站。
enum PersonalDataCloudDisabled: Error, LocalizedError {
    case disabled
    var errorDescription: String? { "个人资料云端处理已停用，请在本机核对信息。" }
}

actor RelayAIResolutionService: AIResolving {
    func resolve(candidates: [FieldCandidate], blocks: [OCRBlock],
                 resolvedFields: [ResolvedField], materials: [MaterialAsset]) async throws {
        throw PersonalDataCloudDisabled.disabled
    }
}

actor RelayProfileExtractionService: ProfileAIExtracting {
    func extract(blocks: [OCRBlock], resolvedFields: [ResolvedField]) async throws {
        throw PersonalDataCloudDisabled.disabled
    }
}
