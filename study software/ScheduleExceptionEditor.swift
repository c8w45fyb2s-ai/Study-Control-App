import SwiftUI

// MARK: - ScheduleExceptionEditor
//
// 一次性例外编辑：停课 / 换课 / 补课。
// 只编辑本地草稿，保存回调交给 G 统一写入。

struct ScheduleExceptionEditor: View {
    var semester: ScheduleSemester
    var course: Course
    var initialDraft: ScheduleExceptionDraft
    var onSave: (ScheduleException) -> StoreChangeResult
    var onDelete: (() -> StoreChangeResult)?
    var onCancel: () -> Void

    @State private var draft: ScheduleExceptionDraft
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        semester: ScheduleSemester,
        course: Course,
        initialDraft: ScheduleExceptionDraft,
        onSave: @escaping (ScheduleException) -> StoreChangeResult,
        onDelete: (() -> StoreChangeResult)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.semester = semester
        self.course = course
        self.initialDraft = initialDraft
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
    }

    // MARK: 派生

    private var usesReplacementTime: Bool {
        draft.kind == .relocation || draft.kind == .makeup
    }

    private var isTimeValid: Bool {
        !usesReplacementTime || draft.replacementEnd.minutes > draft.replacementStart.minutes
    }

    private var dayStart: Date {
        semester.calendar.startOfDay(for: draft.date)
    }

    private var weekIndex: Int {
        semester.weekIndex(for: dayStart)
    }

    private var isInsideSemester: Bool {
        (1...semester.lastWeek).contains(weekIndex)
    }

    private var baseOccurrenceExists: Bool {
        ScheduleResolver.day(
            for: dayStart,
            semester: semester,
            courses: [course],
            exceptions: []
        ).courses.contains { !$0.isMakeup }
    }

    /// 用当前草稿试算当天占用，用来展示“应用前 / 应用后”。
    private var previewDay: ScheduleDay {
        ScheduleResolver.day(
            for: dayStart,
            semester: semester,
            courses: [course],
            exceptions: [draft.makeException(calendar: semester.calendar)]
        )
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                Section("调整类型") {
                    Picker("类型", selection: $draft.kind) {
                        ForEach(ScheduleExceptionKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("调整类型")

                    Text(kindExplanation)
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    DatePicker(
                        usesReplacementTime ? "补课日期" : "生效日期",
                        selection: $draft.date,
                        displayedComponents: .date
                    )
                    .accessibilityLabel("生效日期")

                    HStack(spacing: StudyDesign.Spacing.compact) {
                        Text("第 \(weekIndex) 周")
                            .studyMetaPill(tint: isInsideSemester ? StudyDesign.Colors.secondary : StudyDesign.Colors.warning)
                        Text(ScheduleResolver.weekday(of: dayStart, semester: semester).fullLabel)
                            .studyMetaPill(tint: StudyDesign.Colors.secondary)
                        if !isInsideSemester {
                            Text("学期范围外")
                                .studyMetaPill(tint: StudyDesign.Colors.warning)
                        }
                    }

                    if draft.kind == .cancellation, !baseOccurrenceExists {
                        Text("这一天原本没有「\(course.name)」的课，停课后不会有任何变化。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.warning)
                    }
                    if draft.kind == .makeup, baseOccurrenceExists {
                        Text("这一天本来就有「\(course.name)」的课，补课会叠加在原有课程之外。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.warning)
                    }
                } header: {
                    Text("日期")
                } footer: {
                    Text(isInsideSemester
                         ? "日期落在当前学期内（共 \(semester.lastWeek) 周）。"
                         : "日期不在学期范围内，仍然会记录这条调整，但会在课表里给出提示。")
                }

                if usesReplacementTime {
                    Section {
                        timeRow(title: "开始", time: $draft.replacementStart, accessibility: "开始时间")
                        timeRow(title: "结束", time: $draft.replacementEnd, accessibility: "结束时间")
                        if !isTimeValid {
                            Label("结束时间必须晚于开始时间。", systemImage: "exclamationmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.danger)
                        }
                    } header: {
                        Text("替换时间")
                    } footer: {
                        Text(draft.kind == .makeup
                             ? "补课使用这里的时间；留空会无效，所以必须填。"
                             : "时间不变时保持与课程时间一致即可。")
                    }

                    Section {
                        TextField("教室 / 地点（可选）", text: $draft.replacementLocation)
                            .studyInputChrome()
                            .accessibilityLabel("替换地点")
                    } header: {
                        Text("替换地点")
                    } footer: {
                        Text("留空则沿用原课程地点。")
                    }
                }

                Section("备注") {
                    TextField("备注（可选）", text: $draft.note, axis: .vertical)
                        .lineLimit(2...4)
                        .studyInputChrome()
                }

                if let saveError {
                    Section("保存失败") {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("应用后这一天的课") {
                    if previewDay.courses.isEmpty {
                        Text("这一天没有课程占用（停课或换天后为空）。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    } else {
                        ForEach(previewDay.courses) { occurrence in
                            HStack(spacing: StudyDesign.Spacing.normal) {
                                Text(ScheduleViewEnvironment.timeText(occurrence.start, semester: semester))
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 44, alignment: .leading)
                                Text(occurrence.courseName)
                                    .font(.caption)
                                if occurrence.isMakeup {
                                    Text("补课").studyMetaPill(tint: StudyDesign.Colors.warning)
                                }
                                if occurrence.isReplaced {
                                    Text("换课").studyMetaPill(tint: StudyDesign.Colors.info)
                                }
                                Spacer(minLength: StudyDesign.Spacing.tight)
                            }
                        }
                    }

                    Text("这张预览只反映当前草稿，保存前不会写入任何正式数据。")
                        .font(.caption2)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }

                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            submit(onDelete)
                        } label: {
                            Label("删除这条调整", systemImage: "trash")
                        }
                    }
                }
            }
            .groupedFormChrome()
            .navigationTitle(initialDraft.editingExceptionID == nil ? "添加临时调整" : "编辑临时调整")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        submit { onSave(draft.makeException(calendar: semester.calendar)) }
                    }
                    .disabled(!isTimeValid || isSaving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func submit(_ action: () -> StoreChangeResult) {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        let result = action()
        isSaving = false
        saveError = result.errorMessage
    }

    // MARK: 子视图

    private var kindExplanation: String {
        switch draft.kind {
        case .cancellation:
            return "停课：这一次课取消，对应时间会恢复为可用自习时间。"
        case .relocation:
            return "换课：这一次课改时间或改教室，不会额外增加占用。"
        case .makeup:
            return "补课：在额外日期增加一次课，与原课程不会重复计算。"
        }
    }

    private func timeRow(
        title: String,
        time: Binding<TimeOfDay>,
        accessibility: String
    ) -> some View {
        DatePicker(
            title,
            selection: Binding(
                get: { time.wrappedValue.dateOnReferenceDay(dayStart, semester: semester) },
                set: { newValue in
                    time.wrappedValue = TimeOfDay(date: newValue, calendar: semester.calendar)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .accessibilityLabel(accessibility)
    }
}
