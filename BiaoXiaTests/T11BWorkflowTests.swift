import Foundation
import SwiftData
import Testing
@testable import BiaoXia

@MainActor
@Suite(.serialized)
struct T11BWorkflowTests {
    @Test
    func reviewedExplanationIsPersistedAndManualFallbackRemainsAvailable() async throws {
        let matcher = T11BRematchingProbe()
        let fixture = try makeFixture(submitter: T11BExplanationSubmitter(), matcher: matcher)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.flow.createTask(in: fixture.context)
        await fixture.flow.importForm(from: fixture.formURL, in: fixture.context)
        await fixture.flow.prepareFieldExplanationReview(in: fixture.context)

        let draft = try #require(fixture.flow.snapshot?.fieldExplanationDraft)
        #expect(draft.texts.isEmpty == false)
        fixture.flow.allowAllExplanationTexts(in: fixture.context)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.flow.submitReviewedFieldExplanation(in: fixture.context)

        #expect(await matcher.calls == 2)
        #expect(fixture.flow.snapshot?.generalForm?.fields.first?.answer?.value == "Local match")
        #expect(fixture.flow.snapshot?.fieldExplanationDraft == nil)
        #expect(fixture.flow.snapshot?.checkpoint?.stage == .explained)
        #expect(fixture.flow.snapshot?.generalForm?.fields.contains { $0.meaning.state == .explained } == true)

        await fixture.flow.prepareFieldExplanationReview(in: fixture.context)
        await fixture.flow.continueWithoutRemoteExplanation(in: fixture.context)
        #expect(fixture.flow.snapshot?.status == .reviewing)
        #expect(fixture.flow.snapshot?.lastError?.contains("跳过云端解释") == true)
    }

