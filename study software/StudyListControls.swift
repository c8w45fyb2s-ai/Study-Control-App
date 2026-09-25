import SwiftUI

enum MasteryFilter: String, CaseIterable, Identifiable {
    case all = "全部掌握度"
    case needsReview = "薄弱"
    case learning = "学习中"
    case proficient = "熟练"
    case mastered = "已掌握"

    var id: String { rawValue }

    func matches(_ mastery: Double) -> Bool {
        switch self {
        case .all:
            return true
        case .needsReview:
            return mastery < 0.25
        case .learning:
            return mastery >= 0.25 && mastery < 0.5
        case .proficient:
            return mastery >= 0.5 && mastery < 0.8
        case .mastered:
            return mastery >= 0.8
        }
    }
}

enum KnowledgeSort: String, CaseIterable, Identifiable {
    case recent = "最近"
    case lowMastery = "掌握度低"
    case highMastery = "掌握度高"
    case title = "标题"

    var id: String { rawValue }
}

enum MistakeSort: String, CaseIterable, Identifiable {
    case recent = "最近"
    case oldest = "最早"
    case question = "题目"

    var id: String { rawValue }
}

enum ReviewSort: String, CaseIterable, Identifiable {
    case dueSoon = "到期时间"
    case priority = "优先级"
    case dueLatest = "最近安排"

    var id: String { rawValue }
}

let allSubjectsTitle = "全部科目"
let uncategorizedSubjectTitle = "未分类"

struct StudyInlineSearchField: View {
    @Binding var text: String
    var prompt: String
    var tint: Color = StudyDesign.Colors.info
    @FocusState private var isFocused: Bool

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isActive: Bool {
        !trimmedText.isEmpty
    }

    private var isHighlighted: Bool {
        isActive || isFocused
    }

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.tight) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isHighlighted ? tint : StudyDesign.Colors.labelSecondary)
                .frame(width: 24, height: 30)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .focused($isFocused)
                .submitLabel(.search)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif

            if !text.isEmpty {
                Button {
                    withAnimation(StudyDesign.Motion.animation(.fast)) {
                        text = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
#if os(iOS)
                .frame(width: 44, height: 44)
#else
                .frame(width: 32, height: 32)
#endif
                .help("清空搜索")
                .accessibilityLabel("清空搜索")
                .accessibilityHint("清除当前关键词")
            }
        }
        .frame(minHeight: 46)
        .padding(.horizontal, StudyDesign.Spacing.normal)
        .padding(.vertical, StudyDesign.Spacing.compact)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .fill(StudyDesign.Colors.inputBackground)
            )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                .stroke(
                    isFocused ? StudyDesign.Colors.primary : StudyDesign.Colors.inputHairline,
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .shadow(color: isFocused ? StudyDesign.Colors.primary.opacity(0.14) : .clear, radius: isFocused ? 4 : 0, y: 1)
        .animation(StudyDesign.Motion.animation(.fast), value: isActive)
        .animation(StudyDesign.Motion.animation(.fast), value: isFocused)
        .help(isActive ? "搜索：\(trimmedText)" : prompt)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt)
        .accessibilityValue(isActive ? trimmedText : "未输入")
        .accessibilityHint("输入关键词筛选当前列表")
    }
}

struct StudyFilterResetButton: View {
    var title: String = "重置筛选"
    let onReset: () -> Void

    var body: some View {
        Button(action: onReset) {
            Label(title, systemImage: "arrow.counterclockwise")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.labelSecondary, prominence: .soft, size: .compact, minWidth: 96))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityHint("清除当前搜索和筛选条件")
    }
}

extension View {
    @ViewBuilder
    func studyScrollBottomComfort(_ amount: CGFloat = StudyDesign.Spacing.relaxed) -> some View {
#if os(iOS)
        self.padding(.bottom, amount)
#else
        self
#endif
    }
}

struct ListFilterControls<Sort: CaseIterable & Identifiable & RawRepresentable & Hashable>: View where Sort.RawValue == String, Sort.AllCases: RandomAccessCollection {
    @Binding var selectedSubject: String
    var subjects: [String]
    @Binding var sort: Sort

    var body: some View {
#if os(iOS)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                controls
            }
        }
        .scrollClipDisabled()
        .accessibilityLabel("列表筛选控件")
        .accessibilityHint("横向滚动可调整科目和排序。")
