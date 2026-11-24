import Foundation
import SwiftData

extension FlowStore {
    func beginFormPlan(fieldID: String? = nil, in context: ModelContext) async {
        guard !isWorking, !isUpdatingAISharing, let document = snapshot?.generalForm else { return }
        snapshot?.generalForm?.planDraft = FormPlanDraft(fingerprint: document.fingerprint,
            structureVersion: document.structureVersion, sources: formPlanSources, targets: document.fields.enumerated().compactMap {
                guard fieldID == nil || $0.element.id == fieldID, !FormPlanRules.isProtected($0.element) else { return nil }
                return FormPlanRules.target($0.element, number: $0.offset + 1)
            }, sharingPolicyVersion: 1, scopeFieldID: fieldID)
        if let draft = snapshot?.generalForm?.planDraft { formPlanProgress = .init(draftID: draft.id) }
        await persist(in: context)
    }

    /// Refresh only a new, unsent draft; historical/frozen requests require explicit preparation.
    func refreshFormPlanSources() {
        guard !isWorking, !isUpdatingAISharing, var draft = snapshot?.generalForm?.planDraft,
              draft.sharingPolicyVersion == 1, draft.batches.isEmpty else { return }
        draft.sources = formPlanSources
        draft.lastAuthorizedAt = nil
        snapshot?.generalForm?.planDraft = draft
    }

    /// Editing is synchronous so a subsequent send cannot race a queued text-field mutation.
    func editFormPlan(_ edit: (inout FormPlanDraft) -> Void) {
        guard !isWorking, !isUpdatingAISharing, var draft = snapshot?.generalForm?.planDraft,
              draft.sharingPolicyVersion == 1, draft.batches.isEmpty else { return }
        edit(&draft)
        draft.lastAuthorizedAt = nil
        snapshot?.generalForm?.planDraft = draft
    }

    func toggleFormPlanSource(_ source: FormPlanSource) {
        guard formPlanSources.contains(source) else { return }
        editFormPlan { draft in
            if draft.sources.contains(where: { $0.originID == source.originID }) {
                draft.sources.removeAll { $0.originID == source.originID }
            } else {
                var added = source
                let number = draft.sources.compactMap { Int($0.id.replacingOccurrences(of: "source-", with: "")) }.max() ?? 0
                added.id = "source-\(number + 1)"
                draft.sources.append(added)
            }
        }
    }

    func selectAllFormPlanSources() {
        let available = formPlanSources
        editFormPlan { draft in
            var nextNumber = draft.sources.compactMap { Int($0.id.replacingOccurrences(of: "source-", with: "")) }.max() ?? 0
            for source in available where !draft.sources.contains(where: { $0.originID == source.originID }) {
                nextNumber += 1
                var added = source
                added.id = "source-\(nextNumber)"
                draft.sources.append(added)
            }
        }
    }

    func toggleFormPlanField(_ field: DynamicFormField) {
        guard !FormPlanRules.isProtected(field), let position = snapshot?.generalForm?.fields.firstIndex(where: { $0.id == field.id }) else { return }
        editFormPlan { draft in
            guard draft.scopeFieldID == nil || draft.scopeFieldID == field.id else { return }
            if draft.targets.contains(where: { $0.original.id == field.id }) { draft.targets.removeAll { $0.original.id == field.id } }
            else {
                draft.targets.append(FormPlanRules.target(field, number: position + 1))
                draft.targets.sort { (Int($0.id.dropFirst(6)) ?? 0) < (Int($1.id.dropFirst(6)) ?? 0) }
            }
        }
    }

    var formPlanIsCurrent: Bool {
        guard let document = snapshot?.generalForm, let draft = document.planDraft else { return false }
        return draft.sharingPolicyVersion == 1 && !aiSharingSaveFailed && !isUpdatingAISharing
            && ProfileAIRequestBoundary.sourcesAreCurrent(draft.sources, allowed: formPlanSources)
            && FormPlanRules.isCurrent(draft, document: document, sources: formPlanSources)
    }