    @Test
    func regionAndExplicitVersionMappingAreReusedOnlyForExactStructure() async throws {
        let fixture = try makeFixture(submitter: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.flow.loadProfile()
        fixture.flow.profile = .testFixture
        await fixture.flow.createTask(in: fixture.context)
        await fixture.flow.importForm(from: fixture.formURL, in: fixture.context)

        let fieldID = try #require(fixture.flow.snapshot?.generalForm?.fields.first?.id)
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05)
        await fixture.flow.adjustPDFRegion(
            fieldID: fieldID,
            pageIndex: 0,
            rect: rect,
            in: fixture.context
        )
        fixture.flow.updateFieldMeaning(fieldID: fieldID, canonicalKey: "employer", in: fixture.context)
        await fixture.flow.saveCurrentVersionMapping(in: fixture.context)

        let mapping = try #require(fixture.flow.snapshot?.versionMapping)
        #expect(mapping.anchors[fieldID]?.first?.rect == rect)
        #expect(mapping.fieldMeanings[fieldID]?.canonicalKey == "employer")
        #expect(fixture.flow.profileLibrary.formMappings?.count == 1)
        let restored = reopenedFlow(root: fixture.root, submitter: nil)
        await restored.loadProfile()
        restored.profile = .testFixture
        await restored.open(try #require(fixture.flow.activeRecord), in: fixture.context)
        #expect(restored.snapshot?.versionMapping?.id == mapping.id)
        #expect(restored.snapshot?.versionMapping?.fieldMeanings == mapping.fieldMeanings)
        #expect(restored.snapshot?.versionMapping?.anchors == mapping.anchors)
        await restored.createTask(in: fixture.context)
        await restored.importForm(from: fixture.formURL, in: fixture.context)
        #expect(restored.snapshot?.versionMapping?.id == mapping.id)
        #expect(restored.snapshot?.versionMapping?.fieldMeanings == mapping.fieldMeanings)
        #expect(restored.snapshot?.versionMapping?.anchors == mapping.anchors)
        #expect(restored.snapshot?.generalForm?.fields.first { $0.id == fieldID }?.anchors.first?.rect == rect)
        restored.profileLibrary.formMappings?[0].structureVersion += 1
        await restored.createTask(in: fixture.context)
        await restored.importForm(from: fixture.formURL, in: fixture.context)
        #expect(restored.snapshot?.versionMapping == nil)
        restored.profileLibrary.formMappings?[0].structureVersion = mapping.structureVersion
        restored.profileLibrary.formMappings?[0].documentFingerprint.value = "different-file"
        await restored.createTask(in: fixture.context)
        await restored.importForm(from: fixture.formURL, in: fixture.context)
        #expect(restored.snapshot?.versionMapping == nil)
    }

    @Test
    func removedTextAndManualAnswersSurviveFailureAndDiskReopen() async throws {
        let submitter = T11BFailOnceSubmitter()
        let fixture = try makeFixture(submitter: submitter)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.flow.createTask(in: fixture.context)
        await fixture.flow.importForm(from: fixture.formURL, in: fixture.context)
        await fixture.flow.prepareFieldExplanationReview(in: fixture.context)
        await fixture.flow.submitReviewedFieldExplanation(in: fixture.context)
        #expect(await submitter.calls == 0)
        fixture.flow.transientError = nil
        let original = try #require(fixture.flow.snapshot?.fieldExplanationDraft)
        let removed = try #require(original.texts.first)
        fixture.flow.removeExplanationText(removed.id, in: fixture.context)
        fixture.flow.allowAllExplanationTexts(in: fixture.context)
        fixture.flow.updateGeneralFormAnswer(fieldID: removed.fieldID, value: "Human answer", in: fixture.context)
        await fixture.flow.retrySaving(in: fixture.context)
        await fixture.flow.submitReviewedFieldExplanation(in: fixture.context)
        #expect(fixture.flow.snapshot?.status == .awaitingAIConsent)
        #expect(fixture.flow.snapshot?.fieldExplanationDraft != nil)
        #expect(await submitter.calls == 1)

        let restored = reopenedFlow(root: fixture.root, submitter: submitter)
        await restored.open(try #require(fixture.flow.activeRecord), in: fixture.context)
        let draft = try #require(restored.snapshot?.fieldExplanationDraft)
        #expect(draft.requestID == original.requestID)
        #expect(draft.texts.first { $0.id == removed.id }?.state == .removed)
        #expect(draft.texts.first { $0.id == removed.id }?.value == "")
        await restored.submitReviewedFieldExplanation(in: fixture.context)
        #expect(restored.snapshot?.checkpoint?.stage == .explained)
        #expect(restored.snapshot?.generalForm?.fields.first { $0.id == removed.fieldID }?.answer?.value == "Human answer")
        #expect(await submitter.calls == 2)
        await restored.prepareFieldExplanationReview(in: fixture.context)
        await restored.continueWithoutRemoteExplanation(in: fixture.context)
        #expect(restored.snapshot?.fieldExplanationDraft == nil)
        #expect(restored.snapshot?.status == .reviewing)
    }

    @Test
    func timedOutExplanationCanContinueManuallyWithoutLosingAnswers() async throws {
        let submitter = T11BFailOnceSubmitter()
        let fixture = try makeFixture(submitter: submitter)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.flow.createTask(in: fixture.context)
        await fixture.flow.importForm(from: fixture.formURL, in: fixture.context)
        let fieldID = try #require(fixture.flow.snapshot?.generalForm?.fields.first?.id)
        fixture.flow.updateGeneralFormAnswer(fieldID: fieldID, value: "Manual answer", in: fixture.context)
        await fixture.flow.prepareFieldExplanationReview(in: fixture.context)
        fixture.flow.allowAllExplanationTexts(in: fixture.context)
        await fixture.flow.submitReviewedFieldExplanation(in: fixture.context)
        #expect(await submitter.calls == 1)
        #expect(fixture.flow.snapshot?.status == .awaitingAIConsent)
        #expect(fixture.flow.snapshot?.fieldExplanationDraft != nil)
        await fixture.flow.continueWithoutRemoteExplanation(in: fixture.context)
        #expect(fixture.flow.snapshot?.status == .reviewing)
        #expect(fixture.flow.snapshot?.fieldExplanationDraft == nil)
        #expect(fixture.flow.snapshot?.generalForm?.fields.first { $0.id == fieldID }?.answer?.value == "Manual answer")
        #expect(await submitter.calls == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["T11B_LIVE_RELAY"] == "1"))
    func userReviewMatchesActualHTTPAfterFailureAndReopen() async throws {
        let environment = ProcessInfo.processInfo.environment
        let address = try #require(environment["BIAOXIA_RELAY_BASE_URL"])
        let endpoint = try #require(URL(string: address))
        let token = try #require(environment["BIAOXIA_RELAY_CLIENT_TOKEN"])
        T11BAuditedTransport.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [T11BAuditedTransport.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = RelayFieldExplanationService(endpoint: endpoint, clientToken: token, session: session)
        let fixture = try makeFixture(submitter: service)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.flow.createTask(in: fixture.context)
        let form = fixture.formURL.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "boundary/B03.pdf")
        await fixture.flow.importForm(from: form, in: fixture.context)
        await fixture.flow.prepareFieldExplanationReview(in: fixture.context)
        await fixture.flow.submitReviewedFieldExplanation(in: fixture.context)
        #expect(T11BAuditedTransport.bodies.isEmpty)
        fixture.flow.transientError = nil
        let draft = try #require(fixture.flow.snapshot?.fieldExplanationDraft)
        let removed = try #require(draft.texts.first)
        fixture.flow.removeExplanationText(removed.id, in: fixture.context)
        fixture.flow.allowAllExplanationTexts(in: fixture.context)
        await fixture.flow.retrySaving(in: fixture.context)
        let approved = try #require(fixture.flow.snapshot?.fieldExplanationDraft)
        let expected = try FieldExplanationRequestBuilder().build(from: approved)
        await fixture.flow.submitReviewedFieldExplanation(in: fixture.context)
        #expect(fixture.flow.snapshot?.lastError?.contains("云端解释失败") == true)
        let restored = reopenedFlow(root: fixture.root, submitter: service)
        await restored.open(try #require(fixture.flow.activeRecord), in: fixture.context)
        await restored.submitReviewedFieldExplanation(in: fixture.context)
        try #require(restored.snapshot?.checkpoint?.stage == .explained)
        #expect(restored.snapshot?.fieldExplanationDraft == nil)
        #expect(T11BAuditedTransport.bodies.count == 2)
        for body in T11BAuditedTransport.bodies {
            #expect(try JSONDecoder().decode(FieldExplanationRequest.self, from: body) == expected)
            let text = String(decoding: body, as: UTF8.self)
            for marker in [removed.value, "苏若岚", "FICTIONAL_HIDDEN", "FICTIONAL_COMMENT", "FICTIONAL_METADATA", "B03.pdf"] {
                #expect(!text.contains(marker))
            }
        }
        print("T11-B actual HTTP matched reviewed draft; requestID=\(draft.requestID); injectedTimeout=1; realResponse=1")
    }

    @Test
    func missingRequiredAndOldStructureCannotReportCompletion() async throws {
        let fixture = try makeFixture(submitter: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.flow.createTask(in: fixture.context)
        await fixture.flow.importForm(from: fixture.formURL, in: fixture.context)
        await fixture.flow.export(in: fixture.context)
        #expect(fixture.flow.snapshot?.status != .completed)
        #expect(fixture.flow.snapshot?.lastError?.contains("必填") == true)
        fixture.flow.snapshot?.generalForm?.structureVersion = 1
        await fixture.flow.export(in: fixture.context)
        #expect(fixture.flow.snapshot?.status != .completed)
        #expect(fixture.flow.snapshot?.lastError?.contains("旧版字段结构") == true)
        #expect(fixture.flow.snapshot?.generalForm != nil)
    }

    @Test
    func adjustingOneChoicePreservesOtherOptionAnchors() async throws {
        let fixture = try makeFixture(submitter: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.flow.createTask(in: fixture.context)
        await fixture.flow.importForm(from: fixture.formURL, in: fixture.context)
        let field = try #require(fixture.flow.snapshot?.generalForm?.fields.first { $0.options.count > 1 })
        let rect = NormalizedRect(x: 0.5, y: 0.5, width: 0.02, height: 0.02)
        await fixture.flow.adjustPDFRegion(fieldID: field.id, anchorIndex: 1, pageIndex: 0, rect: rect, in: fixture.context)
        let adjusted = try #require(fixture.flow.snapshot?.generalForm?.fields.first { $0.id == field.id })
        #expect(adjusted.anchors.count == field.anchors.count)
        #expect(adjusted.anchors[0] == field.anchors[0])
        #expect(adjusted.anchors[1].rect == rect)
        #expect(adjusted.anchors[2] == field.anchors[2])
    }

    private func reopenedFlow(root: URL, submitter: (any ReviewedFieldExplanationSubmitting)?) -> FlowStore {
        let flow = FlowStore(
            fileStore: TaskFileStore(rootURL: root.appending(path: "tasks")),
            profileLibraryStore: ProfileLibraryStore(rootURL: root.appending(path: "profile")),
            fieldExplanationSubmitter: submitter
        )
        flow.profile = .testFixture
        return flow
    }

    private func makeFixture(
        submitter: (any ReviewedFieldExplanationSubmitting)?,
        matcher: any AnswerMatching = LocalRuleAnswerMatcher()
    ) throws -> (root: URL, flow: FlowStore, context: ModelContext, formURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(component: UUID().uuidString, directoryHint: .isDirectory)
        let taskStore = TaskFileStore(rootURL: root.appending(path: "tasks"))
        let libraryStore = ProfileLibraryStore(rootURL: root.appending(path: "profile"))
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FillTaskRecord.self, configurations: configuration)
        let flow = FlowStore(
            fileStore: taskStore,
            profileLibraryStore: libraryStore,
            answerMatcher: matcher,
            fieldExplanationSubmitter: submitter
        )
        flow.profile = .testFixture
        let formURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "TestAssets/GeneralForms/debug/normal/F01-pdf.pdf")
        return (root, flow, ModelContext(container), formURL)
    }
}

private actor T11BExplanationSubmitter: ReviewedFieldExplanationSubmitting {
    func explain(draft: FieldExplanationDraft) async throws -> [String: FieldMeaning] {
        Dictionary(uniqueKeysWithValues: draft.fields.map {
            ($0.id, FieldMeaning(canonicalKey: "employer", summary: "单位", state: .explained))
        })
    }
}

private actor T11BFailOnceSubmitter: ReviewedFieldExplanationSubmitting {
    private(set) var calls = 0
    func explain(draft: FieldExplanationDraft) async throws -> [String: FieldMeaning] {
        _ = try FieldExplanationRequestBuilder().build(from: draft)
        calls += 1
        if calls == 1 { throw FieldExplanationRequestError.retryable("Injected timeout") }
        return Dictionary(uniqueKeysWithValues: draft.fields.map {
            ($0.id, FieldMeaning(canonicalKey: "employer", summary: "单位", state: .explained))
        })
    }
}

private final class T11BAuditedTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var capturedBodies: [Data] = []
    private nonisolated(unsafe) static var capturedServerLog: String?
    private var forwardingTask: Task<Void, Never>?

    static var bodies: [Data] { lock.withLock { capturedBodies } }
    static var serverLog: String? { lock.withLock { capturedServerLog } }
    static func reset() { lock.withLock { capturedBodies = []; capturedServerLog = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let injectFailure = Self.lock.withLock {
            Self.capturedBodies.append(body)
            return Self.capturedBodies.count == 1
        }
        if injectFailure {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        var forwarded = request
        forwarded.httpBodyStream = nil
        forwarded.httpBody = body
        // FC can return this invocation's log tail without enabling SLS storage.
        forwarded.setValue("Tail", forHTTPHeaderField: "X-Fc-Log-Type")
        forwardingTask = Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: forwarded)
                if let encoded = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Fc-Log-Result"),
                   let logData = Data(base64Encoded: encoded), let log = String(data: logData, encoding: .utf8) {
                    Self.lock.withLock { Self.capturedServerLog = log }
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() { forwardingTask?.cancel() }
}

private actor T11BRematchingProbe: AnswerMatching {
    private(set) var calls = 0
    func match(fields: [DynamicFormField], subjects: [ProfileSubject], records: [ProfileRecord]) async throws -> [String: PersonalAnswer] {
        calls += 1
        return Dictionary(uniqueKeysWithValues: fields.filter { $0.meaning.state == .explained }.map {
            ($0.id, PersonalAnswer(value: "Local match", selectedOptionIDs: [], sourceRecordIDs: [], confirmationState: .suggested, modifiedByUser: false))
        })
    }
}
