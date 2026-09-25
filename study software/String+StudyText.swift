import Foundation

extension String {
    nonisolated func compactedForStudyText(limit: Int) -> String {
        let compacted = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compacted.count > limit else { return compacted }
        return String(compacted.prefix(limit)) + "..."
    }
}
