import Foundation

/// 分块只保存正文中的真实文本。ID 由文档、页序和块序构成，重新索引时稳定。
enum DocumentChunkBuilder {
    static func build(documentID: UUID, content: String, pages: [DocumentPage]) -> [DocumentChunk] {
        let inputs: [(Int?, String)] = pages.isEmpty
            ? [(nil, content)]
            : pages.sorted { $0.pageNumber < $1.pageNumber }
                .filter { $0.state == .succeeded && !$0.text.isEmpty }
                .map { ($0.pageNumber, $0.text) }
        var chunks: [DocumentChunk] = []
        var chapter: String?
        for (pageNumber, text) in inputs {
            let paragraphs = text.components(separatedBy: "\n\n")
            var cursor = 0
            var ordinal = 0
            for paragraph in paragraphs {
                let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                let start = cursor + paragraph.prefix(while: { $0.isWhitespace }).count
                cursor += paragraph.count + 2
                guard !trimmed.isEmpty else { continue }
                if let heading = trimmed.components(separatedBy: .newlines).first,
                   let match = DocumentSectionExtractor.heading(from: heading) {
                    chapter = match.title
                }
                let characters = Array(trimmed)
                var offset = 0
                while offset < characters.count {
                    let end = min(characters.count, offset + 1_200)
                    let part = String(characters[offset..<end])
                    ordinal += 1
                    let pageKey = pageNumber.map { "p\($0)" } ?? "legacy"
                    chunks.append(DocumentChunk(id: "\(documentID.uuidString)-\(pageKey)-c\(ordinal)",
                        documentID: documentID, startPage: pageNumber, endPage: pageNumber,
                        chapterTitle: chapter, text: part,
                        startOffset: start + offset, endOffset: start + end))
                    offset = end
                }
            }
        }
        return chunks
    }

    static func reference(in document: StudyDocument, matching text: String) -> SourceReference? {
        let candidates = document.chunks.isEmpty
            ? build(documentID: document.id, content: document.content, pages: document.pages)
            : document.chunks
        let terms = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return nil }
        let matching = candidates.first { $0.text.localizedCaseInsensitiveContains(terms) }
            ?? candidates.first { terms.localizedCaseInsensitiveContains($0.text) && $0.text.count >= 8 }
        guard let chunk = matching else { return nil }
        return SourceReference(documentID: document.id, chunkID: chunk.id,
            pageNumber: chunk.startPage, excerpt: String(chunk.text.prefix(240)))
    }
}
