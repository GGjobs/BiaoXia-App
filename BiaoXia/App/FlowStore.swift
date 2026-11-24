import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class FlowStore {
    var snapshot: FillTaskSnapshot?
    var activeRecord: FillTaskRecord?
    var transientError: String?
    // Persisted task state is independent of dismissible alerts.
    private(set) var hasUnsavedTaskChanges = false
    var isFormImportPresented = false
    var isWorking = false
    private(set) var isUpdatingAISharing = false
    private(set) var aiSharingSaveFailed = false
    var formPlanProgress: FormPlanProgress?
    var profile: PersonalProfile = .empty
    var profileLibrary: ProfileLibrarySnapshot = .empty()
    var isProfileLibraryPresented = false

    private let fileStore: any TaskFileStoring
    private let profileStore: any ProfileStoring
    private let profileLibraryStore: any ProfileLibraryStoring
    private let taskOCRService: (any OCRServing)?
    private let profileOCRService: any OCRServing
    private let extractor: any FieldExtracting
    private let profileItemExtractor: any ProfileItemExtracting
    private let pdfExporter: any PDFExporting
    private let formParser: any FormParsing
    private let answerMatcher: any AnswerMatching
    private let formWriter: any FormWriting
    private let formPreflighter: any FormPreflighting
    private let regionAdjuster: any PDFRegionAdjusting
    private let fieldExplanationSubmitter: (any ReviewedFieldExplanationSubmitting)?
    private let answerComposer: (any AnswerComposing)?
    let formPlanClock: FormPlanClock
    let formPlanner: any FormPlanning
    private let explanationRequestBuilder: FieldExplanationRequestBuilder

    init(
        fileStore: any TaskFileStoring = TaskFileStore.shared,
        profileStore: any ProfileStoring = PersonalProfileStore.shared,
        profileLibraryStore: any ProfileLibraryStoring = ProfileLibraryStore.shared,
        ocrService: (any OCRServing)? = nil,
        profileOCRService: (any OCRServing)? = nil,
        extractor: any FieldExtracting = RuleBasedFieldExtractor(),
        profileItemExtractor: any ProfileItemExtracting = RuleBasedProfileItemExtractor(),
        pdfExporter: (any PDFExporting)? = nil,
        formParser: any FormParsing = GeneralFormEngine(),
        answerMatcher: any AnswerMatching = LocalRuleAnswerMatcher(),
        formWriter: any FormWriting = GeneralFormEngine(),
        formPreflighter: any FormPreflighting = GeneralFormEngine(),
        regionAdjuster: any PDFRegionAdjusting = PDFFormEngine(),
        fieldExplanationSubmitter: (any ReviewedFieldExplanationSubmitting)? = nil,
        answerComposer: (any AnswerComposing)? = nil,
        formPlanner: any FormPlanning = ConfiguredFormPlanningService(),
        formPlanClock: FormPlanClock = FormPlanClock(),
        explanationRequestBuilder: FieldExplanationRequestBuilder = FieldExplanationRequestBuilder()
    ) {
        self.fileStore = fileStore
        self.profileStore = profileStore
        self.profileLibraryStore = profileLibraryStore
        self.taskOCRService = ocrService
        self.profileOCRService = profileOCRService
            ?? VisionOCRService(fileResolver: profileLibraryStore)
        self.extractor = extractor
        self.profileItemExtractor = profileItemExtractor
        self.pdfExporter = pdfExporter ?? PDFExportService(fileStore: fileStore)
        self.formParser = formParser
        self.answerMatcher = answerMatcher
        self.formWriter = formWriter
        self.formPreflighter = formPreflighter
        self.regionAdjuster = regionAdjuster
        self.fieldExplanationSubmitter = fieldExplanationSubmitter
        self.answerComposer = answerComposer
        self.formPlanner = formPlanner
        self.formPlanClock = formPlanClock
        self.explanationRequestBuilder = explanationRequestBuilder
    }

    func loadProfile() async {
        do {
            profile = try await profileStore.load()
        } catch {
            profile = .empty
            transientError = "无法载入个人信息：\(error.localizedDescription)"
        }
        do {
            profileLibrary = try await profileLibraryStore.load()
            if recoverProfileForLocalReview() {
                do {
                    try await persistProfileLibrary()
                } catch {
                    // 保存失败时继续保留已读入的资料，不能让迁移失败变成空信息库。
                    transientError = "本地恢复结果暂未保存，原文件已保留；请稍后重试保存。"
                }
            }
            if (profileLibrary.profileItems ?? []).isEmpty, profile.hasInformation {
                profileLibrary.profileItems = profile.informationItems
                try? await persistProfileLibrary()
            }
        } catch {
            profileLibrary = .empty()
            transientError = "无法迁移个人材料库，原文件已保留；请先备份后再尝试恢复：\(error.localizedDescription)"
        }
        let environment = ProcessInfo.processInfo.environment
        if environment["BIAOXIA_UI_TEST_EMPTY_PROFILE"] == "1" {
            profile = .empty
        } else if let fixture = environment["BIAOXIA_UI_TEST_PROFILE_JSON"],
                  let data = fixture.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(PersonalProfile.self, from: data) {
            profile = decoded
            // The fictional UI fixture must enter the same item-permission boundary as a
            // normally saved profile; injecting a profile never grants cloud access.
            profileLibrary.profileItems = decoded.informationItems
            profileLibrary.subjects = decoded.subjects ?? []
            profileLibrary.aiSharingGrants = [:]
            synchronizeProfileRecords(from: profileLibrary.profileItems ?? [])
        }
    }

    func saveProfile(_ updated: PersonalProfile) async {
        do {
            var normalized = updated
            normalized.schemaVersion = PersonalProfile.currentSchemaVersion
            normalized.evidence = FieldKey.allCases.map { key in
                let prior = profile.evidence?.first(where: { $0.key == key })
                let didChange = profile.value(for: key) != updated.value(for: key)
                return ProfileFieldEvidence(
                    key: key,
                    confidence: didChange ? 1 : (prior?.confidence ?? 1),
                    resolvedByAI: didChange ? false : (prior?.resolvedByAI ?? false),
                    modifiedByUser: didChange || prior?.modifiedByUser == true,
                    sources: didChange ? [] : (prior?.sources ?? [])
                )
            }
            var items = normalized.informationItems
            for key in FieldKey.allCases {
                let value = normalized.value(for: key)
                if let index = items.firstIndex(where: { $0.fieldID == key.rawValue }) {
                    items[index].value = value
                    items[index].confidence = 1
                    items[index].state = .confirmed
                    items[index].modifiedByUser = true
                    items[index].sources = []
                    items[index].updatedAt = .now
                } else if !value.isEmpty {
                    items.append(ProfileItem(
                        category: key.profileCategory,
                        fieldID: key.rawValue,
                        label: key.label,
                        value: value,
                        confidence: 1,
                        state: .confirmed,
                        sensitivity: key.sensitivity,
                        modifiedByUser: true
                    ))
                }
            }
            normalized.items = items.filter { !$0.value.isEmpty }
            try await profileStore.save(normalized)
            profile = normalized
            profileLibrary.profileItems = normalized.items
            try? await persistProfileLibrary()
        } catch {
            transientError = "无法保存个人信息：\(error.localizedDescription)"
        }
    }

    func createTask(in context: ModelContext) async {
        guard !isWorking else { return }
        guard profile.hasInformation else {
            transientError = BiaoXiaError.incompleteProfile.localizedDescription
            isProfileLibraryPresented = true
            return
        }
        var newSnapshot = FillTaskSnapshot.empty(profile: profile)
        newSnapshot.formValues = makeFormValues(from: profile.informationItems)
        let record = FillTaskRecord(snapshot: newSnapshot)
        context.insert(record)
        snapshot = newSnapshot
        activeRecord = record
        await persist(in: context)
    }

    func openProfileLibrary() {
        transientError = nil
        isProfileLibraryPresented = true
    }

    func closeProfileLibrary() {
        isProfileLibraryPresented = false
        transientError = nil
    }

    func clearProfileInformation() async {
        guard !isWorking else { return }
        isWorking = true
        transientError = nil
        defer { isWorking = false }

        // Clear the confirmed profile first so it can no longer be reused by a new task.
        do {
            try await profileStore.save(.empty)
            profile = .empty
        } catch {
            transientError = "无法清空个人信息：\(error.localizedDescription)"
            return
        }

        do {
            var materialsThatCouldNotBeDeleted: [MaterialAsset] = []
            for material in profileLibrary.materials {
                do {
                    try await profileLibraryStore.deleteMaterial(material)
                } catch {
                    materialsThatCouldNotBeDeleted.append(material)
                }
            }

            var clearedLibrary = ProfileLibrarySnapshot.empty(
                workspaceID: profileLibrary.workspaceID
            )
            if !materialsThatCouldNotBeDeleted.isEmpty {
                clearedLibrary.materials = materialsThatCouldNotBeDeleted.map { material in
                    var copy = material
                    copy.status = .pending
                    return copy
                }
                clearedLibrary.status = .imported
            }
            try await profileLibraryStore.save(clearedLibrary)

            profileLibrary = clearedLibrary
            if !materialsThatCouldNotBeDeleted.isEmpty {
                transientError = "个人信息已清空，但有 \(materialsThatCouldNotBeDeleted.count) 份材料文件无法删除，请重试。"
            }
        } catch {
            transientError = "个人信息已清空，但材料库未能完全清空：\(error.localizedDescription)"
        }
    }

    func importProfileMaterials(from urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isWorking = true
        transientError = nil
        defer { isWorking = false }
        do {
            for url in urls {
                profileLibrary.materials.append(
                    try await profileLibraryStore.importMaterial(from: url)
                )
            }
            resetProfileRecognition()
            try await persistProfileLibrary()
        } catch {
            transientError = error.localizedDescription
        }
    }

    func renameProfileMaterial(_ material: MaterialAsset, to displayName: String) async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await profileLibraryStore.renameMaterial(id: material.id, to: trimmed)
            guard let index = profileLibrary.materials.firstIndex(where: { $0.id == material.id }) else {
                return
            }
            profileLibrary.materials[index].displayName = trimmed
            if var evidence = profile.evidence {
                for evidenceIndex in evidence.indices {
                    for sourceIndex in evidence[evidenceIndex].sources.indices
                    where evidence[evidenceIndex].sources[sourceIndex].materialID == material.id {
                        evidence[evidenceIndex].sources[sourceIndex].materialName = trimmed
                    }
                }
                profile.evidence = evidence
                try await profileStore.save(profile)
            }
            updateMaterialName(in: &profileLibrary.profileItems, materialID: material.id, name: trimmed)
            updateMaterialName(in: &profileLibrary.pendingItems, materialID: material.id, name: trimmed)
            if profile.items != nil {
                updateMaterialName(in: &profile.items, materialID: material.id, name: trimmed)
                try await profileStore.save(profile)
            }
            try await persistProfileLibrary()
        } catch {
            transientError = "无法重命名材料：\(error.localizedDescription)"
        }
    }

    func deleteProfileMaterial(_ material: MaterialAsset) async {
        isWorking = true
        transientError = nil
        defer { isWorking = false }
        do {
            try await profileLibraryStore.deleteMaterial(material)
            profileLibrary.materials.removeAll { $0.id == material.id }
            profileLibrary.ocrBlocks.removeAll { $0.materialID == material.id }
            let extracted = extractor.extract(from: profileLibrary.ocrBlocks)
            profileLibrary.candidates = extracted.candidates
            profileLibrary.resolvedFields = extracted.resolved
            resetProfileRecognition()

            if var evidence = profile.evidence {
                for index in evidence.indices {
                    evidence[index].sources.removeAll { $0.materialID == material.id }
                    if evidence[index].sources.isEmpty && !evidence[index].modifiedByUser {
                        profile.setValue("", for: evidence[index].key)
                    }
                }
                profile.evidence = evidence
                try await profileStore.save(profile)
            }
            removeMaterialSource(in: &profileLibrary.profileItems, materialID: material.id)
            removeMaterialSource(in: &profileLibrary.pendingItems, materialID: material.id)
            if profile.items != nil {
                removeMaterialSource(in: &profile.items, materialID: material.id)
                profile.synchronizeLegacyFields()
                profile.records = makeProfileRecords(from: profile.items ?? [],
                    subjects: profile.subjects ?? [], existing: profile.records ?? [])
                try await profileStore.save(profile)
            }
            try await persistProfileLibrary()
        } catch {
            transientError = "无法删除材料：\(error.localizedDescription)"
        }
    }

    func startProfileRecognition() async {
        guard !profileLibrary.materials.isEmpty else {
            transientError = BiaoXiaError.noMaterials.localizedDescription
            return
        }
        guard !isWorking else { return }
        isWorking = true
        let resumableBlocks = [.recognizing, .failed].contains(profileLibrary.status)
            ? profileLibrary.ocrBlocks
            : []
        profileLibrary.status = .recognizing
        profileLibrary.lastError = nil
        profileLibrary.ocrBlocks = resumableBlocks
        profileLibrary.candidates = []
        profileLibrary.resolvedFields = PersonalProfile.empty.resolvedFields
        profileLibrary.recognitionCompletedPages = Set(resumableBlocks.map {
            "\($0.materialID.uuidString.lowercased()):\($0.pageIndex)"
        }).count
        profileLibrary.recognitionTotalPages = profileLibrary.materials.reduce(0) {
            $0 + max(1, $1.pageCount)
        }
        try? await persistProfileLibrary()

        do {
            let blocks = try await profileOCRService.recognize(
                materials: profileLibrary.materials,
                existingBlocks: resumableBlocks
            ) { [weak self] completed, total, blocks in
                await self?.updateProfileRecognitionProgress(
                    completed: completed,
                    total: total,
                    blocks: blocks
                )
            }
            let extracted = extractor.extract(from: blocks)
            profileLibrary.ocrBlocks = blocks
            profileLibrary.candidates = extracted.candidates
            profileLibrary.resolvedFields = attachSources(
                to: extracted.resolved,
                in: profileLibrary
            )
            let localItems = profileItems(from: profileLibrary.resolvedFields)
                + profileItemExtractor.extractItems(
                    from: blocks,
                    materials: profileLibrary.materials
                )
            mergeProfileItems(localItems)
            profileLibrary.materials = profileLibrary.materials.map {
                var copy = $0
                copy.status = .completed
                return copy
            }
            profileLibrary.aiConsent = false
            profileLibrary.status = .reviewing
            profileLibrary.updatedAt = .now
            try await persistProfileLibrary()
        } catch {
            profileLibrary.status = .failed
            profileLibrary.lastError = error.localizedDescription
            try? await persistProfileLibrary()
        }
        isWorking = false
    }

    func declineProfileAI() async {
        profileLibrary.aiConsent = false
        profileLibrary.status = .reviewing
        try? await persistProfileLibrary()
    }

    // 旧授权/重试入口保持可调用，但只能进入本地人工核对。
    func acceptProfileAI() async {
        await declineProfileAI()
    }

    /// 从旧云端状态或中断识别恢复，不删除 OCR、确认值、来源和历史 AI 标记。
    /// 缺少派生字段时重新运行本地规则；人工改过的字段始终优先。
    @discardableResult
    private func recoverProfileForLocalReview() -> Bool {
        let priorConsent = profileLibrary.aiConsent
        profileLibrary.aiConsent = false
        let oldCloudState = [.awaitingAIConsent, .resolving].contains(profileLibrary.status)
        let interrupted = [.recognizing, .failed].contains(profileLibrary.status)
        guard oldCloudState || (interrupted && !profileLibrary.ocrBlocks.isEmpty) else {
            if profileLibrary.status == .recognizing {
                profileLibrary.status = .imported
                return true
            }
            return priorConsent == true
        }
        let extracted = extractor.extract(from: profileLibrary.ocrBlocks)
        if profileLibrary.candidates.isEmpty { profileLibrary.candidates = extracted.candidates }
        let extractedFields = attachSources(to: extracted.resolved, in: profileLibrary)
        // 再次识别会清空派生字段，但不会清空条目。先恢复确认值及来源，
        // 再补 OCR 空缺，避免保存审核结果时反向覆盖原来的人工确认条目。
        if (profileLibrary.profileItems ?? []).isEmpty, profile.hasInformation {
            profileLibrary.profileItems = profile.informationItems
        }
        for item in profileLibrary.profileItems ?? [] where item.state != .pending || item.modifiedByUser {
            restoreCoreField(from: item)
        }
        for field in extractedFields {
            if let index = profileLibrary.resolvedFields.firstIndex(where: { $0.key == field.key }),
               profileLibrary.resolvedFields[index].value.isEmpty,
               !profileLibrary.resolvedFields[index].modifiedByUser {
                profileLibrary.resolvedFields[index] = field
            }
        }
        // 中断 OCR 仍可能包含新增技能/课程。始终抽取并去重，冲突仅进入待确认，
        // 即使 OCR 置信度很高，也不自动替换已有信息。
        mergeProfileItems(
            profileItems(from: profileLibrary.resolvedFields) + profileItems(from: extractedFields)
                + profileItemExtractor.extractItems(from: profileLibrary.ocrBlocks, materials: profileLibrary.materials),
            preservingExisting: true
        )
        profileLibrary.status = .reviewing
        profileLibrary.lastError = "已保留本地结果，请核对信息；复杂经历可在材料库中手动补充。"
        return true
    }

    private func restoreCoreField(from item: ProfileItem) {
        guard let key = FieldKey(rawValue: item.fieldID),
              let index = profileLibrary.resolvedFields.firstIndex(where: { $0.key == key }) else { return }
        let previous = profileLibrary.resolvedFields[index]
        let evidence = profile.evidence?.first { $0.key == key }
        profileLibrary.resolvedFields[index] = ResolvedField(
            key: key,
            value: item.value,
            candidateID: nil,
            confidence: item.confidence,
            sourceBlockIDs: item.sources.map(\.id),
            resolvedByAI: !item.modifiedByUser && (
                (previous.value == item.value && previous.resolvedByAI)
                    || (profile.value(for: key) == item.value && evidence?.resolvedByAI == true)
            ),
            modifiedByUser: item.modifiedByUser,
            sources: item.sources
        )
    }

    func updateProfileField(_ key: FieldKey, value: String) {
        guard let index = profileLibrary.resolvedFields.firstIndex(where: { $0.key == key }) else {
            return
        }
        profileLibrary.resolvedFields[index].value = value
        profileLibrary.resolvedFields[index].confidence = 1
        profileLibrary.resolvedFields[index].resolvedByAI = false
        profileLibrary.resolvedFields[index].modifiedByUser = true
        profileLibrary.resolvedFields[index].sourceBlockIDs = []
        profileLibrary.resolvedFields[index].sources = []
        if let itemIndex = profileLibrary.profileItems?.firstIndex(where: { $0.fieldID == key.rawValue }) {
            profileLibrary.profileItems?[itemIndex].value = value
            profileLibrary.profileItems?[itemIndex].components = [:]
            profileLibrary.profileItems?[itemIndex].confidence = 1
            profileLibrary.profileItems?[itemIndex].state = .confirmed
            profileLibrary.profileItems?[itemIndex].modifiedByUser = true
            profileLibrary.profileItems?[itemIndex].sources = []
            profileLibrary.profileItems?[itemIndex].updatedAt = .now
        }
        profileLibrary.updatedAt = .now
        Task { try? await persistProfileLibrary() }
    }

    func saveConfirmedProfile() async {
        var confirmedItems = (profileLibrary.profileItems ?? []).filter { $0.state != .pending }
        for var coreItem in profileItems(from: profileLibrary.resolvedFields) {
            coreItem.state = .confirmed
            if let index = confirmedItems.firstIndex(where: { $0.fieldID == coreItem.fieldID }) {
                // Keep the item's identity; an unchanged value must not lose its permission.
                var existing = confirmedItems[index]
                existing.label = coreItem.label
                existing.value = coreItem.value
                existing.confidence = coreItem.confidence
                existing.state = coreItem.state
                existing.sources = coreItem.sources
                existing.modifiedByUser = coreItem.modifiedByUser
                existing.updatedAt = coreItem.updatedAt
                confirmedItems[index] = existing
            } else {
                confirmedItems.append(coreItem)
            }
        }
        guard !confirmedItems.isEmpty else {
            transientError = BiaoXiaError.incompleteProfile.localizedDescription
            return
        }
        synchronizeProfileRecords(from: confirmedItems)
        var updated = PersonalProfile.empty
        updated.schemaVersion = PersonalProfile.currentSchemaVersion
        updated.evidence = profileLibrary.resolvedFields.map { field in
            updated.setValue(field.value, for: field.key)
            return ProfileFieldEvidence(
                key: field.key,
                confidence: field.confidence,
                resolvedByAI: field.resolvedByAI,
                modifiedByUser: field.modifiedByUser,
                sources: field.sources ?? []
            )
        }
        updated.items = confirmedItems
        updated.subjects = profileLibrary.subjects
        updated.records = profileLibrary.records
        updated.synchronizeLegacyFields()
        do {
            try await profileStore.save(updated)
            profile = updated
            profileLibrary.profileItems = confirmedItems
            profileLibrary.status = .confirmed
            try await persistProfileLibrary()
            isProfileLibraryPresented = false
        } catch {
            transientError = "无法保存个人档案：\(error.localizedDescription)"
        }
    }

    func importForm(from url: URL, in context: ModelContext) async {
        guard var current = snapshot else { return }
        isWorking = true
        transientError = nil
        defer { isWorking = false }

        do {
            let form = try await fileStore.importForm(
                from: url,
                taskID: current.id
            )
            current.form = form
            current.inputMode = .reusableProfile
            current.title = url.deletingPathExtension().lastPathComponent
            isFormImportPresented = false
            current.generalForm = nil
            current.fieldExplanationDraft = nil
            current.versionMapping = nil
            current.exportRelativePath = nil
            current.checkpoint = nextCheckpoint(.imported, after: current.checkpoint)
            current.status = .imported
            current.updatedAt = .now
            snapshot = current
            await persist(in: context)
            try await continueGeneralFormWorkflow(in: context)
        } catch {
            await fail(error, in: context)
        }
    }

    func open(_ record: FillTaskRecord, in context: ModelContext) async {
        guard !isWorking else { return }
        do {
            var loaded = try await fileStore.loadSnapshot(taskID: record.id)
            switch loaded.status {
            case .recognizing:
                loaded.status = .imported
            case .awaitingAIConsent, .resolving:
                loaded.status = .reviewing
                loaded.lastError = nil
            case .failed where loaded.generalForm != nil && [.matched, .reviewed].contains(loaded.checkpoint?.stage):
                loaded.status = .reviewing
                loaded.lastError = nil
            case .exporting:
                loaded.status = .reviewing
            default:
                break
            }
            loaded.aiConsent = false
            snapshot = loaded
            activeRecord = record
            await persist(in: context)
            if shouldContinueGeneralFormWorkflow(loaded) {
                do {
                    try await continueGeneralFormWorkflow(in: context)
                } catch {
                    await fail(error, in: context)
                }
            }
        } catch {
            transientError = "无法恢复任务：\(error.localizedDescription)"
        }
    }

    func closeTask() {
        guard !isWorking else { return }
        isFormImportPresented = false
        snapshot = nil
        activeRecord = nil
        transientError = nil
        hasUnsavedTaskChanges = false
    }

    func deleteTask(_ record: FillTaskRecord, in context: ModelContext) async {
        guard !isWorking else { return }
        isWorking = true
        transientError = nil
        defer { isWorking = false }

        do {
            try await fileStore.deleteTask(taskID: record.id)
            context.delete(record)
            try context.save()
        } catch {
            transientError = "无法删除任务：\(error.localizedDescription)"
        }
    }

    func clearTasks(_ records: [FillTaskRecord], in context: ModelContext) async {
        guard !isWorking, !records.isEmpty else { return }
        isWorking = true
        transientError = nil
        defer { isWorking = false }

        var failedTitles: [String] = []
        for record in records {
            do {
                try await fileStore.deleteTask(taskID: record.id)
                context.delete(record)
            } catch {
                failedTitles.append(record.title)
            }
        }

        do {
            try context.save()
        } catch {
            transientError = "清空任务记录失败：\(error.localizedDescription)"
            return
        }

        if !failedTitles.isEmpty {
            transientError = "部分任务无法删除，已保留：\(failedTitles.joined(separator: "、"))"
        }
    }

    func importURLs(_ urls: [URL], in context: ModelContext) async {
        guard var current = snapshot else { return }
        isWorking = true
        transientError = nil
        do {
            for url in urls {
                let asset = try await fileStore.importMaterial(
                    from: url,
                    taskID: current.id
                )
                current.materials.append(asset)
            }
            current.status = current.materials.isEmpty ? .draft : .imported
            current.updatedAt = .now
            snapshot = current
            await persist(in: context)
        } catch {
            transientError = error.localizedDescription
        }
        isWorking = false
    }

    func startRecognition(in context: ModelContext) async {
        guard var current = snapshot else { return }
        guard !current.materials.isEmpty else {
            transientError = BiaoXiaError.noMaterials.localizedDescription
            return
        }
        guard current.status == .imported else { return }

        current.status = .recognizing
        current.lastError = nil
        current.recognitionTotalPages = current.materials.reduce(0) {
            $0 + max(1, $1.pageCount)
        }
        current.recognitionCompletedPages = Set(current.ocrBlocks.map {
            "\($0.materialID.uuidString.lowercased()):\($0.pageIndex)"
        }).count
        snapshot = current
        await persist(in: context)

        do {
            let ocrService = taskOCRService ?? VisionOCRService(
                fileResolver: TaskMaterialFileResolver(store: fileStore, taskID: current.id)
            )
            let blocks = try await ocrService.recognize(
                materials: current.materials,
                existingBlocks: current.ocrBlocks
            ) { [weak self] completed, total, blocks in
                await self?.updateRecognitionProgress(
                    completed: completed,
                    total: total,
                    blocks: blocks
                )
            }
            let extracted = extractor.extract(from: blocks)
            guard var latest = snapshot else { return }
            latest.ocrBlocks = blocks
            latest.candidates = extracted.candidates
            latest.resolvedFields = extracted.resolved
            latest.materials = latest.materials.map {
                var copy = $0
                copy.status = .completed
                return copy
            }
            latest.aiConsent = false
            latest.status = .reviewing
            latest.updatedAt = .now
            snapshot = latest
            await persist(in: context)
        } catch {
            await fail(error, in: context)
        }
    }

    func declineAI(in context: ModelContext) async {
        guard var current = snapshot else { return }
        current.aiConsent = false
        current.status = .reviewing
        current.updatedAt = .now
        snapshot = current
        await persist(in: context)
    }

    // 即使旧界面或恢复任务仍调用此方法，也不会创建网络请求。
    func acceptAI(in context: ModelContext) async {
        await declineAI(in: context)
    }

    func updateField(_ key: FieldKey, value: String, in context: ModelContext) {
        guard var current = snapshot,
              let index = current.resolvedFields.firstIndex(where: { $0.key == key }) else {
            return
        }
        current.resolvedFields[index].value = value
        current.resolvedFields[index].confidence = 1
        current.resolvedFields[index].resolvedByAI = false
        current.resolvedFields[index].modifiedByUser = true
        current.updatedAt = .now
        snapshot = current
        Task { await persist(in: context) }
    }

    func updateFormValue(_ fieldID: String, value: String, in context: ModelContext) {
        guard var current = snapshot,
              let index = current.formValues?.firstIndex(where: { $0.fieldID == fieldID }) else {
            return
        }
        current.formValues?[index].value = value
        current.formValues?[index].modifiedByUser = true
        current.updatedAt = .now
        snapshot = current
        Task { await persist(in: context) }
    }

    func updateGeneralFormAnswer(
        fieldID: String,
        value: String,
        selectedOptionIDs: [String] = [],
        intentionallyBlank: Bool = false,
        in context: ModelContext
    ) {
        guard var current = snapshot,
              var document = current.generalForm,
              let index = document.fields.firstIndex(where: { $0.id == fieldID }) else { return }
        document.fields[index].answer = PersonalAnswer(
            value: intentionallyBlank ? nil : value,
            selectedOptionIDs: intentionallyBlank ? [] : selectedOptionIDs,
            sourceRecordIDs: [],
            confirmationState: intentionallyBlank ? .intentionallyBlank : .confirmed,
            modifiedByUser: true,
            reviewReasons: nil
        )
        current.generalForm = document
        current.checkpoint = nextCheckpoint(.reviewed, after: current.checkpoint)
        snapshot = current
        Task { await persist(in: context) }
    }

    func confirmSuggestedGeneralFormAnswer(fieldID: String, in context: ModelContext) async {
        guard var current = snapshot,
              var document = current.generalForm,
              let index = document.fields.firstIndex(where: { $0.id == fieldID }),
              var answer = document.fields[index].answer,
              answer.confirmationState == .suggested,
              let form = current.form else { return }

        answer.confirmationState = .confirmed
        document.fields[index].answer = answer
        do {
            let sourceURL = try await fileStore.absoluteURL(for: form.relativePath, taskID: current.id)
            let result = try formPreflighter.preflight(document: document, sourceURL: sourceURL)
                .first(where: { $0.fieldID == fieldID })
            let canConfirm: Bool
            switch result?.state {
            case .ready: canConfirm = document.effectiveFormat == .pdf
            case .contentReadyNeedsExternalReview: canConfirm = document.effectiveFormat == .docx
            default: canConfirm = false
            }
            guard canConfirm else {
                transientError = "无法确认“\(document.fields[index].label)”：\(layoutFailureMessage(result?.state))"
                return
            }
            current.generalForm = document
            current.checkpoint = nextCheckpoint(.reviewed, after: current.checkpoint)
            current.updatedAt = .now
            snapshot = current
            await persist(in: context)
        } catch {
            transientError = "无法确认“\(document.fields[index].label)”：\(error.localizedDescription)"
        }
    }

    func retrySaving(in context: ModelContext) async {
        transientError = nil
        await persist(in: context)
    }

    func prepareFieldExplanationReview(in context: ModelContext) async {
        guard var current = snapshot, let document = current.generalForm else { return }

        let draft = explanationRequestBuilder.makeDraft(fields: document.fields)
        guard !draft.texts.isEmpty else {
            transientError = "当前没有需要云端解释的陌生字段。"
            return
        }
        current.fieldExplanationDraft = draft
        current.status = .awaitingAIConsent
        current.updatedAt = .now
        snapshot = current
        await persist(in: context)
    }

    func allowExplanationText(_ textID: UUID, in context: ModelContext) {
        guard var current = snapshot, var draft = current.fieldExplanationDraft else { return }
        draft.allow(textID)
        current.fieldExplanationDraft = draft
        current.updatedAt = .now
        snapshot = current
        Task { await persist(in: context) }
    }

    func allowAllExplanationTexts(in context: ModelContext) {
        guard var current = snapshot, var draft = current.fieldExplanationDraft else { return }
        draft.allowAllPending()
        current.fieldExplanationDraft = draft
        current.updatedAt = .now
        snapshot = current
        Task { await persist(in: context) }
    }

    func removeExplanationText(_ textID: UUID, in context: ModelContext) {
        guard var current = snapshot, var draft = current.fieldExplanationDraft else { return }
        draft.remove(textID)
        current.fieldExplanationDraft = draft
        current.updatedAt = .now
        snapshot = current
        Task { await persist(in: context) }
    }

    func submitReviewedFieldExplanation(in context: ModelContext) async {
        guard !isWorking else { return }
        guard let submitter = fieldExplanationSubmitter else {
            transientError = "尚未配置字段解释服务；可跳过并在本机手动指定字段含义。"
            return
        }
        guard var current = snapshot, let draft = current.fieldExplanationDraft, draft.canSend else {
            transientError = "请先逐项允许或移除拟发送文字。"
            return
        }
        isWorking = true
        defer { isWorking = false }
        current.status = .resolving
        current.updatedAt = .now
        snapshot = current
        await persist(in: context)
        do {
            try validateAIOutboundText(draft.texts.filter { $0.state == .allowed }.map(\.value))
            let meanings = try await submitter.explain(draft: draft)
            guard snapshot?.id == current.id, var document = snapshot?.generalForm else { return }
            for index in document.fields.indices {
                if let meaning = meanings[document.fields[index].id] {
                    document.fields[index].meaning = meaning
                }
            }
            // Match newly explained fields locally without replacing explicit human answers.
            let answers = try await answerMatcher.match(
                fields: document.fields,
                subjects: profile.subjects ?? profileLibrary.subjects ?? [],
                records: profile.records ?? profileLibrary.records ?? []
            )
            for index in document.fields.indices {
                let existing = document.fields[index].answer
                if existing?.confirmationState != .confirmed,
                   existing?.confirmationState != .intentionallyBlank,
                   existing?.modifiedByUser != true,
                   let answer = answers[document.fields[index].id] {
                    document.fields[index].answer = answer
                }
            }
            current = snapshot ?? current
            current.generalForm = document
            current.fieldExplanationDraft = nil
            current.checkpoint = nextCheckpoint(.explained, after: current.checkpoint)
            current.status = .reviewing
            current.lastError = nil
            current.updatedAt = .now
            snapshot = current
            await persist(in: context)
        } catch {
            current = snapshot ?? current
            current.status = .awaitingAIConsent
            current.lastError = "云端解释失败，已保留核对内容；可重试或人工继续：\(error.localizedDescription)"
            snapshot = current
            await persist(in: context)
        }
    }

    func continueWithoutRemoteExplanation(in context: ModelContext) async {
        guard !isWorking, var current = snapshot else { return }
        current.fieldExplanationDraft = nil
        current.status = .reviewing
        current.lastError = "已跳过云端解释。陌生字段请在本机手动填写，个人资料不会因此出站。"
        current.updatedAt = .now
        snapshot = current
        await persist(in: context)
    }

    func updateFieldMeaning(fieldID: String, canonicalKey: String, in context: ModelContext) {
        guard var current = snapshot, var document = current.generalForm,
              let index = document.fields.firstIndex(where: { $0.id == fieldID }) else { return }
        let trimmed = canonicalKey.trimmingCharacters(in: .whitespacesAndNewlines)
        document.fields[index].meaning = FieldMeaning(
            canonicalKey: trimmed.isEmpty ? nil : trimmed,
            summary: trimmed.isEmpty ? nil : "由用户指定",
            state: trimmed.isEmpty ? .unresolved : .userSpecified
        )
        current.generalForm = document
        current.updatedAt = .now
        snapshot = current
        Task { await persist(in: context) }
    }

    func adjustPDFRegion(
        fieldID: String,
        anchorIndex: Int = 0,
        pageIndex: Int,
        rect: NormalizedRect,
        in context: ModelContext
    ) async {
        guard var current = snapshot, let document = current.generalForm else { return }
        do {
            guard let fieldIndex = document.fields.firstIndex(where: { $0.id == fieldID }),
                  document.fields[fieldIndex].anchors.indices.contains(anchorIndex) else {
                throw PDFFormEngineError.invalidAnchor(fieldID: fieldID)
            }
            var adjusted = try regionAdjuster.adjustingRegion(
                fieldID: fieldID,
                to: rect,
                pageIndex: pageIndex,
                in: document
            )
            var anchors = document.fields[fieldIndex].anchors
            anchors[anchorIndex] = adjusted.fields[fieldIndex].anchors[0]
            adjusted.fields[fieldIndex].anchors = anchors
            current.generalForm = adjusted
            current.updatedAt = .now
            snapshot = current
            await persist(in: context)
        } catch {
            transientError = "无法保存填写位置：\(error.localizedDescription)"
        }
    }

    func saveCurrentVersionMapping(in context: ModelContext) async {
        guard var current = snapshot, let document = current.generalForm else { return }
        let mapping = FormVersionMapping(
            id: current.versionMapping?.id ?? UUID(),
            documentFingerprint: document.fingerprint,
            structureVersion: document.structureVersion,
            pdfLayoutVersion: document.pdfLayoutVersion,
            fieldMeanings: Dictionary(uniqueKeysWithValues: document.fields.map { ($0.id, $0.meaning) }),
            anchors: Dictionary(uniqueKeysWithValues: document.fields.map { ($0.id, $0.anchors) }),
            updatedAt: .now
        )
        var mappings = profileLibrary.formMappings ?? []
        mappings.removeAll {
            $0.documentFingerprint == mapping.documentFingerprint
                && $0.structureVersion == mapping.structureVersion
        }
        mappings.append(mapping)
        let previousMappings = profileLibrary.formMappings
        profileLibrary.formMappings = mappings
        do {
            try await persistProfileLibrary()
            current.versionMapping = mapping
            snapshot = current
            await persist(in: context)
        } catch {
            profileLibrary.formMappings = previousMappings
            transientError = "版本映射未能保存，请重试：\(error.localizedDescription)"
        }
    }

    func toggleTaskProfileItem(_ item: ProfileItem, in context: ModelContext) {
        guard var current = snapshot, var values = current.formValues else { return }
        let targetIDs: [String]
        switch item.category {
        case .project: targetIDs = ["competitionTrack", "projectName", "competitionRole", "projectSummary"]
        case .course: targetIDs = ["coreCourses"]
        case .skill, .language: targetIDs = ["skills"]
        case .certificate: targetIDs = ["certificates"]
        case .award: targetIDs = ["awards"]
        case .internship, .work, .campus, .volunteer: targetIDs = ["experienceHighlights"]
        default: return
        }
        let isSelected = targetIDs.contains { fieldID in
            values.first(where: { $0.fieldID == fieldID })?.sourceItemIDs.contains(item.id) == true
        }
        for fieldID in targetIDs {
            guard let index = values.firstIndex(where: { $0.fieldID == fieldID }) else { continue }
            if isSelected {
                values[index].sourceItemIDs.removeAll { $0 == item.id }
            } else if item.category == .project {
                values[index].sourceItemIDs = [item.id]
            } else {
                let limit = maximumItems(for: fieldID)
                guard values[index].sourceItemIDs.count < limit else {
                    transientError = "本模板的\(values[index].label)最多选择 \(limit) 项"
                    continue
                }
                values[index].sourceItemIDs.append(item.id)
            }
        }
        let itemByID = Dictionary(uniqueKeysWithValues: profile.informationItems.map { ($0.id, $0) })
        for index in values.indices where targetIDs.contains(values[index].fieldID) {
            let selectedItems = values[index].sourceItemIDs.compactMap { itemByID[$0] }
            switch values[index].fieldID {
            case "competitionTrack": values[index].value = selectedItems.first?.components["赛道"] ?? selectedItems.first?.components["track"] ?? ""
            case "projectName": values[index].value = selectedItems.first?.components["title"] ?? selectedItems.first?.label ?? ""
            case "competitionRole": values[index].value = selectedItems.first?.components["角色"] ?? selectedItems.first?.components["role"] ?? ""
            case "projectSummary": values[index].value = selectedItems.first?.components["描述"] ?? selectedItems.first?.components["description"] ?? selectedItems.first?.value ?? ""
            default: values[index].value = selectedItems.map(\.value).joined(separator: values[index].fieldID == "skills" ? "、" : "\n")
            }
        }
        current.formValues = values
        current.updatedAt = .now
        snapshot = current
        Task { await persist(in: context) }
    }

    private func maximumItems(for fieldID: String) -> Int {
        guard let url = Bundle.main.url(forResource: "template_manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(TemplateManifest.self, from: data),
              let field = manifest.fields.first(where: { $0.key == fieldID }) else {
            return .max
        }
        return field.maximumItems ?? .max
    }

    func saveTaskValuesBackToProfile() async {
        guard let values = snapshot?.formValues else { return }
        var items = profile.informationItems
        for value in values where value.modifiedByUser && !value.value.isEmpty {
            if let index = items.firstIndex(where: { $0.fieldID == value.fieldID }) {
                items[index].value = value.value
                items[index].confidence = 1
                items[index].state = .confirmed
                items[index].modifiedByUser = true
                items[index].updatedAt = .now
            } else {
                items.append(ProfileItem(
                    category: .other,
                    fieldID: value.fieldID,
                    label: value.label,
                    value: value.value,
                    confidence: 1,
                    state: .confirmed,
                    modifiedByUser: true
                ))
            }
        }
        var updated = profile
        updated.items = items
        updated.schemaVersion = PersonalProfile.currentSchemaVersion
        updated.synchronizeLegacyFields()
        await saveProfile(updated)
    }

    func export(in context: ModelContext, allowPartial: Bool = false) async {
        guard !isWorking else { return }
        guard var current = snapshot else { return }
        if current.effectiveInputMode == .reusableProfile,
           current.form == nil {
            transientError = BiaoXiaError.formRequired.localizedDescription
            return
        }
        let missing = current.generalForm == nil
            ? (current.formValues ?? []).filter {
                $0.required && $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            : []
        guard missing.isEmpty else {
            transientError = "请先补全本表必填信息：\(missing.map(\.label).joined(separator: "、"))"
            return
        }
        if let document = current.generalForm {
            do { try validateGeneralFormForExport(document) }
            catch { await fail(error, in: context); return }
        }
        if let document = current.generalForm, FormExportSummary(document: document).isPartial, !allowPartial {
            transientError = "仍有未处理项目，请核对导出摘要后选择导出已确认内容。"
            return
        }
        isWorking = true
        defer { isWorking = false }
        current.status = .exporting
        current.lastError = nil
        current.updatedAt = .now
        snapshot = current
        await persist(in: context)

        do {
            guard snapshot?.id == current.id else { return }
            if let document = current.generalForm, let form = current.form {
                try validateGeneralFormForExport(document)
                let sourceURL = try await fileStore.absoluteURL(
                    for: form.relativePath,
                    taskID: current.id
                )
                let fileName = "filled-\(current.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).\(document.effectiveFormat.rawValue)"
                let destinationURL = try await fileStore.exportURL(
                    fileName: fileName,
                    taskID: current.id
                )
                try await formWriter.write(
                    document: document,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL
                )
                guard snapshot?.id == current.id else { return }
                current.exportRelativePath = "exports/\(fileName)"
                current.exportSummary = FormExportSummary(document: document)
                current.status = .completed
                current.checkpoint = nextCheckpoint(.exported, after: current.checkpoint)
                current.updatedAt = .now
                snapshot = current
                await persist(in: context)
                return
            }
            let result = try await pdfExporter.export(
                taskID: current.id,
                sourceFormRelativePath: current.form?.relativePath,
                resolvedFields: current.resolvedFields,
                formValues: current.formValues
            )
            guard snapshot?.id == current.id else { return }
            current.exportRelativePath = result.relativePath
            current.status = .completed
            current.updatedAt = .now
            snapshot = current
            await persist(in: context)
        } catch {
            guard snapshot?.id == current.id else { return }
            await fail(error, in: context)
        }
    }

    func sourceFormFileURL() async -> URL? {
        guard let current = snapshot, let form = current.form else { return nil }
        return try? await fileStore.absoluteURL(
            for: form.relativePath,
            taskID: current.id
        )
    }

    func exportFileURL() async -> URL? {
        guard let current = snapshot,
              let relativePath = current.exportRelativePath else { return nil }
        return try? await fileStore.absoluteURL(
            for: relativePath,
            taskID: current.id
        )
    }

    func retry(in context: ModelContext) async {
        guard var current = snapshot else { return }
        current.lastError = nil
        current.aiConsent = false
        let totalPages = current.materials.reduce(0) {
            $0 + max(1, $1.pageCount)
        }
        if current.form != nil {
            guard shouldContinueGeneralFormWorkflow(current) else {
                current.status = .reviewing
                snapshot = current
                await persist(in: context)
                return
            }
            current.status = .imported
            snapshot = current
            await persist(in: context)
            do {
                try await continueGeneralFormWorkflow(in: context)
            } catch {
                await fail(error, in: context)
            }
            return
        } else if current.materials.isEmpty {
            current.status = .draft
        } else if current.recognitionCompletedPages < totalPages {
            current.status = .imported
        } else {
            current.status = .reviewing
        }
        snapshot = current
        await persist(in: context)
    }

    private func updateRecognitionProgress(
        completed: Int,
        total: Int,
        blocks: [OCRBlock]
    ) async {
        guard var current = snapshot else { return }
        current.recognitionCompletedPages = completed
        current.recognitionTotalPages = total
        current.ocrBlocks = blocks
        current.updatedAt = .now
        snapshot = current
        try? await fileStore.saveSnapshot(current)
    }

    private func attachSources(
        to fields: [ResolvedField],
        in snapshot: ProfileLibrarySnapshot
    ) -> [ResolvedField] {
        let blockByID = Dictionary(uniqueKeysWithValues: snapshot.ocrBlocks.map { ($0.id, $0) })
        let materialByID = Dictionary(uniqueKeysWithValues: snapshot.materials.map { ($0.id, $0) })
        return fields.map { field in
            var copy = field
            copy.sources = field.sourceBlockIDs.compactMap { id in
                guard let block = blockByID[id], let material = materialByID[block.materialID] else {
                    return nil
                }
                return FieldSource(
                    id: block.id,
                    materialID: material.id,
                    materialName: material.displayName,
                    pageIndex: block.pageIndex,
                    excerpt: block.text,
                    confidence: block.confidence
                )
            }
            return copy
        }
    }

    func addCustomProfileItem(
        label: String,
        value: String,
        category: ProfileItemCategory = .other,
        subjectID: UUID? = nil
    ) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, !trimmedValue.isEmpty else { return }
        var items = profileLibrary.profileItems ?? profile.informationItems
        items.append(ProfileItem(
            category: category,
            fieldID: "custom.\(UUID().uuidString.lowercased())",
            label: trimmedLabel,
            value: trimmedValue,
            components: subjectID.map { ["subjectID": $0.uuidString.lowercased()] } ?? [:],
            confidence: 1,
            state: .confirmed,
            modifiedByUser: true
        ))
        profileLibrary.profileItems = items
        Task { try? await persistProfileLibrary() }
    }

    func addOCRBlockToProfile(
        _ block: OCRBlock,
        label: String,
        value: String,
        category: ProfileItemCategory = .other,
        subjectID: UUID? = nil
    ) {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty,
              !trimmedValue.isEmpty,
              block.text.localizedCaseInsensitiveContains(trimmedValue),
              let material = profileLibrary.materials.first(where: { $0.id == block.materialID }) else {
            return
        }
        var items = profileLibrary.profileItems ?? profile.informationItems
        let item = ProfileItem(
            category: category,
            fieldID: "custom.\(UUID().uuidString.lowercased())",
            label: trimmedLabel,
            value: trimmedValue,
            components: subjectID.map { ["subjectID": $0.uuidString.lowercased()] } ?? [:],
            confidence: 1,
            state: .confirmed,
            modifiedByUser: true,
            sources: [FieldSource(
                id: block.id,
                materialID: material.id,
                materialName: material.displayName,
                pageIndex: block.pageIndex,
                excerpt: block.text,
                confidence: block.confidence
            )]
        )
        items.append(item)
        profileLibrary.profileItems = items
        Task { try? await persistProfileLibrary() }
    }

    func addProfileSubject(
        displayName: String,
        kind: ProfileSubjectKind,
        relationshipToSelf: String?
    ) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let relationship = relationshipToSelf?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var subjects = profileLibrary.subjects ?? []
        guard !subjects.contains(where: {
            $0.kind == kind
                && $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
                && ($0.relationshipToSelf ?? "") == (relationship ?? "")
        }) else { return }
        subjects.append(ProfileSubject(
            id: UUID(),
            kind: kind,
            relationshipToSelf: relationship?.isEmpty == true ? nil : relationship,
            displayName: name
        ))
        profileLibrary.subjects = subjects
        Task { try? await persistProfileLibrary() }
    }

    func updateProfileItem(_ item: ProfileItem, label: String, value: String) {
        guard let index = profileLibrary.profileItems?.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let didChangeValue = profileLibrary.profileItems?[index].value != normalizedValue
        profileLibrary.profileItems?[index].label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        profileLibrary.profileItems?[index].value = normalizedValue
        if didChangeValue {
            let subjectID = profileLibrary.profileItems?[index].components["subjectID"]
            profileLibrary.profileItems?[index].components = subjectID.map { ["subjectID": $0] } ?? [:]
            profileLibrary.profileItems?[index].sources = []
        }
        profileLibrary.profileItems?[index].confidence = 1
        profileLibrary.profileItems?[index].state = .confirmed
        profileLibrary.profileItems?[index].modifiedByUser = true
        profileLibrary.profileItems?[index].updatedAt = .now
        Task { try? await persistProfileLibrary() }
    }

    func deleteProfileItem(_ item: ProfileItem) {
        profileLibrary.profileItems?.removeAll { $0.id == item.id }
        profileLibrary.pendingItems?.removeAll { $0.id == item.id }
        Task { try? await persistProfileLibrary() }
    }

    func setPreferredProfileItem(_ item: ProfileItem) {
        guard var items = profileLibrary.profileItems else { return }
        for index in items.indices where items[index].category == item.category {
            items[index].isPreferred = items[index].id == item.id
        }
        profileLibrary.profileItems = items
        Task { try? await persistProfileLibrary() }
    }

    func acceptPendingProfileItem(_ item: ProfileItem) {
        guard profileLibrary.pendingItems?.contains(where: { $0.id == item.id }) == true else { return }
        var accepted = item
        accepted.state = .confirmed
        accepted.updatedAt = .now
        mergeProfileItems([accepted], forceApply: true)
        restoreCoreField(from: accepted)
        profileLibrary.pendingItems?.removeAll { $0.id == item.id }
        Task { try? await persistProfileLibrary() }
    }

    func acceptAllPendingProfileItems() {
        guard let pendingItems = profileLibrary.pendingItems, !pendingItems.isEmpty else { return }
        let acceptedIDs = Set(pendingItems.map(\.id))
        let acceptedItems = pendingItems.map { item in
            var accepted = item
            accepted.state = .confirmed
            accepted.updatedAt = .now
            return accepted
        }
        mergeProfileItems(acceptedItems, forceApply: true)
        for item in acceptedItems { restoreCoreField(from: item) }
        profileLibrary.pendingItems?.removeAll { acceptedIDs.contains($0.id) }
        Task { try? await persistProfileLibrary() }
    }

    func rejectPendingProfileItem(_ item: ProfileItem) {
        profileLibrary.pendingItems?.removeAll { $0.id == item.id }
        Task { try? await persistProfileLibrary() }
    }

    func undoProfileChangeBatch(_ batch: ProfileChangeBatch) {
        var items = profileLibrary.profileItems ?? []
        for change in batch.changes.reversed() {
            items.removeAll { $0.id == change.itemID }
            if let previous = change.previous { items.append(previous) }
        }
        profileLibrary.profileItems = items
        profileLibrary.changeHistory?.removeAll { $0.id == batch.id }
        Task { try? await persistProfileLibrary() }
    }

    func undoProfileChange(_ change: ProfileItemChange, in batch: ProfileChangeBatch) {
        var items = profileLibrary.profileItems ?? []
        items.removeAll { $0.id == change.itemID }
        if let previous = change.previous { items.append(previous) }
        profileLibrary.profileItems = items
        guard let batchIndex = profileLibrary.changeHistory?.firstIndex(where: { $0.id == batch.id }) else {
            Task { try? await persistProfileLibrary() }
            return
        }
        profileLibrary.changeHistory?[batchIndex].changes.removeAll { $0.id == change.id }
        if profileLibrary.changeHistory?[batchIndex].changes.isEmpty == true {
            profileLibrary.changeHistory?.remove(at: batchIndex)
        }
        Task { try? await persistProfileLibrary() }
    }

    func searchOCR(_ query: String) -> [OCRBlock] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return profileLibrary.ocrBlocks.filter {
            $0.text.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func profileItems(from fields: [ResolvedField]) -> [ProfileItem] {
        fields.compactMap { field in
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return ProfileItem(
                category: field.key.profileCategory,
                fieldID: field.key.rawValue,
                label: field.key.label,
                value: value,
                confidence: field.confidence,
                state: field.confidence >= 0.92 ? .autoExtracted : .pending,
                sensitivity: field.key.sensitivity,
                modifiedByUser: field.modifiedByUser,
                sources: field.sources ?? []
            )
        }
    }

    private func mergeProfileItems(
        _ candidates: [ProfileItem],
        forceApply: Bool = false,
        preservingExisting: Bool = false
    ) {
        var current = profileLibrary.profileItems ?? profile.informationItems
        var pending = profileLibrary.pendingItems ?? []
        var changes: [ProfileItemChange] = []

        // 多值信息按稳定语义身份合并；实例 UUID 只用于编辑与展示，不能参与业务去重。
        func isSameItem(_ lhs: ProfileItem, _ rhs: ProfileItem) -> Bool {
            return lhs.normalizedIdentity == rhs.normalizedIdentity
        }

        for candidate in candidates {
            if preservingExisting && pending.contains(where: { isSameItem($0, candidate) }) { continue }
            let isCoreField = FieldKey(rawValue: candidate.fieldID) != nil
            let existingIndex: Int? = candidate.category.allowsMultiple && !isCoreField
                ? current.firstIndex(where: { isSameItem($0, candidate) })
                : current.firstIndex(where: { $0.fieldID == candidate.fieldID })

            if let index = existingIndex {
                let existing = current[index]
                if existing.value == candidate.value {
                    if preservingExisting { continue }
                    current[index].confidence = max(existing.confidence, candidate.confidence)
                    current[index].sources = Array(Set(existing.sources + candidate.sources))
                    continue
                }
                if preservingExisting {
                    var update = candidate
                    update.state = .pending
                    pending.append(update)
                    continue
                }
                if forceApply || candidate.confidence >= 0.92 {
                    var replacement = candidate
                    replacement = ProfileItem(
                        id: existing.id,
                        category: candidate.category,
                        fieldID: existing.fieldID,
                        label: candidate.label,
                        value: candidate.value,
                        components: candidate.components,
                        confidence: candidate.confidence,
                        state: candidate.state,
                        sensitivity: candidate.sensitivity,
                        isPreferred: existing.isPreferred,
                        modifiedByUser: candidate.modifiedByUser,
                        sources: candidate.sources,
                        updatedAt: .now
                    )
                    current[index] = replacement
                    changes.append(ProfileItemChange(
                        itemID: existing.id,
                        label: candidate.label,
                        previous: existing,
                        current: replacement
                    ))
                } else if !pending.contains(where: { $0.normalizedIdentity == candidate.normalizedIdentity }) {
                    pending.append(candidate)
                }
            } else if forceApply || candidate.confidence >= 0.92 {
                var applied = candidate
                applied.state = forceApply
                    ? candidate.state
                    : (candidate.modifiedByUser ? .confirmed : .autoExtracted)
                current.append(applied)
                changes.append(ProfileItemChange(
                    itemID: applied.id,
                    label: applied.label,
                    previous: nil,
                    current: applied
                ))
            } else if !pending.contains(where: { $0.normalizedIdentity == candidate.normalizedIdentity }) {
                pending.append(candidate)
            }
        }

        profileLibrary.profileItems = current
        profileLibrary.pendingItems = pending
        synchronizeProfileRecords(from: current)
        if !changes.isEmpty {
            var history = profileLibrary.changeHistory ?? []
            history.insert(ProfileChangeBatch(changes: changes), at: 0)
            profileLibrary.changeHistory = Array(history.prefix(20))
        }
    }

    private func synchronizeProfileRecords(from items: [ProfileItem]) {
        let existingSelf = profileLibrary.subjects?.first(where: { $0.kind == .selfPerson })
        let selfSubject = existingSelf ?? ProfileSubject(
            id: UUID(),
            kind: .selfPerson,
            relationshipToSelf: nil,
            displayName: items.first(where: { $0.fieldID == FieldKey.fullName.rawValue })?.value ?? "本人"
        )
        var subjects = profileLibrary.subjects ?? []
        if !subjects.contains(where: { $0.id == selfSubject.id }) { subjects.append(selfSubject) }
        profileLibrary.subjects = subjects

        profileLibrary.records = makeProfileRecords(from: items, subjects: subjects,
            existing: profileLibrary.records ?? [])
    }

    /// Rebuild each store from its own surviving items, preserving stable record IDs.
    private func makeProfileRecords(from items: [ProfileItem], subjects: [ProfileSubject], existing: [ProfileRecord]) -> [ProfileRecord] {
        guard let selfSubject = subjects.first(where: { $0.kind == .selfPerson }) else { return [] }
        let existingByKey = Dictionary(
            existing.map { ($0.businessKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.compactMap { item in
            guard let kind = recordKind(for: item.category) else { return nil }
            var components = item.components
            let subjectID = components.removeValue(forKey: "subjectID")
                .flatMap(UUID.init(uuidString:))
                .flatMap { id in subjects.contains(where: { $0.id == id }) ? id : nil }
                ?? selfSubject.id
            components["fieldID"] = item.fieldID.split(separator: ".").first.map(String.init) ?? item.fieldID
            components["label"] = item.label
            components["value"] = item.value
            let businessKey = ProfileBusinessKey.make(
                kind: kind,
                subjectID: subjectID,
                components: components
            )
            let existing = existingByKey[businessKey]
            return ProfileRecord(
                id: existing?.id ?? item.id,
                subjectID: subjectID,
                kind: kind,
                businessKey: businessKey,
                displayValue: item.value,
                components: components,
                sources: item.sources,
                confirmedComponentKeys: item.state == .confirmed ? Set(components.keys) : [],
                updatedAt: item.updatedAt
            )
        }
    }

    private func recordKind(for category: ProfileItemCategory) -> ProfileRecordKind? {
        switch category {
        case .education: .education
        case .course: .course
        case .skill, .language: .skill
        case .certificate: .certificate
        case .project: .project
        case .internship, .work: .employment
        case .campus, .volunteer, .award, .selfIntroduction: .experience
        case .identity: .identity
        case .contact: .contact
        case .other: nil
        }
    }

    private func updateMaterialName(
        in items: inout [ProfileItem]?,
        materialID: UUID,
        name: String
    ) {
        guard var values = items else { return }
        for itemIndex in values.indices {
            for sourceIndex in values[itemIndex].sources.indices
            where values[itemIndex].sources[sourceIndex].materialID == materialID {
                values[itemIndex].sources[sourceIndex].materialName = name
            }
        }
        items = values
    }

    private func removeMaterialSource(in items: inout [ProfileItem]?, materialID: UUID) {
        guard var values = items else { return }
        for index in values.indices {
            values[index].sources.removeAll { $0.materialID == materialID }
        }
        values.removeAll { $0.sources.isEmpty && !$0.modifiedByUser }
        items = values
    }

    private func makeFormValues(from items: [ProfileItem]) -> [FormFieldValue] {
        let manifestFields: [TemplateFieldManifest] = {
            guard let url = Bundle.main.url(forResource: "template_manifest", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(TemplateManifest.self, from: data) else {
                return []
            }
            return manifest.fields
        }()
        let definitions = Dictionary(uniqueKeysWithValues: manifestFields.map { ($0.key, $0) })
        let bestByField = Dictionary(grouping: items, by: \.fieldID).compactMapValues { values in
            values.sorted {
                if $0.isPreferred != $1.isPreferred { return $0.isPreferred }
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.updatedAt > $1.updatedAt
            }.first
        }
        var values: [FormFieldValue] = FieldKey.allCases.map { key in
            let item = bestByField[key.rawValue]
            return FormFieldValue(
                fieldID: key.rawValue,
                label: key.label,
                value: item?.value ?? profile.value(for: key),
                required: definitions[key.rawValue]?.required ?? false,
                sourceItemIDs: item.map { [$0.id] } ?? [],
                modifiedByUser: false
            )
        }

        func selected(_ category: ProfileItemCategory, limit: Int) -> [ProfileItem] {
            Array(items.filter { $0.category == category && $0.state != .pending }
                .sorted {
                    if $0.isPreferred != $1.isPreferred { return $0.isPreferred }
                    if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                    return $0.updatedAt > $1.updatedAt
                }
                .prefix(limit))
        }

        let project = selected(.project, limit: 1).first
        let extra: [(String, String, String, [ProfileItem])] = [
            ("competitionTrack", "报名赛道", project?.components["赛道"] ?? project?.components["track"] ?? "", project.map { [$0] } ?? []),
            ("projectName", "项目名称", project?.components["title"] ?? project?.label ?? "", project.map { [$0] } ?? []),
            ("competitionRole", "参赛角色", project?.components["角色"] ?? project?.components["role"] ?? "", project.map { [$0] } ?? []),
            ("projectSummary", "项目简介", project?.components["描述"] ?? project?.components["description"] ?? project?.value ?? "", project.map { [$0] } ?? []),
            ("selfIntroduction", "个人简介", selected(.selfIntroduction, limit: 1).first?.value ?? "", selected(.selfIntroduction, limit: 1)),
            ("skills", "技能", selected(.skill, limit: definitions["skills"]?.maximumItems ?? 6).map(\.value).joined(separator: "、"), selected(.skill, limit: definitions["skills"]?.maximumItems ?? 6)),
            ("certificates", "证书", selected(.certificate, limit: definitions["certificates"]?.maximumItems ?? 4).map(\.value).joined(separator: "\n"), selected(.certificate, limit: definitions["certificates"]?.maximumItems ?? 4)),
            ("awards", "获奖", selected(.award, limit: definitions["awards"]?.maximumItems ?? 4).map(\.value).joined(separator: "\n"), selected(.award, limit: definitions["awards"]?.maximumItems ?? 4)),
            ("coreCourses", "核心课程与成绩", selected(.course, limit: definitions["coreCourses"]?.maximumItems ?? 5).map(\.value).joined(separator: "\n"), selected(.course, limit: definitions["coreCourses"]?.maximumItems ?? 5)),
            ("experienceHighlights", "经历摘要", ([.internship, .work, .campus, .volunteer] as [ProfileItemCategory]).flatMap { selected($0, limit: 2) }.map(\.value).joined(separator: "\n"), ([.internship, .work, .campus, .volunteer] as [ProfileItemCategory]).flatMap { selected($0, limit: 2) }),
            ("materialSources", "来源说明", Array(Set(items.flatMap(\.sources).map(\.materialName))).sorted().joined(separator: "、"), [])
        ]
        values += extra.map { fieldID, label, value, sourceItems in
            FormFieldValue(
                fieldID: fieldID,
                label: label,
                value: value,
                required: definitions[fieldID]?.required ?? false,
                sourceItemIDs: sourceItems.map(\.id),
                modifiedByUser: false
            )
        }
        return values.filter { definitions[$0.fieldID] != nil }
    }

    private func resetProfileRecognition() {
        profileLibrary.status = profileLibrary.materials.isEmpty ? .draft : .imported
        profileLibrary.ocrBlocks = []
        profileLibrary.candidates = []
        profileLibrary.resolvedFields = PersonalProfile.empty.resolvedFields
        profileLibrary.aiConsent = nil
        profileLibrary.recognitionCompletedPages = 0
        profileLibrary.recognitionTotalPages = 0
        profileLibrary.lastError = nil
        profileLibrary.materials = profileLibrary.materials.map {
            var copy = $0
            copy.status = .pending
            return copy
        }
        profileLibrary.updatedAt = .now
    }

    private func updateProfileRecognitionProgress(
        completed: Int,
        total: Int,
        blocks: [OCRBlock]
    ) async {
        profileLibrary.recognitionCompletedPages = completed
        profileLibrary.recognitionTotalPages = total
        profileLibrary.ocrBlocks = blocks
        profileLibrary.updatedAt = .now
        try? await persistProfileLibrary()
    }

    private func persistProfileLibrary() async throws {
        if let items = profileLibrary.profileItems {
            synchronizeProfileRecords(from: items)
        }
        let entries = aiSharingEntries
        profileLibrary.aiSharingGrants = (profileLibrary.aiSharingGrants ?? [:]).filter { id, fingerprint in
            entries.contains { $0.id == id && $0.fingerprint == fingerprint }
        }
        profileLibrary.updatedAt = .now
        try await profileLibraryStore.save(profileLibrary)
    }

    /// Permissions live only in the library. Revocation takes effect in memory before disk I/O,
    /// so a queued batch cannot send while a permission change is being saved.
    func setAISharingAllowed(_ entry: ProfileAISharingEntry, allowed: Bool) async {
        guard !isUpdatingAISharing else { return }
        guard aiSharingEntries.contains(where: { $0.id == entry.id && $0.fingerprint == entry.fingerprint }) else {
            transientError = "资料已改变，请核对当前内容后重新设置 AI 权限。"
            return
        }
        if let items = profileLibrary.profileItems { synchronizeProfileRecords(from: items) }
        guard let current = aiSharingEntries.first(where: { $0.id == entry.id }),
              current.text == entry.text else {
            transientError = "资料已改变，请核对当前内容后重新设置 AI 权限。"
            return
        }
        isUpdatingAISharing = true
        defer { isUpdatingAISharing = false }
        var grants = profileLibrary.aiSharingGrants ?? [:]
        if allowed { grants[entry.id] = current.fingerprint }
        else { grants.removeValue(forKey: entry.id) }
        profileLibrary.aiSharingGrants = grants
        do {
            try await persistProfileLibrary()
            aiSharingSaveFailed = false
        } catch {
            // Never grant on a failed save, and never undo a requested revocation.
            profileLibrary.aiSharingGrants?.removeValue(forKey: entry.id)
            aiSharingSaveFailed = true
            transientError = "AI 权限尚未保存，当前云端填写已暂停。请重试保存；退出后可能恢复此前设置。"
        }
    }

    func retryAISharingSave() async {
        guard !isUpdatingAISharing else { return }
        isUpdatingAISharing = true
        defer { isUpdatingAISharing = false }
        do {
            try await persistProfileLibrary()
            aiSharingSaveFailed = false
            transientError = nil
        } catch {
            aiSharingSaveFailed = true
            transientError = "AI 权限尚未保存，当前云端填写已暂停。请重试保存；退出后可能恢复此前设置。"
        }
    }

    private func continueGeneralFormWorkflow(in context: ModelContext) async throws {
        guard var current = snapshot, let form = current.form else {
            throw BiaoXiaError.formRequired
        }
        let sourceURL = try await fileStore.absoluteURL(
            for: form.relativePath,
            taskID: current.id
        )
        var document: GeneralFormDocument
        if let existing = current.generalForm {
            document = existing
        } else {
            document = try await formParser.parse(formURL: sourceURL)
            if let mapping = (profileLibrary.formMappings ?? []).first(where: {
                $0.documentFingerprint == document.fingerprint
                    && $0.structureVersion == document.structureVersion
                    && (document.effectiveFormat != .pdf || $0.pdfLayoutVersion == document.pdfLayoutVersion)
            }) {
                for index in document.fields.indices {
                    let fieldID = document.fields[index].id
                    if let meaning = mapping.fieldMeanings[fieldID] {
                        document.fields[index].meaning = meaning
                    }
                    if let anchors = mapping.anchors[fieldID], !anchors.isEmpty {
                        document.fields[index].anchors = anchors
                    }
                }
                current.versionMapping = mapping
            }
        }
        current.generalForm = document
        current.checkpoint = nextCheckpoint(.parsed, after: current.checkpoint)
        snapshot = current
        await persist(in: context)

        let answers = try await answerMatcher.match(
            fields: document.fields,
            subjects: profile.subjects ?? profileLibrary.subjects ?? [],
            records: profile.records ?? profileLibrary.records ?? []
        )
        for index in document.fields.indices {
            if let answer = answers[document.fields[index].id] {
                let existing = document.fields[index].answer
                if existing?.confirmationState != .confirmed,
                   existing?.confirmationState != .intentionallyBlank,
                   existing?.modifiedByUser != true {
                    document.fields[index].answer = answer
                }
            }
        }
        current = snapshot ?? current
        for index in document.fields.indices {
            if let key = FormRecordMatcher.key(for: document.fields[index]), document.fields[index].meaning.state != .userSpecified {
                document.fields[index].meaning = FieldMeaning(canonicalKey: key, summary: nil, state: .knownLocally)
            } else if document.fields[index].answer?.confirmationState == .confirmed,
                      document.fields[index].meaning.state == .needsReview {
                document.fields[index].meaning.state = .knownLocally
            }
        }
        current.generalForm = document
        current.checkpoint = nextCheckpoint(.matched, after: current.checkpoint)
        current.status = .reviewing
        current.lastError = nil
        snapshot = current
        await persist(in: context)
    }

    private func validateGeneralFormForExport(_ document: GeneralFormDocument) throws {
        guard document.structureVersion == GeneralFormDocument.currentStructureVersion,
              document.effectiveFormat != .pdf || document.pdfLayoutVersion == PDFFormEngine.layoutVersion else {
            throw ModuleFailure.blocked("此任务使用旧版字段结构，请保留当前答案并重新导入原表核对必填项后导出。")
        }
        let blocking = document.fields.filter { field in
            guard field.constraints.isRequired else { return false }
            return field.answer?.confirmationState != .confirmed
        }
        guard blocking.isEmpty else {
            throw ModuleFailure.blocked(
                "请先处理必填字段：\(blocking.map(\.label).joined(separator: "、"))"
            )
        }
    }

    private func shouldContinueGeneralFormWorkflow(_ task: FillTaskSnapshot) -> Bool {
        guard task.form != nil else { return false }
        if task.generalForm == nil { return true }
        switch task.checkpoint?.stage {
        case .imported, .parsed:
            return true
        default:
            return false
        }
    }

    private func layoutFailureMessage(_ state: PDFFieldLayoutState?) -> String {
        switch state {
        case .ready:
            return ""
        case .contentReadyNeedsExternalReview:
            return "Word 内容可写入；最终版式需在 Word/WPS 中核对"
        case .needsAnchorReview:
            return "填写位置需要修正"
        case .invalidAnswer(let reason):
            return reason
        case .overflow:
            return "内容超出填写区域"
        case nil:
            return "无法验证答案与填写位置"
        }
    }

    private func nextCheckpoint(
        _ stage: WorkflowStage,
        after checkpoint: WorkflowCheckpoint?
    ) -> WorkflowCheckpoint {
        WorkflowCheckpoint(
            stage: stage,
            revision: (checkpoint?.revision ?? 0) + 1,
            savedAt: .now
        )
    }

    private func fail(_ error: Error, in context: ModelContext) async {
        guard var current = snapshot else { return }
        current.status = .failed
        current.lastError = failureMessage(for: error, in: current)
        current.updatedAt = .now
        snapshot = current
        await persist(in: context)
    }

    /// Engine failures carry their own Chinese wording; this only names the offending field when
    /// the engine identified one, so the user knows what to fix before retrying.
    private func failureMessage(for error: Error, in task: FillTaskSnapshot) -> String {
        let message = error.localizedDescription
        guard let fieldID = (error as? PDFFormEngineError)?.fieldID,
              let label = task.generalForm?.fields.first(where: { $0.id == fieldID })?.label,
              !label.isEmpty else { return message }
        return "「\(label)」\(message)"
    }

    func persist(in context: ModelContext) async {
        guard var current = snapshot else { return }
        current.updatedAt = .now
        snapshot = current
        do {
            try await fileStore.saveSnapshot(current)
            // Saving may suspend; never update the index of a task opened meanwhile.
            guard snapshot?.id == current.id else { return }
            if let activeRecord {
                activeRecord.update(from: current)
            } else {
                let record = FillTaskRecord(snapshot: current)
                context.insert(record)
                activeRecord = record
            }
            try context.save()
            hasUnsavedTaskChanges = false
            if transientError?.hasPrefix("尚未保存：") == true { transientError = nil }
        } catch {
            hasUnsavedTaskChanges = true
            transientError = "尚未保存：\(error.localizedDescription)。请重试保存。"
        }
    }
}

// Shared PDF/DOCX assistance always writes the same dynamic field used by export.
extension FlowStore {
    func returnToFormReview(in context: ModelContext) async {
        guard snapshot?.generalForm != nil, !isWorking else { return }
        snapshot?.status = .reviewing
        snapshot?.lastError = nil
        await persist(in: context)
    }

    var availableRecords: [ProfileRecord] { profile.records ?? profileLibrary.records ?? [] }
    var availableSubjects: [ProfileSubject] { profile.subjects ?? profileLibrary.subjects ?? [] }

    func records(for field: DynamicFormField, includeAll: Bool = false) -> [ProfileRecord] {
        if includeAll { return availableRecords.sorted { $0.id.uuidString < $1.id.uuidString } }
        return FormRecordMatcher.candidates(field: field, records: availableRecords, subjects: availableSubjects)
    }

    func toggleRecord(_ recordID: UUID, fieldID: String, in context: ModelContext) async {
        guard var document = snapshot?.generalForm, let index = document.fields.firstIndex(where: { $0.id == fieldID }),
              availableRecords.contains(where: { $0.id == recordID }) else { return }
        var ids = document.fields[index].selectedRecordIDs ?? []
        if ids.contains(recordID) { ids.removeAll { $0 == recordID } }
        else if FormRecordMatcher.isSingleProject(document.fields[index]) { ids = [recordID] }
        else { ids.append(recordID) }
        document.fields[index].selectedRecordIDs = ids
        document.fields[index].compositionDraft = nil
        if FormRecordMatcher.isSingleProject(document.fields[index]) {
            let group = document.fields.indices.filter {
                FormRecordMatcher.isSingleProject(document.fields[$0]) && document.fields[$0].section == document.fields[index].section
            }
            let keys = group.compactMap { FormRecordMatcher.key(for: document.fields[$0]) }
            // Only a unique, unambiguous project group can share a selection.
            if Set(keys).count == keys.count {
                for i in group where i != index {
                    document.fields[i].selectedRecordIDs = ids
                    document.fields[i].compositionDraft = nil
                }
            }
        }
        // A selection is not consent to replace a handwritten answer or send data.
        snapshot?.generalForm = document
        await persist(in: context)
    }

    func combineSelectedRecords(fieldID: String, replacingConfirmed: Bool = false, in context: ModelContext) async {
        guard var document = snapshot?.generalForm, let index = document.fields.firstIndex(where: { $0.id == fieldID }) else { return }
        let field = document.fields[index]
        let selected = (field.selectedRecordIDs ?? []).compactMap { id in availableRecords.first { $0.id == id } }
        let values = selected.map { FormRecordMatcher.value(record: $0, field: field) }.filter { !$0.isEmpty }
        guard !values.isEmpty else { transientError = "所选资料没有对应内容，请手动补充。"; return }
        if !replacingConfirmed && (field.answer?.modifiedByUser == true || field.answer?.confirmationState == .confirmed) {
            transientError = "此字段已有确认内容。请先编辑或清空答案，再采用资料建议。"
            return
        }
        document.fields[index].answer = PersonalAnswer(value: values.joined(separator: "\n"), selectedOptionIDs: [],
            sourceRecordIDs: selected.map(\.id), confirmationState: .suggested, modifiedByUser: false,
            reviewReasons: ["请核对选择的资料与组合内容"])
        snapshot?.generalForm = document
        await persist(in: context)
    }

    func prepareAnswerComposition(fieldID: String, in context: ModelContext) async {
        guard var document = snapshot?.generalForm, let index = document.fields.firstIndex(where: { $0.id == fieldID }) else { return }
        let field = document.fields[index]
        guard field.options.isEmpty else { transientError = "勾选项请自行核对。"; return }
        let sources = formPlanSources
        guard !sources.isEmpty else { transientError = "请先在 AI 可用资料中允许本次需要的建档资料项。"; return }
        let request = AnswerCompositionRequest(requestId: UUID(), fieldLabel: field.label,
            instructions: field.instructions ?? "", maximumCharacters: field.constraints.maximumCharacters,
            sources: sources.map { AnswerSourceSnippet(id: $0.id, text: $0.text) })
        document.fields[index].compositionDraft = AnswerCompositionDraft(request: request,
            recordIDs: sources.compactMap(\.recordID), originalAnswer: field.answer, aiSources: sources)
        snapshot?.generalForm = document
        await persist(in: context)
    }

    func updateCompositionDraft(fieldID: String, edit: (inout AnswerCompositionDraft) -> Void, in context: ModelContext) async {
        guard let index = snapshot?.generalForm?.fields.firstIndex(where: { $0.id == fieldID }),
              var draft = snapshot?.generalForm?.fields[index].compositionDraft else { return }
        edit(&draft)
        snapshot?.generalForm?.fields[index].compositionDraft = draft
        await persist(in: context)
    }

    func discardComposition(fieldID: String, in context: ModelContext) async {
        guard let index = snapshot?.generalForm?.fields.firstIndex(where: { $0.id == fieldID }) else { return }
        snapshot?.generalForm?.fields[index].compositionDraft = nil
        await persist(in: context)
    }

    func submitAnswerComposition(fieldID: String, in context: ModelContext) async {
        guard !isWorking, let taskID = snapshot?.id,
              let field = snapshot?.generalForm?.fields.first(where: { $0.id == fieldID }),
              let draft = field.compositionDraft else { return }
        guard let answerComposer else { transientError = "尚未配置答案整理服务，可继续在本机填写。"; return }
        guard field.answer == draft.originalAnswer else { transientError = "答案已修改，请重新准备整理请求。"; return }
        isWorking = true
        defer { isWorking = false }
        do {
            try validateCompositionPermissions(draft)
            let response = try await answerComposer.compose(draft.request)
            try Task.checkCancellation()
            try validateCompositionPermissions(draft)
            guard snapshot?.id == taskID,
                  let index = snapshot?.generalForm?.fields.firstIndex(where: { $0.id == fieldID }),
                  snapshot?.generalForm?.fields[index].compositionDraft?.request == draft.request,
                  snapshot?.generalForm?.fields[index].answer == draft.originalAnswer else { return }
            snapshot?.generalForm?.fields[index].compositionDraft?.response = response
            snapshot?.generalForm?.fields[index].compositionDraft?.editedAnswer = response.answer
            snapshot?.generalForm?.fields[index].compositionDraft?.error = nil
            await persist(in: context)
        } catch {
            guard snapshot?.id == taskID,
                  let index = snapshot?.generalForm?.fields.firstIndex(where: { $0.id == fieldID }),
                  snapshot?.generalForm?.fields[index].compositionDraft?.request == draft.request else { return }
            snapshot?.generalForm?.fields[index].compositionDraft?.error = "整理未完成，可修改资料后重试或继续本地填写。"
            transientError = error.localizedDescription
            await persist(in: context)
        }
    }

    func adoptComposition(fieldID: String, in context: ModelContext) async {
        guard let index = snapshot?.generalForm?.fields.firstIndex(where: { $0.id == fieldID }),
              let field = snapshot?.generalForm?.fields[index], let draft = field.compositionDraft,
              let response = draft.response, response.answer != nil,
              let value = draft.editedAnswer, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard field.answer == draft.originalAnswer else { transientError = "当前答案已改变，请重新核对后整理，避免覆盖新修改。"; return }
        // Adopting an already saved answer is a local edit, not a new cloud disclosure.
        // Historical drafts remain reviewable even though they may never be sent again.
        let ids = response.sourceIDs.compactMap { sourceID -> UUID? in
            if let sources = draft.aiSources { return sources.first { $0.id == sourceID }?.recordID }
            guard let position = draft.request.sources.firstIndex(where: { $0.id == sourceID }),
                  draft.recordIDs.indices.contains(position) else { return nil }
            return draft.recordIDs[position]
        }
        snapshot?.generalForm?.fields[index].answer = PersonalAnswer(value: value, selectedOptionIDs: [], sourceRecordIDs: ids,
            confirmationState: .confirmed, modifiedByUser: true, reviewReasons: nil)
        snapshot?.generalForm?.fields[index].compositionDraft = nil
        snapshot?.updatedAt = .now
        await persist(in: context)
    }

    func reparseCurrentForm(in context: ModelContext) async {
        guard !isWorking, let current = snapshot, let form = current.form, let old = current.generalForm else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await fileStore.absoluteURL(for: form.relativePath, taskID: current.id)
            var fresh = try await formParser.parse(formURL: url)
            fresh.retainedAnswers = (old.retainedAnswers ?? []) + old.fields.compactMap { field in
                guard let answer = field.answer, answer.modifiedByUser || [.confirmed, .intentionallyBlank].contains(answer.confirmationState) else { return nil }
                return RetainedFormAnswer(id: UUID().uuidString, label: field.label, pageIndex: field.anchors.first?.pageIndex, answer: answer)
            }
            guard snapshot?.id == current.id else { return }
            snapshot?.generalForm = fresh
            snapshot?.versionMapping = nil
            snapshot?.fieldExplanationDraft = nil
            snapshot?.status = .reviewing
            snapshot?.lastError = "已重新识别。旧答案已保留，请逐项选择新位置后恢复。历史导出仍保留。"
            await persist(in: context)
        } catch { transientError = error.localizedDescription }
    }

    func restoreAnswer(_ retainedID: String, to fieldID: String, in context: ModelContext) async {
        guard var document = snapshot?.generalForm,
              let oldIndex = document.retainedAnswers?.firstIndex(where: { $0.id == retainedID }),
              let retained = document.retainedAnswers?[oldIndex],
              let index = document.fields.firstIndex(where: { $0.id == fieldID }) else { return }
        guard document.fields[index].answer?.modifiedByUser != true,
              document.fields[index].answer?.confirmationState != .confirmed else {
            transientError = "目标字段已有确认答案，请选择其他字段。"; return
        }
        var answer = retained.answer
        if answer.confirmationState != .intentionallyBlank { answer.confirmationState = .suggested }
        answer.reviewReasons = ["旧答案已恢复，请核对新的填写位置"]
        document.fields[index].answer = answer
        document.retainedAnswers?.remove(at: oldIndex)
        snapshot?.generalForm = document
        await persist(in: context)
    }

    func addManualPDFField(label: String, pageIndex: Int, rect: NormalizedRect, in context: ModelContext) async {
        guard var document = snapshot?.generalForm, document.effectiveFormat == .pdf,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let field = DynamicFormField(id: "manual-\(UUID().uuidString)", label: label, kind: .multilineText,
            options: [], constraints: FormFieldConstraints(), anchors: [],
            meaning: FieldMeaning(canonicalKey: nil, summary: nil, state: .userSpecified))
        document.fields.append(field)
        do {
            document = try regionAdjuster.adjustingRegion(fieldID: field.id, to: rect, pageIndex: pageIndex, in: document)
            snapshot?.generalForm = document
            await persist(in: context)
        } catch { transientError = "所选区域无效，请重新框选。" }
    }
}
