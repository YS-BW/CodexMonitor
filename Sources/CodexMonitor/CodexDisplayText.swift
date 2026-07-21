import Foundation

enum CodexDisplayText {
    private static let filesMarker = "# Files mentioned by the user:"
    private static let requestMarker = "## My request for Codex:"

    static func userRequest(from rawValue: String?, limit: Int = 90) -> String? {
        guard var value = rawValue else { return nil }

        if let filesRange = value.range(of: filesMarker, options: .caseInsensitive) {
            if let requestRange = value.range(
                of: requestMarker,
                options: .caseInsensitive,
                range: filesRange.upperBound..<value.endIndex
            ) {
                value = String(value[requestRange.upperBound...])
            } else {
                return "处理上传的文件"
            }
        }

        for line in value.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let label = trimmed
                .replacingOccurrences(of: #"^[#>*`\s]+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = label.lowercased()

            guard !lowercased.hasPrefix("files mentioned by the user"),
                  !lowercased.hasPrefix("my request for codex"),
                  !lowercased.hasPrefix("codex-clipboard-"),
                  !lowercased.hasPrefix("<image"),
                  !lowercased.hasPrefix("<attachment")
            else { continue }

            if let result = summary(trimmed, limit: limit) { return result }
        }
        return nil
    }

    static func userRequest(from textParts: [String], limit: Int = 90) -> String? {
        if let wrappedRequest = textParts.first(where: {
            $0.range(of: filesMarker, options: .caseInsensitive) != nil
        }) {
            return userRequest(from: wrappedRequest, limit: limit)
        }

        for part in textParts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("<image"), !trimmed.hasPrefix("<attachment") else { continue }
            if let result = userRequest(from: part, limit: limit) { return result }
        }
        return nil
    }

    static func summary(_ rawValue: String?, limit: Int = 90) -> String? {
        guard var value = rawValue else { return nil }
        value = value
            .replacingOccurrences(of: #"(?s)<(?:image|attachment)\b[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[#*_`>\[\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("<") else { return nil }
        return String(value.prefix(limit))
    }
}
