import Foundation
import Compression
import PDFKit
import UniformTypeIdentifiers
@preconcurrency import Vision

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum DocumentProcessor {
    static var supportedImportTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .pdf, .image]
        types.append(contentsOf: ["doc", "docx", "ppt", "pptx"].compactMap { UTType(filenameExtension: $0) })
        return types
    }

    static func readContent(from url: URL) async throws -> String {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let fileExtension = url.pathExtension.lowercased()

        if type?.conforms(to: .pdf) == true {
            return try readPDF(url)
        }

        if type?.conforms(to: .image) == true {
            return try await recognizeText(in: url)
        }

        if fileExtension == "docx" {
            return try readWordOpenXML(url)
        }

        if fileExtension == "pptx" {
            return try readPresentationOpenXML(url)
        }

#if os(macOS)
        if fileExtension == "doc" || fileExtension == "ppt" {
            return try readLegacyOfficeDocument(url)
        }
#else
        if fileExtension == "doc" || fileExtension == "ppt" {
            throw ProcessingError.unsupportedOfficeFile
        }
#endif

        if let text = try? String(contentsOf: url, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let text = try? String(contentsOf: url, encoding: .unicode), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        throw ProcessingError.unsupportedFile
    }

    private static func readPDF(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw ProcessingError.unsupportedFile }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let text = page.string {
                pages.append(text)
            }
        }
        let result = pages.joined(separator: "\n\n")
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessingError.emptyPDF
        }
        return result
    }

    private static func readWordOpenXML(_ url: URL) throws -> String {
        let entries = try archiveEntryNames(in: url)
        let documentEntries = orderedExistingEntries(
            preferred: [
                "word/document.xml",
                "word/footnotes.xml",
                "word/endnotes.xml"
            ],
            matching: entries.filter {
                $0.range(of: #"^word/(header|footer)[0-9]+\.xml$"#, options: .regularExpression) != nil
            }
        )

        return try readOfficeText(from: url, entries: documentEntries)
    }

    private static func readPresentationOpenXML(_ url: URL) throws -> String {
        let entries = try archiveEntryNames(in: url)
        let slideEntries = entries
            .filter { $0.range(of: #"^ppt/slides/slide[0-9]+\.xml$"#, options: .regularExpression) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let noteEntries = entries
            .filter { $0.range(of: #"^ppt/notesSlides/notesSlide[0-9]+\.xml$"#, options: .regularExpression) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return try readOfficeText(from: url, entries: slideEntries + noteEntries)
    }

    private static func orderedExistingEntries(preferred: [String], matching extraEntries: [String]) -> [String] {
        preferred + extraEntries.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func readOfficeText(from url: URL, entries: [String]) throws -> String {
        var sections: [String] = []
        for entry in entries {
            guard let xml = try? readArchiveEntry(entry, from: url) else { continue }
            let text = extractOfficeXMLText(xml)
            if !text.isEmpty {
                sections.append(text)
            }
        }

        let result = sections.joined(separator: "\n\n")
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessingError.emptyOfficeDocument
        }
        return result
    }

#if os(macOS)
    private static func readLegacyOfficeDocument(_ url: URL) throws -> String {
        if let text = try? runProcess("/usr/bin/textutil", arguments: ["-convert", "txt", "-stdout", url.path]),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        if let text = try? runProcess("/usr/bin/mdls", arguments: ["-raw", "-name", "kMDItemTextContent", url.path]),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           text.trimmingCharacters(in: .whitespacesAndNewlines) != "(null)" {
            return text
        }

        throw ProcessingError.unsupportedOfficeFile
    }

    private static func runProcess(_ executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
            throw ProcessingError.externalToolFailed(errorMessage)
        }

        return String(data: output, encoding: .utf8) ?? ""
    }
#endif

    private static func archiveEntryNames(in url: URL) throws -> [String] {
        try ZipArchive(url: url).entryNames
    }

    private static func readArchiveEntry(_ entry: String, from url: URL) throws -> String {
        let data = try ZipArchive(url: url).data(for: entry)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func extractOfficeXMLText(_ xml: String) -> String {
        let parser = XMLParser(data: Data(xml.utf8))
        let delegate = OfficeTextXMLParserDelegate()
        parser.delegate = delegate
        if parser.parse() {
            return normalizeExtractedText(delegate.text)
        }

        return normalizeExtractedText(
            xml.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        )
    }

    private static func normalizeExtractedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private final class OfficeTextXMLParserDelegate: NSObject, XMLParserDelegate {
        private var parts: [String] = []
        private var currentText = ""
        private var isCapturingText = false

        var text: String {
            parts.joined()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = localName(elementName)
            if name == "t" {
                isCapturingText = true
                currentText = ""
            } else if name == "tab" {
                parts.append("\t")
            } else if name == "br" || name == "cr" {
                parts.append("\n")
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCapturingText {
                currentText += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = localName(elementName)
            if name == "t" {
                parts.append(currentText)
                isCapturingText = false
                currentText = ""
            } else if name == "p" {
                parts.append("\n")
            }
        }

        private func localName(_ elementName: String) -> String {
            elementName.split(separator: ":").last.map(String.init) ?? elementName
        }
    }

    private struct ZipArchive {
        private struct Entry {
            var compressionMethod: UInt16
            var compressedSize: Int
            var uncompressedSize: Int
            var localHeaderOffset: Int
        }

        private let data: Data
        private let entries: [String: Entry]

        var entryNames: [String] {
            Array(entries.keys)
        }

        init(url: URL) throws {
            data = try Data(contentsOf: url)
            entries = try Self.readCentralDirectory(in: data)
        }

        func data(for name: String) throws -> Data {
            guard let entry = entries[name] else {
                throw ProcessingError.unsupportedOfficeFile
            }

            guard data.uint32(at: entry.localHeaderOffset) == 0x0403_4b50,
                  let nameLength = data.uint16(at: entry.localHeaderOffset + 26),
                  let extraLength = data.uint16(at: entry.localHeaderOffset + 28) else {
                throw ProcessingError.unsupportedOfficeFile
            }

            let payloadOffset = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
            guard payloadOffset >= 0,
                  entry.compressedSize >= 0,
                  payloadOffset + entry.compressedSize <= data.count else {
                throw ProcessingError.unsupportedOfficeFile
            }

            let compressed = data[payloadOffset..<(payloadOffset + entry.compressedSize)]
            switch entry.compressionMethod {
            case 0:
                return Data(compressed)
            case 8:
                return try inflate(compressed, expectedSize: entry.uncompressedSize)
            default:
                throw ProcessingError.unsupportedOfficeFile
            }
        }

        private static func readCentralDirectory(in data: Data) throws -> [String: Entry] {
            let endOffset = try endOfCentralDirectoryOffset(in: data)
            guard let entryCount = data.uint16(at: endOffset + 10),
                  let centralDirectorySize = data.uint32(at: endOffset + 12),
                  let centralDirectoryOffset = data.uint32(at: endOffset + 16) else {
                throw ProcessingError.unsupportedOfficeFile
            }

            var entries: [String: Entry] = [:]
            var offset = Int(centralDirectoryOffset)
            let directoryEnd = offset + Int(centralDirectorySize)
            guard offset >= 0, directoryEnd <= data.count else {
                throw ProcessingError.unsupportedOfficeFile
            }

            for _ in 0..<Int(entryCount) {
                guard offset + 46 <= directoryEnd,
                      data.uint32(at: offset) == 0x0201_4b50,
                      let compressionMethod = data.uint16(at: offset + 10),
                      let compressedSize = data.uint32(at: offset + 20),
                      let uncompressedSize = data.uint32(at: offset + 24),
                      let fileNameLength = data.uint16(at: offset + 28),
                      let extraFieldLength = data.uint16(at: offset + 30),
                      let fileCommentLength = data.uint16(at: offset + 32),
                      let localHeaderOffset = data.uint32(at: offset + 42) else {
                    throw ProcessingError.unsupportedOfficeFile
                }

                let nameOffset = offset + 46
                let nameEnd = nameOffset + Int(fileNameLength)
                guard nameEnd <= directoryEnd else {
                    throw ProcessingError.unsupportedOfficeFile
                }

                let nameData = data[nameOffset..<nameEnd]
                if let name = String(data: nameData, encoding: .utf8) {
                    entries[name] = Entry(
                        compressionMethod: compressionMethod,
                        compressedSize: Int(compressedSize),
                        uncompressedSize: Int(uncompressedSize),
                        localHeaderOffset: Int(localHeaderOffset)
                    )
                }

                offset = nameEnd + Int(extraFieldLength) + Int(fileCommentLength)
            }

            return entries
        }

        private static func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
            guard data.count >= 22 else {
                throw ProcessingError.unsupportedOfficeFile
            }

            let searchLength = min(data.count, 65_557)
            let lowerBound = data.count - searchLength
            var offset = data.count - 22
            while offset >= lowerBound {
                if data.uint32(at: offset) == 0x0605_4b50 {
                    return offset
                }
                offset -= 1
            }

            throw ProcessingError.unsupportedOfficeFile
        }

        private func inflate(_ compressed: Data.SubSequence, expectedSize: Int) throws -> Data {
            if expectedSize == 0 {
                return Data()
            }

            var output = [UInt8](repeating: 0, count: expectedSize)
            let decodedCount = compressed.withUnsafeBytes { compressedBuffer in
                guard let source = compressedBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }

                return compression_decode_buffer(
                    &output,
                    output.count,
                    source,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }

            guard decodedCount == expectedSize else {
                throw ProcessingError.unsupportedOfficeFile
            }

            return Data(output)
        }
    }

    private static func recognizeText(in url: URL) async throws -> String {
#if os(macOS)
        guard let image = NSImage(contentsOf: url), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProcessingError.unsupportedFile
        }
#elseif os(iOS)
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            throw ProcessingError.unsupportedFile
        }
#else
        throw ProcessingError.unsupportedFile
#endif

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let text = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: ProcessingError.emptyOCR)
                } else {
                    continuation.resume(returning: text)
                }
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    enum ProcessingError: LocalizedError {
        case unsupportedFile
        case emptyPDF
        case emptyOCR
        case emptyOfficeDocument
        case unsupportedOfficeFile
        case externalToolFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFile:
                return "暂不支持该文件类型，请先使用文本、PDF、图片、Word 或 PPT。"
            case .emptyPDF:
                return "没有从 PDF 中提取到文字。扫描版 PDF 请先转成图片再导入。"
            case .emptyOCR:
                return "图片 OCR 没有识别到文字，请换一张更清晰的图片。"
            case .emptyOfficeDocument:
                return "没有从 Word/PPT 中提取到文字，请确认文件内包含可复制文本。"
            case .unsupportedOfficeFile:
                return "暂时无法读取该 Word/PPT 文件。请优先使用 .docx 或 .pptx，旧版 .doc/.ppt 可另存为新版格式后再导入。"
            case .externalToolFailed(let message):
                return message.isEmpty ? "系统文档解析工具运行失败。" : message
            }
        }
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return withUnsafeBytes { buffer in
            guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return UInt16(baseAddress[offset]) | (UInt16(baseAddress[offset + 1]) << 8)
        }
    }

    func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return withUnsafeBytes { buffer in
            guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return UInt32(baseAddress[offset])
                | (UInt32(baseAddress[offset + 1]) << 8)
                | (UInt32(baseAddress[offset + 2]) << 16)
                | (UInt32(baseAddress[offset + 3]) << 24)
        }
    }
}
