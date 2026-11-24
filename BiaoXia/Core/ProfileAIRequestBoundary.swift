import Foundation

/// Checks saved drafts as well as freshly prepared requests. A UI selection is never
/// sufficient authority to reuse old OCR, edited snippets, or previously frozen batches.
enum ProfileAIRequestBoundary {
    static func sourcesAreCurrent(_ selected: [FormPlanSource], allowed: [FormPlanSource]) -> Bool {
        Set(selected.map(\.originID)).count == selected.count
            && Set(selected.map(\.id)).count == selected.count
            && selected.allSatisfy { source in
                source.id.range(of: #"^source-[1-9][0-9]*$"#, options: .regularExpression) != nil && allowed.contains {
                    $0.originID == source.originID && $0.originalText == source.originalText
                        && $0.text == source.text && $0.recordID == source.recordID
                }
            }
    }

    static func validate(_ draft: FormPlanDraft, allowedSources: [FormPlanSource]) throws {
        try require(draft.sharingPolicyVersion == 1 && !draft.sources.isEmpty
            && sourcesAreCurrent(draft.sources, allowed: allowedSources))
        if !draft.batches.isEmpty {
            let expected = try FormPlanRules.makeBatches(draft)
            try validate(draft.batches, expected: expected)
        }
        var replay = draft
        replay.mergeRounds = nil
        for round in draft.mergeRounds ?? [] {
            let expected = try FormPlanRules.makeMergeBatches(replay)
            try require(!expected.isEmpty)
            try validate(round, expected: expected)
            replay.mergeRounds = (replay.mergeRounds ?? []) + [round]
        }
    }

    static func validate(_ draft: AnswerCompositionDraft, allowedSources: [FormPlanSource]) throws {
        guard let sources = draft.aiSources else { throw invalidDraft }
        try require(!sources.isEmpty && sourcesAreCurrent(sources, allowed: allowedSources))
        try require(draft.request.sources == sources.map { AnswerSourceSnippet(id: $0.id, text: $0.text) })
    }

    private static func validate(_ actual: [FormPlanBatch], expected: [FormPlanBatch]) throws {
        try require(actual.count == expected.count)
        for (saved, rebuilt) in zip(actual, expected) {
            // Request UUIDs are stable for retries; rebuilding is only for content comparison.
            try require(saved.request.schemaVersion == rebuilt.request.schemaVersion
                && saved.request.fields == rebuilt.request.fields && saved.request.sources == rebuilt.request.sources
                && saved.sourceMembers == rebuilt.sourceMembers && saved.sourceOrigins == rebuilt.sourceOrigins
                && saved.evidenceLineage == rebuilt.evidenceLineage)
        }
    }

    private static var invalidDraft: ModuleFailure {
        .blocked("AI 可用资料或发送内容已改变，请按当前资料项权限重新准备填写。")
    }
    private static func require(_ condition: Bool) throws {
        if !condition { throw invalidDraft }
    }
}