    func formPlanTargetIsCurrent(_ target: FormPlanTarget) -> Bool {
        guard formPlanIsCurrent, let document = snapshot?.generalForm else { return false }
        return FormPlanRules.isTargetCurrent(target, document: document)
    }

    /// Only the explicit send/retry button enters this method. Restoration never calls it.
    func submitFormPlan(in context: ModelContext) async {
        guard !isWorking, !isUpdatingAISharing, let taskID = snapshot?.id, var draft = snapshot?.generalForm?.planDraft else { return }
        guard formPlanIsCurrent else { transientError = "资料或表格已改变，请重新准备整表填写。"; return }
        do {
            if draft.batches.isEmpty { draft.batches = try FormPlanRules.makeBatches(draft) }
            try ProfileAIRequestBoundary.validate(draft, allowedSources: formPlanSources)
            for batch in draft.batches where batch.response == nil {
                try FormPlanRules.validate(batch.request)
                try validateAIOutboundRequest(batch.request)
            }
        } catch { transientError = error.localizedDescription; return }
        await runFormPlan(draft: draft, taskID: taskID, mergeRound: nil, in: context)
    }

    /// A synthesis round sends AI draft text only after its own preview and tap.
    func submitFormPlanMerge(in context: ModelContext) async {
        guard !isWorking, !isUpdatingAISharing, let taskID = snapshot?.id, var draft = snapshot?.generalForm?.planDraft,
              !draft.batches.isEmpty, draft.batches.allSatisfy({ $0.response != nil }) else { return }
        guard formPlanIsCurrent else { transientError = "资料或表格已改变，请重新准备整表填写。"; return }
        do {
            if draft.mergeRounds?.last?.contains(where: { $0.response == nil }) != true {
                let next = try FormPlanRules.makeMergeBatches(draft)
                guard !next.isEmpty else { return }
                draft.mergeRounds = (draft.mergeRounds ?? []) + [next]
            }
            try ProfileAIRequestBoundary.validate(draft, allowedSources: formPlanSources)
            for batch in draft.mergeRounds!.last! where batch.response == nil {
                try FormPlanRules.validate(batch.request)
                try validateAIOutboundRequest(batch.request)
            }
        } catch { transientError = error.localizedDescription; return }
        await runFormPlan(draft: draft, taskID: taskID, mergeRound: draft.mergeRounds!.count - 1, in: context)
    }

