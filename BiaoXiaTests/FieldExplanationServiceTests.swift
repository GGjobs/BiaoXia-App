import Foundation
import XCTest
@testable import BiaoXia

final class FieldExplanationServiceTests: XCTestCase {
    override func tearDown() {
        ExplanationURLProtocol.reset()
        super.tearDown()
    }

    func testDraftRequiresReviewAndSensitiveTextCannotBeAllowed() throws {
        let safe = makeField(id: "field-1", label: "最高学历毕业院校")
        let sensitive = makeField(id: "field-2", label: "联系电话 13800000001")
        let builder = FieldExplanationRequestBuilder()
        var draft = builder.makeDraft(fields: [safe, sensitive])

        XCTAssertFalse(draft.canSend)
        XCTAssertEqual(draft.texts.first { $0.fieldID == safe.id }?.state, .pendingReview)
        let blocked = try XCTUnwrap(draft.texts.first { $0.fieldID == sensitive.id })
        XCTAssertEqual(blocked.state, .blocked)
        draft.allow(blocked.id)
        XCTAssertEqual(draft.texts.first { $0.id == blocked.id }?.state, .blocked)
        XCTAssertThrowsError(try builder.build(from: draft)) {
            XCTAssertEqual($0 as? FieldExplanationRequestError, .blockedContent)
        }

        draft.remove(blocked.id)
        draft.allowAllPending()
        let request = try builder.build(from: draft)
        XCTAssertEqual(request.fields.map(\.id), [safe.id])
        XCTAssertEqual(request.fields.first?.label, "最高学历毕业院校")
    }

