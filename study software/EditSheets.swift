import SwiftUI

// MARK: - Edit Sheets

struct KnowledgeEditSheetWrapper: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var point: KnowledgePoint

    @State private var title: String = ""
    @State private var subject: String = ""
    @State private var summary: String = ""
    @State private var mastery: Double = 0.5
    @State private var isShowingDiscardConfirmation = false

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSummary: String {
        summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
    }

    private var validationMessage: String? {
        canSave ? nil : "标题不能为空"
    }

    private var hasUnsavedChanges: Bool {
        trimmedTitle != point.title.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmedSubject != point.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmedSummary != point.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            || abs(mastery - point.mastery) > 0.001
    }

    var body: some View {
        Group {
#if os(iOS)
            NavigationStack {
                formContent
                    .navigationTitle("编辑知识点")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { cancelEditing() }
                                .keyboardShortcut(.cancelAction)
                                .keyboardShortcut(.cancelAction)
                                .keyboardShortcut(.cancelAction)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { save() }
                                .disabled(!canSave)
                                .keyboardShortcut("s", modifiers: .command)
                                .help(validationMessage ?? "保存知识点修改")
                                .accessibilityHint(validationMessage ?? "保存知识点修改")
                        }
                    }
            }
#else
            VStack(spacing: 0) {
                formContent
                EditSheetDesktopActionBar(canSave: canSave, disabledReason: validationMessage ?? "请补全必填项") {
                    cancelEditing()
                } onSave: {
                    save()
                }
            }
            .frame(minWidth: 460, minHeight: 480)
            .background(StudyDesign.Gradients.pageBackdrop)
