import SwiftUI
import PDFKit

/// 引用只使用真实保存的页码；旧资料与未保留附件给出明确说明。
struct SourceLocationView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let reference: SourceReference

    private var document: StudyDocument? {
        store.snapshot.documents.first { $0.id == reference.documentID }
    }

    private var chunk: DocumentChunk? {
        document?.chunks.first { $0.id == reference.chunkID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(reference.pageLabel).font(.headline)
                    if let chunk {
                        if let chapter = chunk.chapterTitle { Text(chapter).font(.subheadline.weight(.semibold)) }
                        Text(chunk.text).textSelection(.enabled)
                    } else if !reference.excerpt.isEmpty {
                        Text(reference.excerpt).textSelection(.enabled)
                    } else if let document, !document.content.isEmpty {
                        Text(document.content).textSelection(.enabled)
                    }
                    if let document,
                       let pageNumber = reference.pageNumber,
                       let url = store.originalPDFURL(for: document) {
                        ManagedPDFPageView(url: url, pageNumber: pageNumber)
                            .frame(minHeight: 500)
                    } else if document == nil {
                        Text("来源资料已删除；仅显示引用时保存的摘录。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if document?.originalPDFFileName != nil {
                        Text("原 PDF 附件在当前设备不可用；仍可查看已保存文本与页码。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("原 PDF 未保留，无法打开原页面；仅显示已有文本与页码。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(document?.title ?? "来源资料已删除")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }
}

/// 原附件使用不可变文件名；同一视图刷新时复用文档，避免重复读盘并重置阅读位置。
@MainActor
private final class PDFPageCoordinator {
    private var loadedURL: URL?
    private var displayedPageNumber: Int?

    func update(_ view: PDFView, url: URL, pageNumber: Int) {
        if loadedURL != url || view.document == nil {
            guard let document = PDFDocument(url: url) else { return }
            view.document = document
            view.autoScales = true
            loadedURL = url
            displayedPageNumber = nil
        }
        guard displayedPageNumber != pageNumber,
              let page = view.document?.page(at: pageNumber - 1) else { return }
        view.go(to: page)
        displayedPageNumber = pageNumber
    }
}

#if os(macOS)
private struct ManagedPDFPageView: NSViewRepresentable {
    let url: URL
    let pageNumber: Int
    func makeCoordinator() -> PDFPageCoordinator { PDFPageCoordinator() }
    func makeNSView(context: Context) -> PDFView { PDFView() }
    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.update(view, url: url, pageNumber: pageNumber)
    }
}
#else
private struct ManagedPDFPageView: UIViewRepresentable {
    let url: URL
    let pageNumber: Int
    func makeCoordinator() -> PDFPageCoordinator { PDFPageCoordinator() }
    func makeUIView(context: Context) -> PDFView { PDFView() }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.update(view, url: url, pageNumber: pageNumber)
    }
}
#endif
