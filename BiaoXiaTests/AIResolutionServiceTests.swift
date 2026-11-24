import Foundation
import SwiftData
import XCTest
@testable import BiaoXia

final class PersonalDataOutboundShutdownTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RequestTrapURLProtocol.reset()
        URLProtocol.registerClass(RequestTrapURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(RequestTrapURLProtocol.self)
        RequestTrapURLProtocol.reset()
        super.tearDown()
    }

    func testLegacyClientsRejectWithoutStartingARequest() async {
        // 阳性对照：确认请求陷阱有效；虚构域名请求会在协议层被拒绝，不出网。
        do {
            _ = try await URLSession.shared.data(from: URL(string: "https://t04.invalid/control")!)
            XCTFail("阳性对照必须被拦截")
        } catch {
            XCTAssertGreaterThan(RequestTrapURLProtocol.requestCount, 0)
        }
        RequestTrapURLProtocol.reset()

        let candidate = FieldCandidate(
            fieldKey: .major,
            value: "虚构专业",
            sourceBlockIDs: [],
            score: 0.88,
            scoreReasons: ["字段标签匹配"]
        )
        let block = fictionalBlock(materialID: UUID())

        do {
            try await RelayAIResolutionService().resolve(
                candidates: [candidate],
                blocks: [block],
                resolvedFields: [],
                materials: []
            )
            XCTFail("旧字段消歧入口必须拒绝调用")
        } catch PersonalDataCloudDisabled.disabled {
            // Expected: the compatibility entry point cannot create a request.
        } catch {
            XCTFail("错误类型不正确：\(error.localizedDescription)")
        }

        do {
            try await RelayProfileExtractionService().extract(
                blocks: [block],
                resolvedFields: []
            )
            XCTFail("旧资料抽取入口必须拒绝调用")
        } catch PersonalDataCloudDisabled.disabled {
            // Expected: the compatibility entry point cannot create a request.
        } catch {
            XCTFail("错误类型不正确：\(error.localizedDescription)")
        }

        XCTAssertEqual(RequestTrapURLProtocol.requestCount, 0)
    }

    func testAppSourcesContainNoLegacyPersonalDataEndpoint() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = projectRoot.appending(path: "BiaoXia")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )
        )
        let swiftFiles = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(swiftFiles.isEmpty, "必须实际扫描 App 源码，不能空集合通过")
        let appSource = try swiftFiles.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertFalse(appSource.contains("v1/resolve-fields"))
        XCTAssertFalse(appSource.contains("v1/extract-profile"))
        XCTAssertFalse(appSource.contains("RelayClientToken"))
    }

    @MainActor
    func testNewRecognitionFlowsContinueDirectlyToLocalReview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = fictionalMaterial()
        let ocr = StubOCRService()

        let profileStore = ProfileLibraryStore(rootURL: root.appending(path: "profile-library"))
        let profileFlow = FlowStore(
            profileStore: PersonalProfileStore(rootURL: root.appending(path: "profile")),
            profileLibraryStore: profileStore,
            profileOCRService: ocr
        )
        profileFlow.profileLibrary.materials = [material]

        await profileFlow.startProfileRecognition()

        XCTAssertEqual(profileFlow.profileLibrary.status, .reviewing)
        XCTAssertEqual(profileFlow.profileLibrary.aiConsent, false)
        XCTAssertFalse(profileFlow.profileLibrary.ocrBlocks.isEmpty)
        let savedProfile = try await profileStore.load()
        XCTAssertEqual(savedProfile.status, .reviewing)

        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FillTaskRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let taskStore = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let taskFlow = FlowStore(fileStore: taskStore, ocrService: ocr)
        var task = FillTaskSnapshot.empty()
        task.materials = [material]
        task.status = .imported
        taskFlow.snapshot = task

        await taskFlow.startRecognition(in: context)

        XCTAssertEqual(taskFlow.snapshot?.status, .reviewing)
        XCTAssertEqual(taskFlow.snapshot?.aiConsent, false)
        XCTAssertFalse(taskFlow.snapshot?.ocrBlocks.isEmpty ?? true)
        let savedTask = try await taskStore.loadSnapshot(taskID: task.id)
        XCTAssertEqual(savedTask.status, .reviewing)
        XCTAssertEqual(RequestTrapURLProtocol.requestCount, 0)
    }

    @MainActor
    func testLegacyProfileCloudStateRecoversLocallyWithoutLosingData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryStore = ProfileLibraryStore(rootURL: root.appending(path: "library"))
        let material = fictionalMaterial()
        let block = fictionalBlock(materialID: material.id)
        var legacy = ProfileLibrarySnapshot.empty()
        legacy.status = .resolving
        legacy.aiConsent = true
        legacy.materials = [material]
        legacy.ocrBlocks = [block]
        let majorIndex = try XCTUnwrap(
            legacy.resolvedFields.firstIndex { $0.key == .major }
        )
        legacy.resolvedFields[majorIndex].value = "旧版已确认专业"
        legacy.resolvedFields[majorIndex].resolvedByAI = true
        legacy.profileItems = [ProfileItem(
            category: .skill,
            fieldID: "skill.local",
            label: "技能",
            value: "本地保留内容",
            confidence: 1,
            state: .confirmed,
            modifiedByUser: true
        )]
        try await libraryStore.save(legacy)
        let flow = FlowStore(
            profileStore: PersonalProfileStore(rootURL: root.appending(path: "profile")),
            profileLibraryStore: libraryStore,
            profileOCRService: StubOCRService()
        )

        await flow.loadProfile()

        XCTAssertEqual(flow.profileLibrary.status, .reviewing)
        XCTAssertEqual(flow.profileLibrary.aiConsent, false)
        XCTAssertEqual(
            flow.profileLibrary.resolvedFields.first { $0.key == .major }?.value,
            "旧版已确认专业"
        )
        XCTAssertTrue(
            flow.profileLibrary.resolvedFields.first { $0.key == .major }?.resolvedByAI == true
        )
        XCTAssertEqual(flow.profileLibrary.profileItems?.first?.value, "本地保留内容")
        let reloaded = try await libraryStore.load()
        XCTAssertEqual(reloaded.status, .reviewing)

        // 同一份虚构旧资料覆盖待授权、处理中和失败恢复，并验证保存后可继续填表。
        for status in [ProfileWorkflowStatus.awaitingAIConsent, .resolving, .failed, .recognizing] {
            legacy.status = status
            try await libraryStore.save(legacy)
            let profileStore = PersonalProfileStore(rootURL: root.appending(path: "profile-\(status.rawValue)"))
            let taskStore = TaskFileStore(rootURL: root.appending(path: "tasks-\(status.rawValue)"))
            let recoveredFlow = FlowStore(
                fileStore: taskStore,
                profileStore: profileStore,
                profileLibraryStore: libraryStore
            )
            await recoveredFlow.loadProfile()
            XCTAssertEqual(recoveredFlow.profileLibrary.status, .reviewing)
            XCTAssertEqual(recoveredFlow.profileLibrary.aiConsent, false)
            XCTAssertEqual(recoveredFlow.profileLibrary.ocrBlocks, legacy.ocrBlocks)
            XCTAssertEqual(recoveredFlow.profileLibrary.materials, legacy.materials)
            await recoveredFlow.acceptProfileAI()
            XCTAssertEqual(recoveredFlow.profileLibrary.status, .reviewing)
            await recoveredFlow.saveConfirmedProfile()
            XCTAssertNil(recoveredFlow.transientError)
            XCTAssertEqual(recoveredFlow.profileLibrary.status, .confirmed)
            let savedProfile = try await profileStore.load()
            XCTAssertTrue(savedProfile.hasInformation)
            XCTAssertTrue(savedProfile.informationItems.contains { $0.value == "本地保留内容" })
            let container = try ModelContainer(
                for: FillTaskRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            await recoveredFlow.createTask(in: ModelContext(container))
            XCTAssertNil(recoveredFlow.transientError)
            let taskID = try XCTUnwrap(recoveredFlow.snapshot?.id)
            let savedTask = try await taskStore.loadSnapshot(taskID: taskID)
            XCTAssertEqual(savedTask.resolvedFields.first { $0.key == .major }?.value, "旧版已确认专业")
        }
        XCTAssertEqual(RequestTrapURLProtocol.requestCount, 0)
    }

    @MainActor
    func testInterruptedRecognitionPreservesConfirmedCoreItemUntilConflictIsAccepted() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = fictionalMaterial()
        let block = OCRBlock(
            text: "专业：虚构学科", pageIndex: 0,
            boundingBox: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            confidence: 0.98, materialID: material.id
        )
        let originalSource = FieldSource(
            id: UUID(), materialID: material.id, materialName: material.displayName,
            pageIndex: 0, excerpt: "专业：人工确认专业", confidence: 1
        )
        let original = ProfileItem(
            category: .education, fieldID: FieldKey.major.rawValue, label: "专业",
            value: "人工确认专业", confidence: 1, state: .confirmed,
            modifiedByUser: true, sources: [originalSource],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        for status in [ProfileWorkflowStatus.recognizing, .failed] {
            let library = ProfileLibraryStore(rootURL: root.appending(path: "library-\(status.rawValue)"))
            let profiles = PersonalProfileStore(rootURL: root.appending(path: "profile-\(status.rawValue)"))
            let initial = FlowStore(
                profileStore: profiles, profileLibraryStore: library,
                profileOCRService: InterruptedOCRService(blocks: [block])
            )
            initial.profileLibrary.materials = [material]
            initial.profileLibrary.profileItems = [original]
            // 走真正的清空字段、保存 OCR 进度、抛错路径，不预填派生字段掩盖缺陷。
            await initial.startProfileRecognition()
            var interrupted = try await library.load()
            XCTAssertEqual(interrupted.status, .failed)
            XCTAssertEqual(interrupted.resolvedFields.first { $0.key == .major }?.value, "")
            XCTAssertEqual(interrupted.profileItems, [original])
            interrupted.status = status
            try await library.save(interrupted)

            let recovered = FlowStore(profileStore: profiles, profileLibraryStore: library)
            await recovered.loadProfile()
            XCTAssertEqual(recovered.profileLibrary.status, .reviewing)
            XCTAssertEqual(recovered.profileLibrary.ocrBlocks, [block])
            XCTAssertEqual(recovered.profileLibrary.profileItems?.first { $0.fieldID == "major" }, original)
            let field = try XCTUnwrap(recovered.profileLibrary.resolvedFields.first { $0.key == .major })
            XCTAssertEqual(field.value, original.value)
            XCTAssertTrue(field.modifiedByUser)
            XCTAssertEqual(field.sources, original.sources)
            let conflict = try XCTUnwrap(recovered.profileLibrary.pendingItems?.first { $0.fieldID == "major" })
            XCTAssertEqual(conflict.value, "虚构学科")
            XCTAssertEqual(conflict.state, .pending)

            await recovered.saveConfirmedProfile()
            let saved = try await profiles.load()
            XCTAssertEqual(saved.value(for: .major), original.value)
            XCTAssertEqual(saved.evidence?.first { $0.key == .major }?.sources, original.sources)
            XCTAssertEqual(saved.evidence?.first { $0.key == .major }?.modifiedByUser, true)

            // 接受冲突后字段和条目必须同步，否则保存会再次写回旧值。
            if status == .failed {
                recovered.acceptAllPendingProfileItems()
            } else {
                recovered.acceptPendingProfileItem(conflict)
            }
            await recovered.saveConfirmedProfile()
            let accepted = try await profiles.load()
            XCTAssertEqual(accepted.value(for: .major), conflict.value)
            XCTAssertEqual(accepted.evidence?.first { $0.key == .major }?.sources, conflict.sources)
            XCTAssertTrue(recovered.profileLibrary.pendingItems?.isEmpty == true)
            XCTAssertNil(recovered.transientError)
        }
        XCTAssertEqual(RequestTrapURLProtocol.requestCount, 0)
    }

    @MainActor
    func testRecoveryMergesNewOpenItemsWithoutDuplicatingExistingOrPendingItems() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let material = fictionalMaterial()
        func block(_ text: String, confidence: Double = 0.98) -> OCRBlock {
            OCRBlock(text: text, pageIndex: 0,
                     boundingBox: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                     confidence: confidence, materialID: material.id)
        }
        let blocks = [
            block("技能：原有虚构技能"), block("技能：待确认虚构技能", confidence: 0.7),
            block("技能：新增虚构技能"), block("课程：虚构课程｜学分：2｜成绩：90")
        ]
        let extractor = RuleBasedProfileItemExtractor()
        // 文件存储使用 ISO 8601 秒精度；固定条目时间，避免将精度截断误判为恢复改值。
        func storedItems(_ block: OCRBlock) -> [ProfileItem] {
            extractor.extractItems(from: [block], materials: [material]).map {
                var item = $0
                item.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
                return item
            }
        }
        let existingItems = storedItems(blocks[0])
        let pendingItems = storedItems(blocks[1])
        for hasExisting in [true, false] {
            let library = ProfileLibraryStore(rootURL: root.appending(path: "library-\(hasExisting)"))
            let profiles = PersonalProfileStore(rootURL: root.appending(path: "profile-\(hasExisting)"))
            var interrupted = ProfileLibrarySnapshot.empty()
            interrupted.status = .recognizing
            interrupted.materials = [material]
            interrupted.ocrBlocks = blocks
            interrupted.profileItems = hasExisting ? existingItems : []
            interrupted.pendingItems = pendingItems
            try await library.save(interrupted)
            let flow = FlowStore(profileStore: profiles, profileLibraryStore: library)
            await flow.loadProfile()
            XCTAssertEqual(flow.profileLibrary.status, .reviewing)
            XCTAssertEqual(flow.profileLibrary.profileItems?.count, 3)
            XCTAssertEqual(flow.profileLibrary.pendingItems, pendingItems)
            XCTAssertTrue(flow.profileLibrary.profileItems?.contains { $0.value == "新增虚构技能" } == true)
            XCTAssertTrue(flow.profileLibrary.profileItems?.contains { $0.category == .course } == true)
            if hasExisting {
                XCTAssertEqual(flow.profileLibrary.profileItems?.first, existingItems.first)
            }

            let firstRecovery = try await library.load()
            var retry = firstRecovery
            retry.status = .failed
            try await library.save(retry)
            await flow.loadProfile()
            XCTAssertEqual(flow.profileLibrary.profileItems, firstRecovery.profileItems)
            XCTAssertEqual(flow.profileLibrary.pendingItems, firstRecovery.pendingItems)
            XCTAssertEqual(flow.profileLibrary.ocrBlocks, blocks)
            await flow.saveConfirmedProfile()
            let saved = try await profiles.load()
            XCTAssertEqual(saved.informationItems.count, 3)
            XCTAssertNil(flow.transientError)
        }
        XCTAssertEqual(RequestTrapURLProtocol.requestCount, 0)
    }

    @MainActor
    func testLegacyTaskEntryPointsAndFailedRetryStayLocal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: FillTaskRecord.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        let taskStore = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let material = fictionalMaterial()
        var legacy = FillTaskSnapshot.empty()
        legacy.status = .awaitingAIConsent
        legacy.aiConsent = true
        legacy.materials = [material]
        legacy.recognitionCompletedPages = 1
        legacy.recognitionTotalPages = 1
        let majorIndex = try XCTUnwrap(
            legacy.resolvedFields.firstIndex { $0.key == .major }
        )
        legacy.resolvedFields[majorIndex].value = "旧任务保留专业"
        try await taskStore.saveSnapshot(legacy)
        let record = FillTaskRecord(snapshot: legacy)
        context.insert(record)
        try context.save()
        let flow = FlowStore(fileStore: taskStore)

        await flow.open(record, in: context)

        XCTAssertEqual(flow.snapshot?.status, .reviewing)
        XCTAssertEqual(flow.snapshot?.aiConsent, false)
        XCTAssertEqual(
            flow.snapshot?.resolvedFields.first { $0.key == .major }?.value,
            "旧任务保留专业"
        )

        flow.snapshot?.status = .resolving
        flow.snapshot?.aiConsent = true
        await flow.acceptAI(in: context)
        XCTAssertEqual(flow.snapshot?.status, .reviewing)
        XCTAssertEqual(flow.snapshot?.aiConsent, false)

        flow.snapshot?.status = .failed
        flow.snapshot?.aiConsent = true
        flow.snapshot?.lastError = "虚构失败"
        await flow.retry(in: context)
        XCTAssertEqual(flow.snapshot?.status, .reviewing)
        XCTAssertEqual(flow.snapshot?.aiConsent, false)
        XCTAssertNil(flow.snapshot?.lastError)
        XCTAssertEqual(RequestTrapURLProtocol.requestCount, 0)
    }
}