#endif
        }
        .onAppear {
            title = point.title
            subject = point.subject
            summary = point.summary
            mastery = point.mastery
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .confirmationDialog("放弃未保存的修改？", isPresented: $isShowingDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("当前知识点还有未保存的修改。")
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                EditSheetHero(
                    icon: "lightbulb.fill",
                    title: "整理知识点",
                    subtitle: "优化标题、科目和摘要，让后续检索与复习更准确。",
                    tint: StudyDesign.Colors.warning,
                    statusTitle: "掌握度",
                    statusValue: "\(Int(mastery * 100))%",
                    signals: [
                        ("对象", "知识点", "lightbulb.max.fill"),
                        ("科目", subject.isEmpty ? "待补全" : subject, "books.vertical.fill"),
                        ("摘要", summary.isEmpty ? "待填写" : "已记录", "text.alignleft")
                    ]
                )

                EditSheetPanel(title: "基础信息", icon: "text.badge.checkmark", tint: StudyDesign.Colors.warning) {
                    EditTextFieldRow(title: "标题", text: $title, prompt: "知识点标题", icon: "textformat", autoFocus: true)
                    if let validationMessage {
                        EditValidationHint(message: validationMessage)
                    }
                    EditTextFieldRow(title: "科目", text: $subject, prompt: "所属科目", icon: "books.vertical.fill")
                    EditTextFieldRow(title: "摘要", text: $summary, prompt: "用一两句话说明核心内容", icon: "text.alignleft", lineLimit: 3...8)
                    EditSliderRow(title: "掌握度", value: $mastery, tint: StudyDesign.Colors.success)
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudyDesign.Gradients.pageBackdrop)
    }

    private func save() {
        guard canSave else { return }
        store.updateKnowledgePoint(point, title: trimmedTitle, subject: trimmedSubject, summary: trimmedSummary, mastery: mastery)
        dismiss()
    }

    private func cancelEditing() {
        if hasUnsavedChanges {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }
}

struct MistakeEditSheetWrapper: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var mistake: Mistake

    @State private var question: String = ""
    @State private var correctAnswer: String = ""
    @State private var errorReason: String = ""
    @State private var isShowingDiscardConfirmation = false

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCorrectAnswer: String {
        correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedErrorReason: String {
        errorReason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedQuestion.isEmpty
    }

    private var validationMessage: String? {
        canSave ? nil : "题目不能为空"
    }

    private var hasUnsavedChanges: Bool {
        trimmedQuestion != mistake.question.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmedCorrectAnswer != mistake.correctAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            || trimmedErrorReason != mistake.errorReason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
#if os(iOS)
            NavigationStack {
                formContent
                    .navigationTitle("编辑错题")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { cancelEditing() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { save() }
                                .disabled(!canSave)
                                .keyboardShortcut("s", modifiers: .command)
                                .help(validationMessage ?? "保存错题修改")
                                .accessibilityHint(validationMessage ?? "保存错题修改")
                        }
                    }
            }
#else
            VStack(spacing: 0) {
                formContent
                EditSheetDesktopActionBar(canSave: canSave, disabledReason: validationMessage ?? "请补全必填项") {
                    cancelEditing()
                } onSave: {
                    save()
                }
            }
            .frame(minWidth: 500, minHeight: 500)
            .background(StudyDesign.Gradients.pageBackdrop)
#endif
        }
        .onAppear {
            question = mistake.question
            correctAnswer = mistake.correctAnswer
            errorReason = mistake.errorReason
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .confirmationDialog("放弃未保存的修改？", isPresented: $isShowingDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("当前错题还有未保存的修改。")
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                EditSheetHero(
                    icon: "xmark.circle.fill",
                    title: "修正错题记录",
                    subtitle: "把题目、答案和错因写清楚，复盘时才能快速定位问题。",
                    tint: StudyDesign.Colors.danger,
                    statusTitle: "错因",
                    statusValue: errorReason.isEmpty ? "待补全" : "已记录",
                    signals: [
                        ("题目", question.isEmpty ? "待填写" : "已记录", "doc.text.magnifyingglass"),
                        ("答案", correctAnswer.isEmpty ? "待填写" : "已记录", "checkmark.seal.fill"),
                        ("复盘", errorReason.isEmpty ? "需补充" : "可检索", "arrow.triangle.2.circlepath")
                    ]
                )

                EditSheetPanel(title: "错题内容", icon: "doc.text.magnifyingglass", tint: StudyDesign.Colors.danger) {
                    EditTextFieldRow(title: "题目", text: $question, prompt: "题目内容", icon: "doc.text.magnifyingglass", lineLimit: 2...6, autoFocus: true)
                    if let validationMessage {
                        EditValidationHint(message: validationMessage)
                    }
                    EditTextFieldRow(title: "正确答案", text: $correctAnswer, prompt: "参考答案", icon: "checkmark.seal.fill", lineLimit: 2...6)
                    EditTextFieldRow(title: "错因分析", text: $errorReason, prompt: "例如概念混淆、计算失误、审题遗漏", icon: "exclamationmark.magnifyingglass", lineLimit: 2...6)
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudyDesign.Gradients.pageBackdrop)
    }

    private func save() {
        guard canSave else { return }
        store.updateMistake(mistake, question: trimmedQuestion, correctAnswer: trimmedCorrectAnswer, errorReason: trimmedErrorReason)
        dismiss()
    }

    private func cancelEditing() {
        if hasUnsavedChanges {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }
}

struct ReviewTaskEditSheetWrapper: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var task: ReviewTask

    @State private var title: String = ""
    @State private var dueDate: Date = Date()
    @State private var priority: Int = 1
    @State private var isShowingDiscardConfirmation = false

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
    }

    private var validationMessage: String? {
        canSave ? nil : "任务标题不能为空"
    }

    private var hasUnsavedChanges: Bool {
        trimmedTitle != task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            || !Calendar.current.isDate(dueDate, inSameDayAs: task.dueDate)
            || priority != (task.priority ?? 1)
    }

    var body: some View {
        Group {
#if os(iOS)
            NavigationStack {
                formContent
                    .navigationTitle("编辑复习任务")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { cancelEditing() }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") { save() }
                                .disabled(!canSave)
                                .keyboardShortcut("s", modifiers: .command)
                                .help(validationMessage ?? "保存复习任务修改")
                                .accessibilityHint(validationMessage ?? "保存复习任务修改")
                        }
                    }
            }
#else
            VStack(spacing: 0) {
                formContent
                EditSheetDesktopActionBar(canSave: canSave, disabledReason: validationMessage ?? "请补全必填项") {
                    cancelEditing()
                } onSave: {
                    save()
                }
            }
            .frame(minWidth: 440, minHeight: 420)
            .background(StudyDesign.Gradients.pageBackdrop)
#endif
        }
        .onAppear {
            title = task.title
            dueDate = task.dueDate
            priority = task.priority ?? 1
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
        .confirmationDialog("放弃未保存的修改？", isPresented: $isShowingDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("当前复习任务还有未保存的修改。")
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                EditSheetHero(
                    icon: "calendar.badge.clock",
                    title: "调整复习任务",
                    subtitle: "更新任务名称、到期时间和优先级，保持今日安排可信。",
                    tint: StudyDesign.Colors.warning,
                    statusTitle: "优先级",
                    statusValue: "\(priority)",
                    signals: [
                        ("任务", title.isEmpty ? "待命名" : "已命名", "checklist"),
                        ("到期", dueDate.formatted(date: .abbreviated, time: .omitted), "calendar"),
                        ("提醒", dueDate.formatted(date: .omitted, time: .shortened), "clock.fill")
                    ]
                )

                EditSheetPanel(title: "任务设置", icon: "checklist", tint: StudyDesign.Colors.warning) {
                    EditTextFieldRow(title: "标题", text: $title, prompt: "复习任务标题", icon: "checklist", autoFocus: true)
                    if let validationMessage {
                        EditValidationHint(message: validationMessage)
                    }
                    EditDateRow(title: "到期日期", date: $dueDate)
                    EditPriorityRow(priority: $priority)
                }
            }
            .padding(StudyDesign.Spacing.wide)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudyDesign.Gradients.pageBackdrop)
    }

    private func save() {
        guard canSave else { return }
        store.updateReviewTask(task, title: trimmedTitle, dueDate: dueDate, priority: priority)
        dismiss()
    }

    private func cancelEditing() {
        if hasUnsavedChanges {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }
}

