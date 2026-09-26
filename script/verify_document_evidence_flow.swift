import Foundation
import CoreGraphics
import CoreText
import PDFKit

@main
struct DocumentEvidenceVerify {
    static func check(_ condition: Bool, _ description: String) {
        if condition { print("PASS \(description)") }
        else { fatalError("FAIL \(description)") }
    }

    static func drawLine(_ text: String, in context: CGContext, x: CGFloat = 65, y: CGFloat = 700) {
        let font = CTFontCreateWithName("Helvetica" as CFString, 42, nil)
        let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }

    static func scannedImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 1000, height: 1200, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("Cannot create bitmap")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 1200))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        drawLine("SCANNED PAGE TWO", in: context, x: 70, y: 650)
        guard let image = context.makeImage() else { fatalError("Cannot create image") }
        return image
    }

    static func makePDF(at url: URL, modes: [Bool], blankLastPage: Bool = false) {
        var mediaBox = CGRect(x: 0, y: 0, width: 850, height: 1000)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fatalError("Cannot create PDF")
        }
        for (index, scanned) in modes.enumerated() {
            context.beginPDFPage(nil)
            if blankLastPage && index == modes.count - 1 {
                // Intentionally blank to verify partial failure is retained.
            } else if scanned {
                context.draw(scannedImage(), in: CGRect(x: 50, y: 80, width: 750, height: 850))
            } else {
                drawLine(index == 0 ? "NATIVE PAGE ONE" : "NATIVE PAGE THREE", in: context)
            }
            context.endPDFPage()
        }

        context.closePDF()
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentEvidenceVerify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, modes) in [("native", [false]), ("scanned", [true]), ("mixed", [false, true, false])] {
            let url = directory.appendingPathComponent("\(name).pdf")
            makePDF(at: url, modes: modes)
            check(PDFDocument(url: url)?.pageCount == modes.count, "\(name): generated PDF can open")
            var progress: [(Int, Int)] = []
            let result = try await DocumentProcessor.readStructuredContent(from: url, documentID: UUID()) { done, total in
                progress.append((done, total))
            }
            check(result.pages.count == modes.count, "\(name): page count")
            check(result.pages.map(\.pageNumber) == Array(1...modes.count), "\(name): one-based page order")
            check(result.pages.enumerated().allSatisfy { index, page in
                page.state == .succeeded && page.method == (modes[index] ? .ocr : .nativeText)
            }, "\(name): extraction method")
            check(progress.first?.0 == 0 && progress.last?.0 == modes.count, "\(name): progress")
            if modes.contains(true) {
                check(result.pages.first(where: { $0.method == .ocr })?.text.localizedCaseInsensitiveContains("SCANNED") == true,
                      "\(name): OCR text")
            }
        }

        let partialURL = directory.appendingPathComponent("partial.pdf")
        makePDF(at: partialURL, modes: [false, false], blankLastPage: true)
        let partial = try await DocumentProcessor.readStructuredContent(from: partialURL, documentID: UUID())
        check(partial.pages.count == 2 && partial.pages[0].state == .succeeded && partial.pages[1].state == .failed,
              "failed page does not discard extracted page")

        let cancelURL = directory.appendingPathComponent("cancel.pdf")
        makePDF(at: cancelURL, modes: [false, true])
        do {
            _ = try await DocumentProcessor.readStructuredContent(from: cancelURL, documentID: UUID()) { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            check(false, "cancellation stops import")
        } catch is CancellationError {
            check(true, "cancellation stops import")
        }
    }
}