    func testRequestContainsNoAnswersAnchorsOrPersonalRecords() throws {
        var field = makeField(id: "widget:FICTIONAL_PRIVATE_NAME", label: "所属单位")
        field.options = [FormFieldOption(id: "FICTIONAL_PRIVATE_OPTION", label: "其他", exportValue: "private-export")]
        field.answer = PersonalAnswer(
            value: "虚构个人单位",
            selectedOptionIDs: [],
            sourceRecordIDs: [UUID()],
            confirmationState: .confirmed,
            modifiedByUser: true
        )
        field.anchors = [
            PDFFieldAnchor(
                pageIndex: 2,
                rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
                kind: .textRegion,
                widgetName: "personal-widget",
                confidence: 0.9
            )
        ]
        let builder = FieldExplanationRequestBuilder()
        var draft = builder.makeDraft(fields: [field])
        draft.allowAllPending()
        let data = try JSONEncoder().encode(builder.build(from: draft))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("虚构个人单位"))
        XCTAssertFalse(json.contains("sourceRecordIDs"))
        XCTAssertFalse(json.contains("anchors"))
        XCTAssertFalse(json.contains("personal-widget"))
        XCTAssertFalse(json.contains("pageIndex"))
        XCTAssertFalse(json.contains("FICTIONAL_PRIVATE_NAME"))
        XCTAssertFalse(json.contains("FICTIONAL_PRIVATE_OPTION"))
        XCTAssertFalse(json.contains("private-export"))
        let request = try JSONDecoder().decode(FieldExplanationRequest.self, from: data)
        XCTAssertEqual(request.fields.first?.id, "field-1")
        XCTAssertEqual(request.fields.first?.options.first?.id, "option-1")
    }

    func testDraftPersistsButRecoveryRechecksBlockedContent() throws {
        let builder = FieldExplanationRequestBuilder()
        var draft = builder.makeDraft(fields: [makeField(id: "field-1", label: "联系 13800000001")])
        var snapshot = FillTaskSnapshot.empty()
        snapshot.fieldExplanationDraft = draft

        let restored = try JSONDecoder().decode(
            FillTaskSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        draft = try XCTUnwrap(restored.fieldExplanationDraft)
        XCTAssertEqual(draft.texts.first?.state, .blocked)
        XCTAssertThrowsError(try builder.build(from: draft)) {
            XCTAssertEqual($0 as? FieldExplanationRequestError, .blockedContent)
        }
    }

    func testRelayResponseFeedsLocalMatcher() async throws {
        let responseRequestID = UUID()
        ExplanationURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/explain-fields")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let response = FieldExplanationResponse(
                schemaVersion: 1,
                requestId: responseRequestID,
                explanations: [
                    FieldExplanationResult(
                        fieldId: "field-1",
                        canonicalKey: "school",
                        summary: "就读院校",
                        confidence: 0.91,
                        reasonCode: "CONTEXT_MATCH"
                    )
                ]
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONEncoder().encode(response)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExplanationURLProtocol.self]
        let service = RelayFieldExplanationService(
            endpoint: URL(string: "https://relay.test")!,
            clientToken: "test-token",
            session: URLSession(configuration: configuration)
        )
        var field = makeField(id: "organization", label: "培养单位")
        let builder = FieldExplanationRequestBuilder()
        var draft = builder.makeDraft(fields: [field], requestID: responseRequestID)
        draft.allowAllPending()

        let meanings = try await service.explain(draft: draft)
        field.meaning = try XCTUnwrap(meanings[field.id])
        let subject = ProfileSubject(
            id: UUID(),
            kind: .selfPerson,
            relationshipToSelf: nil,
            displayName: "林知夏"
        )
        let components = ["fieldID": "school", "label": "学校", "value": "云岭未来大学"]
        let record = ProfileRecord(
            id: UUID(),
            subjectID: subject.id,
            kind: .education,
            businessKey: ProfileBusinessKey.make(
                kind: .education,
                subjectID: subject.id,
                components: components
            ),
            displayValue: "云岭未来大学",
            components: components,
            sources: [],
            confirmedComponentKeys: Set(components.keys),
            updatedAt: .now
        )
        let answer = try await LocalRuleAnswerMatcher().match(
            fields: [field],
            subjects: [subject],
            records: [record]
        )[field.id]

        XCTAssertEqual(field.meaning.canonicalKey, "school")
        XCTAssertEqual(answer?.value, "云岭未来大学")
        XCTAssertEqual(answer?.sourceRecordIDs, [record.id])
    }

    func testInvalidResponseAndRetryableStatusAreDistinguished() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExplanationURLProtocol.self]
        let service = RelayFieldExplanationService(
            endpoint: URL(string: "https://relay.test")!,
            clientToken: "test-token",
            session: URLSession(configuration: configuration)
        )
        let builder = FieldExplanationRequestBuilder()
        var draft = builder.makeDraft(fields: [makeField(id: "field-1", label: "院校")])
        draft.allowAllPending()

        ExplanationURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        do {
            _ = try await service.explain(draft: draft)
            XCTFail("429 必须可重试")
        } catch let error as FieldExplanationRequestError {
            guard case .retryable = error else { return XCTFail("错误类型不正确：\(error)") }
        }

        ExplanationURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        do {
            _ = try await service.explain(draft: draft)
            XCTFail("400 必须阻断")
        } catch let error as FieldExplanationRequestError {
            guard case .blocked = error else { return XCTFail("错误类型不正确：\(error)") }
        }
    }

    func testDelayedRelayResponseBeyondTwentySecondsStillSucceeds() async throws {
        let requestID = UUID()
        ExplanationURLProtocol.handler = { request in
            XCTAssertEqual(request.timeoutInterval, 50)
            // Controlled delay: no cloud charges or dependence on provider latency.
            Thread.sleep(forTimeInterval: 21)
            let response = FieldExplanationResponse(
                schemaVersion: 1, requestId: requestID,
                explanations: [FieldExplanationResult(
                    fieldId: "field-1", canonicalKey: "school", summary: "院校",
                    confidence: 0.91, reasonCode: "CONTEXT_MATCH"
                )]
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200,
                                   httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(response))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExplanationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = RelayFieldExplanationService(
            endpoint: URL(string: "https://relay.test")!, clientToken: "test-token", session: session
        )
        var draft = FieldExplanationRequestBuilder().makeDraft(
            fields: [makeField(id: "school-field", label: "院校")], requestID: requestID
        )
        draft.allowAllPending()
        let result = try await service.explain(draft: draft)
        XCTAssertEqual(result["school-field"]?.canonicalKey, "school")
    }

    func testTransportTimeoutRemainsRetryable() async throws {
        ExplanationURLProtocol.handler = { request in
            XCTAssertEqual(request.timeoutInterval, 50)
            throw URLError(.timedOut)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExplanationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = RelayFieldExplanationService(
            endpoint: URL(string: "https://relay.test")!, clientToken: "test-token", session: session
        )
        var draft = FieldExplanationRequestBuilder().makeDraft(
            fields: [makeField(id: "school-field", label: "院校")]
        )
        draft.allowAllPending()
        do {
            _ = try await service.explain(draft: draft)
            XCTFail("Transport timeout must not be reported as success")
        } catch let error as FieldExplanationRequestError {
            guard case .retryable = error else { return XCTFail("Timeout must allow retry") }
        }
    }

    private func makeField(id: String, label: String) -> DynamicFormField {
        DynamicFormField(
            id: id,
            label: label,
            section: nil,
            instructions: nil,
            kind: .singleLineText,
            options: [],
            constraints: FormFieldConstraints(),
            anchors: [],
            meaning: FieldMeaning(canonicalKey: nil, summary: nil, state: .needsReview),
            answer: nil
        )
    }
}

private final class ExplanationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var storedHandler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    static func reset() {
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