private struct EditSheetDesktopActionBar: View {
    let canSave: Bool
    let disabledReason: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            Label {
                Text("保存后会更新资料库与复习队列")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            } icon: {
                Image(systemName: "tray.full.fill")
                    .foregroundStyle(StudyDesign.Colors.info)
            }

            Spacer()
            Button(action: onCancel) {
                StudyActionPillLabel(title: "取消", systemImage: "xmark")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.labelSecondary, prominence: .soft, size: .compact, minWidth: 76))
            .keyboardShortcut(.cancelAction)

            Button(action: onSave) {
                StudyActionPillLabel(title: "保存", systemImage: "checkmark")
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, size: .compact, minWidth: 76))
            .disabled(!canSave)
            .keyboardShortcut("s", modifiers: .command)
            .help(canSave ? "保存修改" : disabledReason)
        }
        .padding(.horizontal, StudyDesign.Spacing.wide)
        .padding(.vertical, StudyDesign.Spacing.normal)
        .background(
            StudyDesign.Colors.chromeBackground
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(StudyDesign.Colors.accentHairline.opacity(0.68))
                        .frame(height: 1)
                }
        )
    }
}

private struct EditValidationHint: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(StudyDesign.Colors.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, StudyDesign.Spacing.tight)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact)
                    .stroke(StudyDesign.Colors.warning.opacity(0.16), lineWidth: 1)
            )
    }
}

