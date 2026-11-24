import Foundation
import PDFKit
import Testing
@testable import BiaoXia

/// Opt-in holdout evaluation. Gold answers are used only for scoring, never as
/// parser input or matcher hints. Each run writes a new report, preserving first results.
struct T12AcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["T12_ACCEPTANCE"] == "1"))
    func frozenPDFAcceptance() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let assets = root.appending(path: "TestAssets/GeneralForms")
        let manifest = try json(assets.appending(path: "manifest.json"))
        let profile = try json(assets.appending(path: "profiles/profile.json"))
        let subjects = [
            ProfileSubject(id: UUID(), kind: .selfPerson, relationshipToSelf: nil, displayName: "苏若岚"),
            ProfileSubject(id: UUID(), kind: .emergencyContact, relationshipToSelf: "联系人", displayName: "周星禾"),
            ProfileSubject(id: UUID(), kind: .familyMember, relationshipToSelf: "配偶", displayName: "陆青舟")
        ]
        // Convert the frozen fictional profile into the app's public record model.
        // This mapping is independent of every document's labels and gold answers.
        let keys = ["education.highest.school": "school", "education.highest.level": "educationLevel",
                    "education.major": "major", "education.graduation": "graduationDate",
                    "work.employer": "employer", "work.role": "role"]
        var records = (profile["facts"] as! [[String: Any]]).filter { !(($0["standard"] as? String)?.hasPrefix("education.highest.") ?? false) }.map { fact -> ProfileRecord in
            let standard = fact["standard"] as! String
            let owner = standard.hasPrefix("contact.") ? 1 : standard.hasPrefix("spouse.") ? 2 : 0
            let key = owner > 0 ? (standard.hasSuffix("name") ? "fullName" : "phone") : keys[standard] ?? standard
            let value = (fact["value"] as? String) ?? (fact["value"] as? [String])?.joined(separator: "、") ?? ""
            let components = [key: value]
            let kind: ProfileRecordKind = standard.hasPrefix("education.") ? .education : standard.hasPrefix("work.") ? .employment : .identity
            return ProfileRecord(id: UUID(), subjectID: subjects[owner].id, kind: kind,
                businessKey: ProfileBusinessKey.make(kind: kind, subjectID: subjects[owner].id, components: components),
                displayValue: value, components: components, sources: [],
                confirmedComponentKeys: fact["confirmed"] as? Bool == true ? [key] : [], updatedAt: .now)
        }
        for education in profile["educationRecords"] as! [[String: Any]] {
            let components = ["school": education["school"] as! String, "educationLevel": education["level"] as! String]
            records.append(ProfileRecord(id: UUID(), subjectID: subjects[0].id, kind: .education,
                businessKey: ProfileBusinessKey.make(kind: .education, subjectID: subjects[0].id, components: components),
                displayValue: components["school"]!, components: components, sources: [],
                confirmedComponentKeys: Set(components.keys), updatedAt: .now))
        }
        let exportDirectory = root.appending(path: "tmp/t12-validation/exports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        var rows: [[String: Any]] = []
        let engine = PDFFormEngine()
        for sample in manifest["samples"] as! [[String: Any]] where sample["format"] as? String == "PDF" && sample["kind"] as? String == "normal" {
            let source = assets.appending(path: sample["file"] as! String)
            let gold = try json(assets.appending(path: sample["answer"] as! String))["fields"] as! [[String: Any]]
            let start = Date()
            do {
                var document = try await engine.parse(formURL: source)
                let answers = try await LocalRuleAnswerMatcher().match(fields: document.fields, subjects: subjects, records: records)
                let original = try Data(contentsOf: source)
                var used = Set<String>()
                var scores: [[String: Any]] = []
                for expected in gold {
                    let location = expected["location"] as! [String: Any]
                    let r = location["rect"] as! [Double]
                    let pageSize = location["pageSize"] as! [Double]
                    let bounds = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
                    let label = expected["label"] as! String
                    let candidates = document.fields.filter { field in
                        !used.contains(field.id) && field.anchors.contains { anchor in
                            let actual = PDFFormEngine.pdfBounds(from: anchor.rect, pageBounds: CGRect(x: 0, y: 0, width: pageSize[0], height: pageSize[1]))
                            return anchor.pageIndex == location["page"] as! Int && bounds.insetBy(dx: -3, dy: -3).contains(CGPoint(x: actual.midX, y: actual.midY))
                        }
                    }
                    let field = candidates.first { $0.label.contains(label) }
                    if let field { used.insert(field.id) }
                    let expectedKind: FormFieldKind = switch expected["type"] as! String {
                    case "date": .date
                    case "single": .singleChoice
                    case "multi": .multipleChoice
                    case "multiline": .multilineText
                    default: .singleLineText
                    }
                    let expectedOptions = expected["options"] as! [String]
                    let optionRects = location["optionRects"] as? [String: [Double]] ?? [:]
                    let optionPositionsCorrect = field.map { candidate in
                        guard candidate.options.count == expectedOptions.count else { return false }
                        return candidate.options.enumerated().allSatisfy { index, option in
                            guard expectedOptions.contains(option.label), index < candidate.anchors.count,
                                  let r = optionRects[option.label] else { return false }
                            let actual = PDFFormEngine.pdfBounds(from: candidate.anchors[index].rect,
                                pageBounds: CGRect(x: 0, y: 0, width: pageSize[0], height: pageSize[1]))
                            return abs(actual.minX - r[0]) <= 3 && abs(actual.minY - r[1]) <= 3
                                && abs(actual.width - r[2]) <= 3 && abs(actual.height - r[3]) <= 3
                        }
                    } ?? false
                    let recognized = field?.kind == expectedKind && optionPositionsCorrect
                    let answer = field.flatMap { answers[$0.id] }
                    let automatic = answer?.confirmationState == .confirmed
                    let selected = field?.options.filter { answer?.selectedOptionIDs.contains($0.id) == true }.map(\.label) ?? []
                    let correct: Bool
                    if let values = expected["expected"] as? [String] { correct = Set(values) == Set(selected) }
                    else if let value = expected["expected"] as? String {
                        correct = expectedKind == .singleChoice ? selected == [value] : answer?.value == value
                    } else { correct = !automatic }
                    // Export exercises explicit human completion AFTER scoring.
                    // Gold/manual values never feed back into automatic matching.
                    if let field, let index = document.fields.firstIndex(where: { $0.id == field.id }) {
                        if automatic && correct {
                            document.fields[index].answer = answer
                        } else {
                            let value = expected["expected"] as? String ?? "人工确认"
                            let choices = (expected["expected"] as? [String]) ?? [value]
                            var selectedIDs = field.options.filter { choices.contains($0.label) }.map(\.id)
                            if !field.options.isEmpty && selectedIDs.isEmpty { selectedIDs = [field.options[0].id] }
                            document.fields[index].answer = PersonalAnswer(value: value, selectedOptionIDs: selectedIDs,
                                sourceRecordIDs: [], confirmationState: .confirmed, modifiedByUser: true)
                        }
                    }
                    scores.append(["id": expected["id"]!, "recognized": recognized,
                        "basicEligible": expected["basicEligible"]!, "automatic": automatic,
                        "correct": correct, "wrongAutomatic": automatic && !correct,
                        "actualLabel": field?.label ?? "", "actualKind": field?.kind.rawValue ?? "missing",
                        "state": answer?.confirmationState.rawValue ?? "missing"])
                }
                var exportResult: [String: Any] = [:]
                if used.count == gold.count && document.fields.allSatisfy({ $0.answer != nil }) {
                    do {
                        let destination = exportDirectory.appending(path: "\(sample["id"] as! String).pdf")
                        try await engine.write(document: document, sourceURL: source, destinationURL: destination)
                        let reopened = try #require(PDFDocument(url: destination))
                        let originalPDF = try #require(PDFDocument(url: source))
                        let text = (reopened.string ?? "").precomposedStringWithCompatibilityMapping
                        let writtenText = document.fields.filter { $0.options.isEmpty }.compactMap { $0.answer?.value }
                        let textPreserved = writtenText.allSatisfy { text.contains($0.precomposedStringWithCompatibilityMapping) }
                        let labelsPreserved = gold.allSatisfy { text.contains(($0["label"] as! String).precomposedStringWithCompatibilityMapping) }
                        let unchanged = try Data(contentsOf: source) == original
                        exportResult = ["path": destination.path, "passed": textPreserved && labelsPreserved && unchanged && reopened.pageCount == originalPDF.pageCount,
                                        "textPreserved": textPreserved, "labelsPreserved": labelsPreserved, "sourceUnchanged": unchanged]
                    } catch { exportResult = ["passed": false, "error": String(describing: error)] }
                } else { exportResult = ["passed": false, "error": "Missing or extra fields; full export not attempted"] }
                rows.append(["sample": sample["id"]!, "split": sample["split"]!, "fields": scores,
                    "extraFields": document.fields.filter { !used.contains($0.id) }.map(\.label),
                    "export": exportResult, "milliseconds": Date().timeIntervalSince(start) * 1000])
            } catch {
                rows.append(["sample": sample["id"]!, "split": sample["split"]!, "error": String(describing: error),
                    "standardFields": gold.count, "milliseconds": Date().timeIntervalSince(start) * 1000])
            }
        }
        // Boundary sources remain outside normal-set denominators.
        var boundaryResults: [[String: Any]] = []
        let boundary = try await engine.parse(formURL: assets.appending(path: "debug/boundary/B09.pdf"))
        let boundaryAnswers = try await LocalRuleAnswerMatcher().match(fields: boundary.fields, subjects: subjects, records: records)
        let boundaryGold = try json(assets.appending(path: "debug/answers/B09.json"))["fields"] as! [[String: Any]]
        for expected in boundaryGold {
            let label = expected["label"] as! String
            let field = try #require(boundary.fields.first { $0.label.contains(label) })
            let answer = try #require(boundaryAnswers[field.id])
            let passed = expected["expectedState"] as? String == "automatic"
                ? answer.confirmationState == .confirmed && answer.value == expected["expected"] as? String
                : answer.confirmationState != .confirmed
            #expect(passed)
            boundaryResults.append(["sample": "B09", "field": expected["id"]!, "passed": passed])
        }
        let longSource = assets.appending(path: "debug/boundary/B11.pdf")
        var longDocument = try await engine.parse(formURL: longSource)
        let longIndex = try #require(longDocument.fields.firstIndex { $0.label.contains("个人说明") })
        let overrides = try json(assets.appending(path: "debug/answers/B11.json"))["profileOverrides"] as! [String: String]
        longDocument.fields[longIndex].answer = PersonalAnswer(value: overrides["summary"], selectedOptionIDs: [], sourceRecordIDs: [], confirmationState: .confirmed, modifiedByUser: true)
        let longLayouts = try engine.preflight(document: longDocument, sourceURL: longSource)
        #expect(longLayouts.contains { $0.state == .overflow })
        let longOutput = exportDirectory.appending(path: "B11.pdf")
        await #expect(throws: PDFFormEngineError.self) {
            try await engine.write(document: longDocument, sourceURL: longSource, destinationURL: longOutput)
        }
        #expect(!FileManager.default.fileExists(atPath: longOutput.path))
        longDocument.fields[longIndex].answer?.value = "人工缩短后的说明"
        try await engine.write(document: longDocument, sourceURL: longSource, destinationURL: longOutput)
        let recovered = PDFDocument(url: longOutput)?.string?.contains("人工缩短后的说明") == true
        #expect(recovered)
        boundaryResults.append(["sample": "B11", "overflowBlockedAndManualRecovery": longLayouts.contains { $0.state == .overflow } && recovered])
        let report: [String: Any] = ["runID": UUID().uuidString, "date": ISO8601DateFormatter().string(from: .now), "samples": rows, "boundaryResults": boundaryResults,
            "denominators": manifest["denominators"]!, "scoring": "Exact gold type and label containment, anchor center within gold region ±3pt; immutable denominators; no gold hints to production modules"]
        let output = root.appending(path: "TestAssets/GeneralForms/evidence/t12/run-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
        for split in ["debug", "independent"] {
            let group = rows.filter { $0["split"] as? String == split }
            let fields = group.flatMap { $0["fields"] as? [[String: Any]] ?? [] }
            let denominator = split == "debug" ? 57 : 33
            let basicDenominator = split == "debug" ? 24 : 14
            #expect(Double(fields.filter { $0["recognized"] as? Bool == true }.count) / Double(denominator) >= 0.95)
            #expect(Double(fields.filter { $0["basicEligible"] as? Bool == true && $0["automatic"] as? Bool == true && $0["correct"] as? Bool == true }.count) / Double(basicDenominator) >= 0.90)
            #expect(group.allSatisfy { ($0["export"] as? [String: Any])?["passed"] as? Bool == true })
            #expect(fields.allSatisfy { $0["wrongAutomatic"] as? Bool == false })
        }
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
}