private func fictionalMaterial() -> MaterialAsset {
    MaterialAsset(
        displayName: "虚构材料.pdf",
        kind: .pdf,
        pageCount: 1,
        relativePath: "materials/fictional.pdf"
    )
}

private func fictionalBlock(materialID: UUID) -> OCRBlock {
    OCRBlock(
        text: "专业：虚构专业",
        pageIndex: 0,
        boundingBox: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
        confidence: 0.98,
        materialID: materialID
    )
}

private struct StubOCRService: OCRServing {
    func recognize(
        materials: [MaterialAsset],
        existingBlocks: [OCRBlock],
        progress: @escaping @Sendable (Int, Int, [OCRBlock]) async -> Void
    ) async throws -> [OCRBlock] {
        guard let material = materials.first else { return existingBlocks }
        let blocks = existingBlocks + [fictionalBlock(materialID: material.id)]
        await progress(1, 1, blocks)
        return blocks
    }
}

private struct InterruptedOCRService: OCRServing {
    let blocks: [OCRBlock]

    func recognize(
        materials: [MaterialAsset], existingBlocks: [OCRBlock],
        progress: @escaping @Sendable (Int, Int, [OCRBlock]) async -> Void
    ) async throws -> [OCRBlock] {
        await progress(1, 2, blocks)
        throw CancellationError()
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func reset() {
        lock.withLock { value = 0 }
    }

    func increment() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

private final class RequestTrapURLProtocol: URLProtocol, @unchecked Sendable {
    private static let counter = RequestCounter()

    static var requestCount: Int { counter.count }

    static func reset() {
        counter.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        counter.increment()
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.dataNotAllowed)
        )
    }

    override func stopLoading() {}
}
