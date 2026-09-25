import SwiftUI

// MARK: - F 模块：资料一级入口
//
// 页面归属（F 的导航改造）：
// 导入、待确认、知识点、错题、资料章节、知识图谱。
// 「待确认」的数量是这一入口的提示来源（标签栏徽标 + 本页第一张卡片）。

struct StudyLibraryRootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                StudyPageHeader(
                    title: "资料",
                    subtitle: "导入、待确认、知识点与错题",
                    icon: "books.vertical",
                    tint: StudyDesign.Colors.primary,
                    compact: true
                )

                importCard
                if hasLearningAssets {
                    assetsCard
                } else {
                    emptyAssetsCard
                }
            }
            .padding(.horizontal, StudyDesign.Spacing.wide)
            .padding(.top, StudyDesign.Spacing.normal)
            .padding(.bottom, StudyDesign.Spacing.section)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(StudyDesign.Gradients.pageBackdrop)
        .navigationTitle("资料")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    // MARK: 导入与待确认

    private var importCard: some View {
        StudyHomeCard(
            title: "导入与待确认",
            subtitle: importSubtitle,
            systemImage: "square.and.arrow.down",
            tint: StudyDesign.Colors.info
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                if pendingDraftCount > 0 {
                    StudyHomeNoticeLine(
                        text: "有 \(pendingDraftCount) 条整理结果等着确认，确认后才会写入学习系统。",
                        systemImage: "checklist.unchecked",
                        tint: StudyDesign.Colors.warning
                    )
                }

                NavigationLink(value: AppSection.importData) {
                    StudyRootNavigationRow(
                        title: AppSection.importData.rawValue,
                        subtitle: "导入笔记、题目和课程资料",
                        systemImage: AppSection.importData.icon,
                        tint: StudyDesign.Colors.info,
                        countText: store.snapshot.documents.isEmpty ? nil : "\(store.snapshot.documents.count) 份"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: AppSection.drafts) {
                    StudyRootNavigationRow(
                        title: AppSection.drafts.rawValue,
                        subtitle: "审阅整理结果，再写入学习系统",
                        systemImage: AppSection.drafts.icon,
                        tint: StudyDesign.Colors.warning,
                        countText: pendingDraftCount > 0 ? "\(pendingDraftCount)" : nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var importSubtitle: String {
        if pendingDraftCount > 0 {
            return "待确认 \(pendingDraftCount) 条"
        }
        if store.snapshot.documents.isEmpty {
            return "还没有导入资料"
        }
        return "已导入 \(store.snapshot.documents.count) 份资料"
    }

    // MARK: 学习资产

    private var assetsCard: some View {
        StudyHomeCard(
            title: "学习资产",
            subtitle: assetsSubtitle,
            systemImage: "lightbulb",
            tint: StudyDesign.Colors.secondary
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                NavigationLink(value: AppSection.knowledge) {
                    StudyRootNavigationRow(
                        title: AppSection.knowledge.rawValue,
                        subtitle: "概念与掌握度",
                        systemImage: AppSection.knowledge.icon,
                        tint: StudyDesign.Colors.primary,
                        countText: store.snapshot.knowledgePoints.isEmpty ? nil : "\(store.snapshot.knowledgePoints.count)"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: AppSection.mistakes) {
                    StudyRootNavigationRow(
                        title: AppSection.mistakes.rawValue,
                        subtitle: "错题与薄弱项",
                        systemImage: AppSection.mistakes.icon,
                        tint: StudyDesign.Colors.danger,
                        countText: store.snapshot.mistakes.isEmpty ? nil : "\(store.snapshot.mistakes.count)"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: AppSection.documentSections) {
                    StudyRootNavigationRow(
                        title: AppSection.documentSections.rawValue,
                        subtitle: "按资料章节定位内容",
                        systemImage: AppSection.documentSections.icon,
                        tint: StudyDesign.Colors.secondary,
                        countText: sectionCount > 0 ? "\(sectionCount)" : nil
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: AppSection.knowledgeGraph) {
                    StudyRootNavigationRow(
                        title: AppSection.knowledgeGraph.rawValue,
                        subtitle: "知识点之间的联系",
                        systemImage: AppSection.knowledgeGraph.icon,
                        tint: StudyDesign.Colors.info,
                        countText: nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyAssetsCard: some View {
        StudyHomeCard(
            title: "学习资产",
            subtitle: "还没有知识点或错题",
            systemImage: "lightbulb",
            tint: StudyDesign.Colors.labelSecondary
        ) {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                Text("导入资料并确认整理结果后，知识点、错题和资料章节会出现在这里。")
                    .font(StudyDesign.Typography.supporting)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                NavigationLink(value: AppSection.importData) {
                    StudyRootNavigationRow(
                        title: "去导入资料",
                        subtitle: "支持笔记、题目和课程资料",
                        systemImage: "square.and.arrow.down",
                        tint: StudyDesign.Colors.info,
                        countText: nil
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var pendingDraftCount: Int {
        store.snapshot.drafts.count + store.snapshot.pendingAIPlanDrafts.count
    }

    private var hasLearningAssets: Bool {
        !store.snapshot.knowledgePoints.isEmpty
            || !store.snapshot.mistakes.isEmpty
            || !store.snapshot.documents.isEmpty
    }

    private var sectionCount: Int {
        DocumentSectionExtractor.extractAll(from: store.snapshot).count
    }

    private var assetsSubtitle: String {
        let knowledge = store.snapshot.knowledgePoints.count
        let mistakes = store.snapshot.mistakes.count
        return "知识点 \(knowledge) · 错题 \(mistakes)"
    }
}