#else
        HStack(spacing: StudyDesign.Spacing.normal) {
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("列表筛选控件")
#endif
    }

    @ViewBuilder
    private var controls: some View {
        StudyFilterMenu(
            label: "科目",
            title: selectedSubject,
            icon: "books.vertical",
            tint: StudyDesign.Colors.secondary,
            isActive: selectedSubject != allSubjectsTitle
        ) {
            ForEach(subjects, id: \.self) { subject in
                Button {
                    selectedSubject = subject
                } label: {
                    StudyFilterMenuOption(title: subject, isSelected: selectedSubject == subject)
                }
            }
        }

        StudyFilterMenu(
            label: "排序",
            title: sort.rawValue,
            icon: "arrow.up.arrow.down",
            tint: StudyDesign.Colors.info,
            isActive: true
        ) {
            ForEach(Array(Sort.allCases)) { option in
                Button {
                    sort = option
                } label: {
                    StudyFilterMenuOption(title: option.rawValue, isSelected: sort == option)
                }
            }
        }
    }

}

struct KnowledgeFilterControls: View {
    @Binding var selectedSubject: String
    var subjects: [String]
    @Binding var masteryFilter: MasteryFilter
    @Binding var sort: KnowledgeSort

    var body: some View {
#if os(iOS)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StudyDesign.Spacing.tight) {
                controls
            }
        }
        .scrollClipDisabled()
        .accessibilityLabel("知识点筛选控件")
        .accessibilityHint("横向滚动可调整科目、掌握度和排序。")
#else
        HStack(spacing: StudyDesign.Spacing.normal) {
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("知识点筛选控件")
#endif
    }

    @ViewBuilder
    private var controls: some View {
        StudyFilterMenu(
            label: "科目",
            title: selectedSubject,
            icon: "books.vertical",
            tint: StudyDesign.Colors.secondary,
            isActive: selectedSubject != allSubjectsTitle
        ) {
            ForEach(subjects, id: \.self) { subject in
                Button {
                    selectedSubject = subject
                } label: {
                    StudyFilterMenuOption(title: subject, isSelected: selectedSubject == subject)
                }
            }
        }

        StudyFilterMenu(
            label: "掌握度",
            title: masteryFilter.rawValue,
            icon: "gauge.with.dots.needle.50percent",
            tint: StudyDesign.Colors.warning,
            isActive: masteryFilter != .all
        ) {
            ForEach(MasteryFilter.allCases) { option in
                Button {
                    masteryFilter = option
                } label: {
                    StudyFilterMenuOption(title: option.rawValue, isSelected: masteryFilter == option)
                }
            }
        }

        StudyFilterMenu(
            label: "排序",
            title: sort.rawValue,
            icon: "arrow.up.arrow.down",
            tint: StudyDesign.Colors.info,
            isActive: true
        ) {
            ForEach(KnowledgeSort.allCases) { option in
                Button {
                    sort = option
                } label: {
                    StudyFilterMenuOption(title: option.rawValue, isSelected: sort == option)
                }
            }
        }
    }
}

private struct StudyFilterMenu<Content: View>: View {
    let label: String
    let title: String
    let icon: String
    var tint: Color = StudyDesign.Colors.secondary
    var isActive = false
    @ViewBuilder let content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: StudyDesign.Spacing.compact) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isActive ? tint : StudyDesign.Colors.labelSecondary)
                    .frame(width: 22, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.80)
                }

                Spacer(minLength: StudyDesign.Spacing.micro)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? tint : StudyDesign.Colors.labelTertiary)
                    .frame(width: 16, height: 16)
            }
            .padding(.leading, StudyDesign.Spacing.normal)
            .padding(.trailing, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .frame(minWidth: 140)
#if os(iOS)
            .frame(minHeight: 44)
#else
            .frame(minHeight: 40)
#endif
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .fill(StudyDesign.Colors.inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(isActive ? tint : StudyDesign.Colors.inputHairline, lineWidth: isActive ? 2 : 1)
            )
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                        .fill(tint.opacity(0.42))
                        .frame(width: 2)
                        .padding(.vertical, StudyDesign.Spacing.tight)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("调整\(label)：当前为 \(title)")
        .accessibilityLabel("\(label)：\(title)")
        .accessibilityHint("打开\(label)筛选菜单")
    }
}

private struct StudyFilterMenuOption: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }
}
