import Foundation

extension FlowStore {
    var aiSharingEntries: [ProfileAISharingEntry] {
        ProfileAISharing.entries(items: profileLibrary.profileItems ?? [],
            subjects: profileLibrary.subjects ?? [], records: profileLibrary.records ?? [])
    }

    func isAISharingAllowed(_ entry: ProfileAISharingEntry) -> Bool {
        ProfileAISharing.isAllowed(entry, grants: profileLibrary.aiSharingGrants ?? [:])
    }

    func aiSharingBlockReason(_ entry: ProfileAISharingEntry) -> String? {
        ProfileAISharing.blockedReason(for: entry, entries: aiSharingEntries,
            grants: profileLibrary.aiSharingGrants ?? [:])
    }

    /// This projection is shared by whole-form and single-field filling. Raw material,
    /// source excerpts and unrelated structured components never enter these snippets.
    var formPlanSources: [FormPlanSource] {
        ProfileAISharing.allowedEntries(aiSharingEntries, grants: profileLibrary.aiSharingGrants ?? [:])
            .enumerated().map { index, entry in
                FormPlanSource(id: "source-\(index + 1)", originID: "profile-item-\(entry.id.uuidString)",
                    title: "\(entry.personLabel) · \(entry.label)", originalText: entry.text,
                    text: entry.text, recordID: entry.recordID)
            }
    }

    func validateAIOutboundText(_ texts: [String]) throws {
        guard !isUpdatingAISharing, !aiSharingSaveFailed else {
            throw ModuleFailure.blocked("请先完成 AI 资料权限的保存。")
        }
        let entries = aiSharingEntries
        for text in texts {
            if let reason = ProfileAISharing.blockedReason(forText: text, entries: entries,
                grants: profileLibrary.aiSharingGrants ?? [:]) {
                throw ModuleFailure.blocked(reason)
            }
        }
    }

    func validateAIOutboundRequest(_ request: FormPlanRequest) throws {
        guard request.fields.allSatisfy({ field in
            field.id.range(of: #"^field-[1-9][0-9]*$"#, options: .regularExpression) != nil
                && field.options.allSatisfy { $0.id.range(of: #"^option-[1-9][0-9]*$"#, options: .regularExpression) != nil }
        }), request.sources.allSatisfy({ $0.id.range(of: #"^source-[1-9][0-9]*$"#, options: .regularExpression) != nil }) else {
            throw ModuleFailure.blocked("字段或资料编号已改变，请重新准备 AI 填写。")
        }
        try validateAIOutboundText(request.sources.map(\.text) + request.fields.flatMap {
            [$0.label, $0.section, $0.instructions] + $0.options.map(\.label)
        })
    }

    func validateCompositionPermissions(_ draft: AnswerCompositionDraft) throws {
        try ProfileAIRequestBoundary.validate(draft, allowedSources: formPlanSources)
        try validateAIOutboundText([draft.request.fieldLabel, draft.request.instructions] + draft.request.sources.map(\.text))
    }
}