private struct EditSheetHero: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    var statusTitle: String
    var statusValue: String
    var signals: [(title: String, value: String, icon: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                            .fill(StudyDesign.Colors.inputBackground)
                    )
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: 3)
                            .padding(.vertical, StudyDesign.Spacing.compact)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                            .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: StudyDesign.Spacing.normal)

                VStack(alignment: .trailing, spacing: StudyDesign.Spacing.micro) {
                    Text(statusTitle)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    Text(statusValue)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .padding(.horizontal, StudyDesign.Spacing.tight)
                .padding(.vertical, StudyDesign.Spacing.compact)
                .background(Capsule().fill(StudyDesign.Colors.inputBackground))
                .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 1))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: StudyDesign.Spacing.tight)], spacing: StudyDesign.Spacing.tight) {
                ForEach(Array(signals.enumerated()), id: \.offset) { _, signal in
                    EditSheetSignalTile(title: signal.title, value: signal.value, icon: signal.icon, tint: tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .fill(StudyDesign.Colors.cardBackground)
                RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous)
                    .fill(StudyDesign.Gradients.semanticWash(tint).opacity(0.20))
                Rectangle()
                    .fill(tint)
                    .frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: StudyDesign.Radius.medium, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color, radius: StudyDesign.Shadow.card.radius, y: StudyDesign.Shadow.card.y)
    }
}

private struct EditSheetPanel<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .center, spacing: StudyDesign.Spacing.tight) {
                HStack(spacing: StudyDesign.Spacing.tight) {
                    Image(systemName: icon)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous).fill(StudyDesign.Colors.inputBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                .stroke(tint.opacity(0.16), lineWidth: 1)
                        )
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                }

                Spacer()

                Text("EDITING")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, StudyDesign.Spacing.tight)
                    .padding(.vertical, StudyDesign.Spacing.micro)
                    .background(Capsule().fill(StudyDesign.Colors.inputBackground))
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.medium)
                .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
        )
        .shadow(color: StudyDesign.Shadow.card.color.opacity(0.72), radius: 6, y: 2)
    }
}

private struct EditTextFieldRow: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let icon: String
    var lineLimit: ClosedRange<Int> = 1...1
    var autoFocus = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(fieldTint)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .fill(StudyDesign.Colors.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                        .stroke(StudyDesign.Colors.accentHairline.opacity(0.56), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                HStack(spacing: StudyDesign.Spacing.compact) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    Spacer()
                    Text(fieldStatus)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(fieldTint)
                        .lineLimit(1)
                }

                TextField(prompt, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($isFocused)
                    .iOSTouchTarget()
                    .accessibilityLabel(title)
                    .accessibilityValue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写" : text)
                    .accessibilityHint("编辑\(title)")
            }
        }
        .editRowChrome(tint: StudyDesign.Colors.primary, isActive: isFocused)
        .onAppear {
            guard autoFocus else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                isFocused = true
            }
        }
    }

    private var fieldStatus: String {
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return count == 0 ? "待填写" : "\(count) 字"
    }

    private var fieldTint: Color {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? StudyDesign.Colors.labelTertiary : StudyDesign.Colors.info
    }
}

private struct EditSliderRow: View {
    let title: String
    @Binding var value: Double
    let tint: Color

    private var clampedValue: Double {
        min(max(value, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(value * 100))%")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }

            MasteryValueRail(value: clampedValue, tint: tint)

            HStack(spacing: StudyDesign.Spacing.tight) {
                EditValueButton(systemImage: "minus", tint: StudyDesign.Colors.labelSecondary, isDisabled: clampedValue <= 0) {
                    value = max(0, (clampedValue - 0.05).roundedToStep(0.05))
                }

                Text(masteryLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .frame(maxWidth: .infinity)

                EditValueButton(systemImage: "plus", tint: tint, isDisabled: clampedValue >= 1) {
                    value = min(1, (clampedValue + 0.05).roundedToStep(0.05))
                }
            }
        }
        .editRowChrome(tint: tint, isActive: true)
    }

    private var masteryLabel: String {
        switch clampedValue {
        case ..<0.25:
            return "需要重新建立"
        case ..<0.55:
            return "还需巩固"
        case ..<0.80:
            return "基本掌握"
        default:
            return "掌握稳定"
        }
    }
}

private struct MasteryValueRail: View {
    let value: Double
    let tint: Color

