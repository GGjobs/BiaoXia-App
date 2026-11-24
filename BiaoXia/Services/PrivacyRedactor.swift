import Foundation

struct PrivacyRedactor: Sendable {
    private let sensitivePatterns = [
        #"\b1[3-9]\d{9}\b"#,
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        #"(?:19|20)\d{2}[年./-]\d{1,2}[月./-]\d{1,2}日?"#,
        #"(?:学号|学生编号)[：:\s]*[A-Za-z0-9-]{6,24}"#,
        #"(?<![0-9A-Za-z])\d{17}[0-9Xx](?![0-9A-Za-z])"#
    ]

    func redact(
        _ context: String,
        resolvedFields: [ResolvedField],
        maximumLength: Int = 120
    ) -> String {
        var output = context
        for field in resolvedFields where !field.key.allowsCloudResolution {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2 else { continue }
            output = output.replacingOccurrences(of: value, with: "【已脱敏】")
        }
        for pattern in sensitivePatterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "【已脱敏】",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        output = output.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return String(output.prefix(maximumLength))
    }

    func tokenize(
        _ context: String,
        resolvedFields: [ResolvedField],
        maximumLength: Int = 2_000
    ) -> TokenizedText {
        var output = context
        var replacements: [String: String] = [:]
        var sequence = 0

        func replace(_ value: String, prefix: String) {
            guard value.count >= 2, output.localizedCaseInsensitiveContains(value) else { return }
            sequence += 1
            let token = "<\(prefix)_\(sequence)>"
            output = output.replacingOccurrences(of: value, with: token, options: .caseInsensitive)
            replacements[token] = value
        }

        for field in resolvedFields where !field.key.allowsCloudResolution {
            replace(field.value.trimmingCharacters(in: .whitespacesAndNewlines), prefix: "PRIVATE")
        }
        for (index, pattern) in sensitivePatterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let matches = regex.matches(
                in: output,
                range: NSRange(output.startIndex..., in: output)
            ).reversed()
            for match in matches {
                guard let range = Range(match.range, in: output) else { continue }
                let value = String(output[range])
                sequence += 1
                let token = "<SENSITIVE_\(index)_\(sequence)>"
                output.replaceSubrange(range, with: token)
                replacements[token] = value
            }
        }
        output = output.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return TokenizedText(text: String(output.prefix(maximumLength)), replacements: replacements)
    }
}

struct TokenizedText: Sendable, Equatable {
    let text: String
    let replacements: [String: String]

    func rehydrate(_ value: String) -> String {
        replacements.reduce(value) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }
}
