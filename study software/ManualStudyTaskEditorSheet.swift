import SwiftUI

/// 手动学习任务编辑器。只维护标题、预计分钟和可选到期日。
/// 表单只维护本地草稿，提交由 AppStore 统一保存。
struct ManualStudyTaskEditorSheet: View {
    var planningTimeZoneIdentifier: String
    var now: Date
    var initialTask: ManualStudyTask?
    var onSave: (ManualStudyTask) -> StoreChangeResult
    var onDelete: ((UUID) -> StoreChangeResult)?
    var onCancel: () -> Void

    @State private var id: UUID
    @State private var title: String
    @State private var estimatedMinutesText: String
    @State private var dueDate: Date
    @State private var hasDueDate: Bool
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var confirmsDelete = false

    init(
        planningTimeZoneIdentifier: String,
        now: Date,
        initialTask: ManualStudyTask? = nil,
        onSave: @escaping (ManualStudyTask) -> StoreChangeResult,
        onDelete: ((UUID) -> StoreChangeResult)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.planningTimeZoneIdentifier = planningTimeZoneIdentifier
        self.now = now
        self.initialTask = initialTask
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _id = State(initialValue: initialTask?.id ?? UUID())
        _title = State(initialValue: initialTask?.title ?? "")
        _estimatedMinutesText = State(initialValue: String(initialTask?.estimatedMinutes ?? 15))
        _dueDate = State(initialValue: initialTask?.dueDate ?? now)
        _hasDueDate = State(initialValue: initialTask?.dueDate != nil)
    }

    private var parsedMinutes: Int? {
        Int(estimatedMinutesText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var hasValidTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasValidMinutes: Bool {
        guard let parsedMinutes else { return false }
        return ManualStudyTask.estimatedMinutesRange.contains(parsedMinutes)
    }

    private var normalizedDueDate: Date? {
        guard hasDueDate else { return nil }
        let context = PlanningContext(now: now, timeZoneIdentifier: planningTimeZoneIdentifier)
        return context.dayKey(for: dueDate).startOfDay(calendar: context.calendar)
    }

    private var task: ManualStudyTask {
        ManualStudyTask(
            id: id,
            title: title,
            note: initialTask?.note ?? "",
            dueDate: normalizedDueDate,
            estimatedMinutes: parsedMinutes ?? 15,
            createdAt: initialTask?.createdAt ?? now
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("任务标题", text: $title)
                        .studyInputChrome()
                        .accessibilityLabel("手动任务标题")
                    if !hasValidTitle {
                        Text("请输入标题。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.warning)
                    }
                }

                Section("预计分钟") {
                    TextField("分钟数", text: $estimatedMinutesText)
                        .studyInputChrome()
                        .accessibilityLabel("预计学习分钟")
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                    Text("请输入 \(ManualStudyTask.estimatedMinutesRange.lowerBound)–\(ManualStudyTask.estimatedMinutesRange.upperBound) 的整数。预计时间只用于排期，不计入实际学习分钟。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !hasValidMinutes {
                        Text("分钟数必须是范围内的正整数。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.warning)
                    }
                }

                Section("到期日") {
                    Toggle("设置到期日", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("日期", selection: $dueDate, displayedComponents: .date)
                    }
                    Text(hasDueDate ? "任务从到期日当天进入候选池；安排仍受作息、睡眠时段和每日容量约束。" : "不设置到期日时，任务立即进入候选池，并按当前计划容量安排。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if initialTask != nil, onDelete != nil {
                    Section {
                        Button("删除任务", role: .destructive) {
                            confirmsDelete = true
                        }
                        .disabled(isSaving)
                    }
                }

                if let saveError {
                    Section("保存失败") {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .groupedFormChrome()
            .navigationTitle(initialTask == nil ? "添加任务" : "编辑任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "正在保存…" : "保存") { save() }
                        .disabled(isSaving || !hasValidTitle || !hasValidMinutes)
                }
            }
            .confirmationDialog("删除这条手动任务？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("删除任务", role: .destructive) { delete() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已完成记录和历史计划会保留。")
            }
        }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
#endif
    }

    private func save() {
        guard !isSaving else { return }
        guard hasValidTitle else {
            saveError = "请输入标题。"
            return
        }
        guard hasValidMinutes else {
            saveError = "分钟数必须是范围内的正整数。"
            return
        }
        isSaving = true
        saveError = nil
        let result = onSave(task)
        isSaving = false
        saveError = result.errorMessage
        if result.mayCloseEditor { onCancel() }
    }

    private func delete() {
        guard !isSaving, let onDelete else { return }
        isSaving = true
        saveError = nil
        let result = onDelete(id)
        isSaving = false
        saveError = result.errorMessage
        if result.mayCloseEditor { onCancel() }
    }
}