    private func runFormPlan(draft initial: FormPlanDraft, taskID: UUID, mergeRound: Int?, in context: ModelContext) async {
        var draft = initial
        draft.lastAuthorizedAt = formPlanClock.now()
        snapshot?.generalForm?.planDraft = draft
        let batches = mergeRound.map { draft.mergeRounds![$0] } ?? draft.batches
        isWorking = true
        formPlanProgress = .init(draftID: draft.id, phase: .generating, totalBatches: batches.count,
            startedAt: formPlanClock.now(), completedBatches: batches.filter { $0.response != nil }.count)
        defer {
            isWorking = false
            formPlanProgress?.phase = .results
            formPlanProgress?.queueDeadline = nil
            formPlanProgress?.finishedAt = formPlanClock.now()
        }
        await persist(in: context)
        guard !hasUnsavedTaskChanges else { return }
        var consecutiveFailures = 0
        for (index, batch) in batches.enumerated() where batch.response == nil {
            if Task.isCancelled { break }
            guard snapshot?.id == taskID, snapshot?.generalForm?.planDraft?.id == draft.id, formPlanIsCurrent else { break }
            formPlanProgress?.batchNumber = index + 1
            formPlanProgress?.fieldIDs = batch.request.fields.map(\.id)
            formPlanProgress?.fieldNames = batch.request.fields.map(\.label)
            formPlanProgress?.phase = .generating
            var updated = batch
            updated.error = nil
            do {
                let response = try await queuedFormPlan(batch.request, taskID: taskID, draftID: draft.id)
                try Task.checkCancellation()
                guard snapshot?.id == taskID, snapshot?.generalForm?.planDraft?.id == draft.id, formPlanIsCurrent else {
                    transientError = "资料或答案已改变，返回结果未采用。"; break
                }
                var complete = FormPlanRules.sanitizeWireEvidence(response, for: batch.request)
                if mergeRound == nil { complete = FormPlanRules.validateOriginalEvidence(complete, batch: batch, draft: draft) }
                try FormPlanRules.validate(complete, for: batch.request)
                if mergeRound != nil { complete = FormPlanRules.remapMergeEvidence(complete, batch: batch) }
                for field in batch.request.fields where !complete.suggestions.contains(where: { $0.fieldId == field.id }) {
                    complete.suggestions.append(.init(fieldId: field.id, status: .missing, answer: nil,
                        selectedOptionIDs: [], evidence: [], reason: "本批未返回此字段，请补充资料后重新准备。", generated: false))
                }
                updated.response = complete
                consecutiveFailures = 0
                formPlanProgress?.completedBatches += 1
            } catch {
                guard snapshot?.id == taskID, snapshot?.generalForm?.planDraft?.id == draft.id else { break }
                updated.error = Task.isCancelled ? "请求已取消，重试前请再次核对。" : "本批未完成：\(error.localizedDescription)"
                consecutiveFailures += 1
                let stop = Task.isCancelled || error is CancellationError || Self.formPlanBlocked(error) || consecutiveFailures >= 2
                formPlanProgress?.notice = stop ? "第 \(index + 1) 批未完成，已停止；请核对后重试。"
                    : "第 \(index + 1) 批未完成，继续处理后续批次"
                saveFormPlanBatch(updated, index: index, mergeRound: mergeRound)
                await persist(in: context)
                if stop || hasUnsavedTaskChanges { break }
                continue
            }
            saveFormPlanBatch(updated, index: index, mergeRound: mergeRound)
            await persist(in: context)
            if hasUnsavedTaskChanges { break }
        }
    }

    private func saveFormPlanBatch(_ batch: FormPlanBatch, index: Int, mergeRound: Int?) {
        if let mergeRound { snapshot?.generalForm?.planDraft?.mergeRounds?[mergeRound][index] = batch }
        else { snapshot?.generalForm?.planDraft?.batches[index] = batch }
    }

    private static func formPlanBlocked(_ error: Error) -> Bool {
        if let failure = error as? ModuleFailure, case .blocked = failure { return true }
        if let failure = error as? FieldExplanationRequestError {
            switch failure {
            case .blocked, .blockedContent, .pendingReview, .noSendableFields: return true
            default: break
            }
        }
        return false
    }

    private func queuedFormPlan(_ request: FormPlanRequest, taskID: UUID, draftID: UUID) async throws -> FormPlanResponse {
        var waits = 0
        while true {
            try Task.checkCancellation()
            guard snapshot?.id == taskID, snapshot?.generalForm?.planDraft?.id == draftID, formPlanIsCurrent else {
                throw ModuleFailure.blocked("资料或答案已改变，请重新准备整表填写。")
            }
            do {
                guard let current = snapshot?.generalForm?.planDraft else {
                    throw ModuleFailure.blocked("请重新准备 AI 填写。")
                }
                try ProfileAIRequestBoundary.validate(current, allowedSources: formPlanSources)
                try validateAIOutboundRequest(request)
                return try await formPlanner.plan(request)
            }
            catch {
                // Only a typed pre-model admission refusal can be resent automatically.
                guard let failure = error as? FieldExplanationRequestError,
                      case .retryable(_, beforeModel: true) = failure, waits < 3 else { throw error }
                waits += 1
                let now = formPlanClock.now()
                let deadline = Date(timeIntervalSince1970: (floor(now.timeIntervalSince1970 / 60) + 1) * 60 + 2)
                formPlanProgress?.phase = .queued
                formPlanProgress?.queueDeadline = deadline
                try await formPlanClock.sleep(deadline.timeIntervalSince(now))
                try Task.checkCancellation()
                formPlanProgress?.queueDeadline = nil
                formPlanProgress?.phase = .generating
            }
        }
    }