    private var filledSegments: Int {
        Int(ceil(min(max(value, 0), 1) * 10))
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...10, id: \.self) { index in
                RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                    .fill(index <= filledSegments ? tint : StudyDesign.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: StudyDesign.Radius.micro, style: .continuous)
                            .stroke(StudyDesign.Colors.accentHairline.opacity(index <= filledSegments ? 0.0 : 0.42), lineWidth: 1)
                    )
                    .frame(height: 10)
            }
        }
        .padding(StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.42), lineWidth: 1)
        )
        .accessibilityLabel("掌握度 \(Int(value * 100))%")
    }
}

private struct EditValueButton: View {
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    let action: () -> Void

    private var actionLabel: String {
        systemImage == "minus" ? "降低数值" : "提高数值"
    }

    private var helpText: String {
        guard isDisabled else { return actionLabel }
        return systemImage == "minus" ? "已经是最低值。" : "已经是最高值。"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(isDisabled ? StudyDesign.Colors.labelTertiary : tint)
                .frame(width: 32, height: 30)
                .background(Capsule().fill(StudyDesign.Colors.cardBackground))
                .overlay(
                    Capsule()
                        .stroke(StudyDesign.Colors.accentHairline.opacity(0.52), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .iOSTouchTarget()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.48 : 1)
        .help(helpText)
        .accessibilityLabel(actionLabel)
        .accessibilityHint(helpText)
    }
}

private extension Double {
    func roundedToStep(_ step: Double) -> Double {
        (self / step).rounded() * step
    }
}

private struct EditDateRow: View {
    let title: String
    @Binding var date: Date

    var body: some View {
        StudyDateControl(
            title: title,
            subtitle: "影响复习队列里的提醒顺序",
            icon: "clock.badge.checkmark",
            tint: StudyDesign.Colors.secondary,
            date: $date,
            displayedComponents: [.date, .hourAndMinute]
        )
    }
}

private struct EditPriorityRow: View {
    @Binding var priority: Int

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
            HStack {
                Text("优先级")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(priority)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(priority >= 4 ? StudyDesign.Colors.warning : StudyDesign.Colors.info)
            }

            HStack(spacing: StudyDesign.Spacing.compact) {
                ForEach(1...5, id: \.self) { level in
                    EditPriorityChip(level: level, isSelected: priority == level) {
                        priority = level
                    }
                }
            }
        }
        .editRowChrome()
    }
}

private struct EditPriorityChip: View {
    let level: Int
    let isSelected: Bool
    let action: () -> Void

    private var tint: Color {
        switch level {
        case 1...2:
            return StudyDesign.Colors.labelSecondary
        case 3:
            return StudyDesign.Colors.secondary
        case 4:
            return StudyDesign.Colors.warning
        default:
            return StudyDesign.Colors.danger
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(level)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                Circle()
                    .fill(isSelected ? StudyDesign.Colors.primary : tint.opacity(0.55))
                    .frame(width: 4, height: 4)
            }
            .foregroundStyle(isSelected ? StudyDesign.Colors.primary : StudyDesign.Colors.labelSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, StudyDesign.Spacing.compact)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                    .fill(isSelected ? StudyDesign.Colors.primary.opacity(0.14) : StudyDesign.Colors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                    .stroke(isSelected ? StudyDesign.Colors.primary.opacity(0.62) : StudyDesign.Colors.accentHairline.opacity(0.48), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .iOSTouchTarget()
        .help(isSelected ? "当前优先级 \(level)" : "设为优先级 \(level)")
        .accessibilityLabel("优先级 \(level)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint("设置复习任务优先级。")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EditSheetSignalTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(StudyDesign.Colors.cardBackground))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                Text(value)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .padding(.vertical, StudyDesign.Spacing.compact)
        .background(StudyDesign.Colors.cardBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(StudyDesign.Colors.accentHairline.opacity(0.54), lineWidth: 1)
        )
    }
}

private extension View {
    func editRowChrome(tint: Color? = nil, isActive: Bool = false) -> some View {
        self
            .studyInputChrome(size: .compact, tint: tint, isActive: isActive)
    }
}