    func formPlanFieldStatus(_ target: FormPlanTarget, draft: FormPlanDraft) -> String {
        if draft.adoptedFieldIDs.contains(target.id) { return "已采用" }
        if !formPlanTargetIsCurrent(target) { return "已失效" }
        if target.field.mode == .manual { return "需本人填写" }
        if let result = FormPlanRules.finalSuggestion(draft, target: target) {
            switch result.status {
            case .suggested: return "可采用"
            case .missing: return "缺资料"
            case .conflict: return "冲突"
            case .manual: return "需本人填写"
            }
        }
        if FormPlanRules.needsMerge(draft, target: target) { return "等待长文合成与再次授权" }
        if let progress = formPlanProgress, progress.draftID == draft.id, progress.fieldIDs.contains(target.id) {
            if progress.phase == .generating { return "生成中" }
            if progress.phase == .queued { return "排队中" }
        }
        let batches = (draft.mergeRounds?.last ?? draft.batches).filter { $0.request.fields.contains { $0.id == target.id } }
        if batches.contains(where: { $0.error != nil && $0.response == nil }) { return "未完成，待重试" }
        return "排队中"
    }

    func adoptFormPlan(_ fieldIDs: Set<String>, editedAnswer: String? = nil, individually: Bool = false, in context: ModelContext) async {
        guard !isWorking, formPlanIsCurrent, var document = snapshot?.generalForm, var draft = document.planDraft else {
            transientError = "资料或答案已改变，请重新准备整表填写。"; return
        }
        for target in draft.targets where fieldIDs.contains(target.id) && !draft.adoptedFieldIDs.contains(target.id) {
            guard let index = document.fields.firstIndex(where: { $0.id == target.original.id }),
                  let result = FormPlanRules.finalSuggestion(draft, target: target),
                  FormPlanRules.canAdopt(target, current: document.fields[index], result: result, batch: !individually) else { continue }
            let value = individually ? editedAnswer ?? result.answer : result.answer
            if document.fields[index].options.isEmpty {
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      value.utf16.count <= min(target.field.maximumCharacters ?? 8000, 8000) else {
                    transientError = "答案为空或超过字数限制，请修改。"; continue
                }
            }
            let records = Set(result.evidence.compactMap { evidence in
                FormPlanRules.source(for: evidence, targetID: target.id, draft: draft)?.recordID
            })
            let sources = result.evidence.compactMap { evidence -> FormPlanAnswerSource? in
                guard let source = FormPlanRules.source(for: evidence, targetID: target.id, draft: draft) else { return nil }
                return FormPlanAnswerSource(title: source.title, quote: evidence.quote, originID: source.originID)
            }
            let optionIDs = result.selectedOptionIDs.compactMap { id -> String? in
                guard let position = target.field.options.firstIndex(where: { $0.id == id }), target.original.options.indices.contains(position) else { return nil }
                return target.original.options[position].id
            }
            document.fields[index].answer = PersonalAnswer(value: value, selectedOptionIDs: optionIDs,
                sourceRecordIDs: Array(records), confirmationState: .confirmed, modifiedByUser: true,
                reviewReasons: result.generated ? ["用户已核对 AI 撰写草稿"] : nil, planSources: sources)
            draft.adoptedFieldIDs.insert(target.id)
        }
        document.planDraft = draft
        snapshot?.generalForm = document
        await persist(in: context)
    }
}
