import SwiftUI

// MARK: - CourseEditScope

/// 编辑重复课程时的作用范围。这是“区分仅这一次和整个重复规则”的契约。
enum CourseEditScope: String, CaseIterable, Identifiable {
    case onlyThisTime
    case entireSeries

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onlyThisTime: return "仅这一次"
        case .entireSeries: return "整个重复规则"
        }
    }

    var explanation: String {
        switch self {
        case .onlyThisTime:
            return "只改这一次课：会新增一条临时调整记录，重复规则保持不变。"
        case .entireSeries:
            return "修改这条重复规则本身：这门课以后所有周次都会跟着变。"
        }
    }

    var systemImage: String {
        switch self {
        case .onlyThisTime: return "calendar.badge.exclamationmark"
        case .entireSeries: return "repeat"
        }
    }
}

// MARK: - CourseEditorSheet
//
// 课程编辑表单。表单只编辑一份本地草稿，点击保存前不会触碰正式数据。

struct CourseEditorSheet: View {
    var mode: CourseEditorMode
    var semester: ScheduleSemester
    var existingCourses: [Course]
    var periodTemplates: [PeriodTemplate]
    var knownSubjectNames: [String]
    var initialDraft: CourseDraft
    /// 计算“下一次课”的参考日期（由调用方注入，表单不调用 `Date()`）。
    var referenceDate: Date

    var onSave: (Course) -> StoreChangeResult
    /// “仅这一次”修改可能同时产生多条记录（换天 = 停课 + 补课），因此返回数组。
    var onApplyChange: ((Course, CourseEditScope, [ScheduleException]) -> StoreChangeResult)?
    var onDeleteCourse: ((UUID) -> StoreChangeResult)?
    var onCancel: () -> Void

    @State private var draft: CourseDraft
    @State private var isShowingScopeDialog = false
    @State private var isShowingDeleteConfirm = false
    @State private var isShowingDiscardConfirmation = false
    @State private var didAttemptSave = false
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        mode: CourseEditorMode,
        semester: ScheduleSemester,
        existingCourses: [Course],
        periodTemplates: [PeriodTemplate],
        knownSubjectNames: [String],
        initialDraft: CourseDraft,
        referenceDate: Date,
        onSave: @escaping (Course) -> StoreChangeResult,
        onApplyChange: ((Course, CourseEditScope, [ScheduleException]) -> StoreChangeResult)? = nil,
        onDeleteCourse: ((UUID) -> StoreChangeResult)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.semester = semester
        self.existingCourses = existingCourses
        self.periodTemplates = periodTemplates.filter(\.isValid)
        self.knownSubjectNames = knownSubjectNames
        self.initialDraft = initialDraft
        self.referenceDate = referenceDate
        self.onSave = onSave
        self.onApplyChange = onApplyChange
        self.onDeleteCourse = onDeleteCourse
        self.onCancel = onCancel
        _draft = State(initialValue: initialDraft)
    }

    // MARK: 派生

    private var issues: [ScheduleValidationIssue] {
        ScheduleValidation.issues(for: draft, semester: semester, existingCourses: existingCourses)
    }

    private var blockingErrors: [ScheduleValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    private var warnings: [ScheduleValidationIssue] {
        issues.filter { $0.severity == .warning }
    }

    private var originalCourse: Course? {
        guard let id = draft.editingCourseID else { return nil }
        return existingCourses.first { $0.id == id }
    }

    private var hasUnsavedChanges: Bool {
        draft != initialDraft
    }

    /// 是否改动了“会影响整个重复规则”的字段。
    private var affectsWholeSeries: Bool {
        guard let original = originalCourse else { return false }
        return original.name != draft.trimmedName
            || original.weekday != draft.weekday
            || original.startTime != draft.startTime
            || original.endTime != draft.endTime
            || original.endDayOffset != draft.endDayOffset
            || original.location != draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
            || original.teacher != draft.teacher.trimmingCharacters(in: .whitespacesAndNewlines)
            || original.note != draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
            || original.subject.id != draft.subject.id
    }

    private var changesRecurrence: Bool {
        guard let original = originalCourse else { return false }
        return original.recurrence.parity != draft.parity
            || original.recurrence.weeks != Array(Set(draft.customWeeks)).sorted()
            || original.recurrence.lastWeek != draft.lastWeek
    }

    private var templateNameForSelection: String? {
        guard let id = draft.periodTemplateID else { return nil }
        return periodTemplates.first { $0.id == id }?.name
    }

    /// 供科目选择使用的稳定 id 集合。
    private var subjectOptions: [SubjectRef] {
        var result: [SubjectRef] = []
        var seen = Set<UUID>()
        for course in existingCourses where !seen.contains(course.subject.id) {
            seen.insert(course.subject.id)
            result.append(course.subject)
        }
        for name in knownSubjectNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let reference = SubjectRef(displayName: trimmed, linkedKnowledgeSubject: trimmed)
            if result.contains(where: { $0.displayName == trimmed }) { continue }
            result.append(reference)
        }
        return result.sorted { $0.displayName < $1.displayName }
    }

    private var isSubjectFromExistingList: Bool {
        subjectOptions.contains { $0.id == draft.subject.id }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                Section("课程") {
                    TextField("课程名称", text: $draft.name)
                        .studyInputChrome()
                        .accessibilityLabel("课程名称")

                    subjectField
                }

                Section {
                    Picker("星期", selection: $draft.weekday) {
                        ForEach(ScheduleWeekday.ordered) { weekday in
                            Text(weekday.fullLabel).tag(weekday)
                        }
                    }
                    .accessibilityLabel("上课星期")

                    timeRow(
                        title: "开始",
                        time: $draft.startTime,
                        accessibility: "开始时间"
                    )
                    timeRow(
                        title: "结束",
                        time: $draft.endTime,
                        accessibility: "结束时间"
                    )

                    Toggle("结束时间为次日", isOn: Binding(
                        get: { draft.endDayOffset > 0 },
                        set: { draft.endDayOffset = $0 ? 1 : 0 }
                    ))
                    .accessibilityHint("跨午夜课程请打开，例如 22:30–次日 00:30")

                    Text("时长 \(ScheduleViewEnvironment.durationText(draft.durationMinutes))")
                        .font(.caption)
                        .foregroundStyle(draft.durationMinutes > 0 ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.danger)
                } header: {
                    Text("时间")
                } footer: {
                    Text("结束时间必须晚于开始时间。跨午夜请打开「结束时间为次日」。")
                }

                if !periodTemplates.isEmpty {
                    periodTemplateSection
                }

                recurrenceSection

                Section("地点与备注") {
                    TextField("教室 / 地点（可选）", text: $draft.location)
                        .studyInputChrome()
                    TextField("教师（可选）", text: $draft.teacher)
                        .studyInputChrome()
                    TextField("备注（可选）", text: $draft.note, axis: .vertical)
                        .lineLimit(2...4)
                        .studyInputChrome()
                }

                // 保存前的重复规则摘要。
                Section("保存前确认") {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        Label(draft.saveSummary, systemImage: "checkmark.seal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let templateName = templateNameForSelection {
                            Text("节次来源：\(templateName)")
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }

                        Text("课程只表示占用与学习背景，不会自动生成学习完成记录。")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    }
                    .padding(.vertical, 2)
                }

                if didAttemptSave, !blockingErrors.isEmpty {
                    Section("需要修正") {
                        ForEach(blockingErrors) { issue in
                            issueRow(issue)
                        }
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

                if !warnings.isEmpty {
                    Section("提示（不阻止保存）") {
                        ForEach(warnings) { issue in
                            issueRow(issue)
                        }
                    }
                }

                if onDeleteCourse != nil, case .edit(let id) = mode {
                    Section {
                        Button(role: .destructive) {
                            isShowingDeleteConfirm = true
                        } label: {
                            Label("删除这门课程", systemImage: "trash")
                        }
                        .accessibilityHint("删除后该课程所有周次都会移除")
                        .confirmationDialog(
                            "删除「\(originalCourse?.name ?? "该课程")」？",
                            isPresented: $isShowingDeleteConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("删除课程", role: .destructive) {
                                guard let onDeleteCourse else {
                                    saveError = "课程删除入口不可用，请关闭后重试。"
                                    return
                                }
                                submit { onDeleteCourse(id) }
                                if saveError == nil { onCancel() }
                            }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("这会移除该课程在整个学期内的所有周次。已经产生的临时调整记录不会被自动清理。")
                        }
                    }
                }
            }
            .groupedFormChrome()
            .navigationTitle(mode.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: requestCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "正在保存…" : "保存") { attemptSave() }
                        .disabled(isSaving)
                }
            }
            .confirmationDialog(
                "这次修改要应用到哪些周次？",
                isPresented: $isShowingScopeDialog,
                titleVisibility: .visible
            ) {
                Button(CourseEditScope.onlyThisTime.label) {
                    commit(scope: .onlyThisTime)
                }
                Button(CourseEditScope.entireSeries.label) {
                    commit(scope: .entireSeries)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(CourseEditScope.onlyThisTime.explanation + "\n\n" + CourseEditScope.entireSeries.explanation)
            }
            .confirmationDialog(
                "放弃未保存的课程修改？",
                isPresented: $isShowingDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("放弃修改", role: .destructive, action: onCancel)
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("当前课程还有未保存的修改。")
            }
        }
        .interactiveDismissDisabled(hasUnsavedChanges || isSaving)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
    }

    // MARK: 子视图

    private var subjectField: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            if !subjectOptions.isEmpty {
                Picker("选择已有科目", selection: Binding(
                    get: { isSubjectFromExistingList ? draft.subject.id : SubjectRef.newSubjectSentinel },
                    set: { newValue in
                        if newValue == SubjectRef.newSubjectSentinel {
                            draft.subject = SubjectRef(displayName: "")
                        } else if let matched = subjectOptions.first(where: { $0.id == newValue }) {
                            draft.subject = matched
                        }
                    }
                )) {
                    Text("新科目…").tag(SubjectRef.newSubjectSentinel)
                    ForEach(subjectOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .accessibilityLabel("选择已有科目")
            }

            TextField("科目名称", text: Binding(
                get: { draft.subject.displayName },
                set: { newValue in
                    // 手写科目名时保留稳定 id（正在编辑既有科目则沿用其 id）。
                    draft.subject = SubjectRef(
                        id: draft.subject.id,
                        displayName: newValue,
                        linkedKnowledgeSubject: newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            ))
            .studyInputChrome()
            .accessibilityLabel("科目名称")

            Text("科目使用稳定 id 关联，改名不会让课程与已有知识点失联。")
                .font(.caption2)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
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
                get: { time.wrappedValue.dateOnReferenceDay(referenceDate, semester: semester) },
                set: { newValue in
                    time.wrappedValue = TimeOfDay(date: newValue, calendar: semester.calendar)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .accessibilityLabel(accessibility)
    }

    private var periodTemplateSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: StudyDesign.Spacing.compact) {
                    ForEach(periodTemplates) { template in
                        Button {
                            draft.startTime = template.start
                            draft.endTime = template.end
                            draft.endDayOffset = 0
                            draft.periodTemplateID = template.id
                        } label: {
                            VStack(spacing: 1) {
                                Text(template.name)
                                    .font(.caption.weight(.semibold))
                                Text(template.displayText)
                                    .font(.caption2)
                                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, StudyDesign.Spacing.tight)
                            .padding(.vertical, StudyDesign.Spacing.compact)
                            .background(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                                    .fill(draft.periodTemplateID == template.id
                                          ? StudyDesign.Colors.primary.opacity(0.16)
                                          : StudyDesign.Colors.inputBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                                    .stroke(draft.periodTemplateID == template.id
                                            ? StudyDesign.Colors.primary.opacity(0.5)
                                            : StudyDesign.Colors.inputHairline,
                                            lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("套用节次 \(template.name) \(template.displayText)")
                    }
                }
                .padding(.vertical, 2)
            }

            if draft.periodTemplateID != nil {
                Button("清除节次来源") {
                    draft.periodTemplateID = nil
                }
                .font(.caption)
            }
        } header: {
            Text("节次模板")
        } footer: {
            Text("点选节次会自动填入起止时间，也可以在时间里手动微调。")
        }
    }

    private var recurrenceSection: some View {
        Section {
            Picker("重复", selection: Binding(
                get: { draft.parity },
                set: { newValue in
                    draft.parity = newValue
                    if newValue == .custom, draft.customWeeks.isEmpty {
                        draft.customWeeks = [1]
                    }
                }
            )) {
                ForEach(CourseWeekParity.allCases) { parity in
                    Text(parity.label).tag(parity)
                }
            }
            .accessibilityLabel("重复规则")

            if draft.parity == .custom {
                weekChips
            } else {
                Toggle("提前结束", isOn: Binding(
                    get: { draft.lastWeek != nil },
                    set: { draft.lastWeek = $0 ? max(1, min(semester.lastWeek, 8)) : nil }
                ))
                if draft.lastWeek != nil {
                    Stepper(
                        "上到第 \(draft.lastWeek ?? semester.lastWeek) 周",
                        value: Binding(
                            get: { draft.lastWeek ?? semester.lastWeek },
                            set: { draft.lastWeek = min(max($0, 1), semester.lastWeek) }
                        ),
                        in: 1...semester.lastWeek
                    )
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("规则摘要：\(draft.recurrenceSummary)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text("学期共 \(semester.lastWeek) 周；生效周次 \(effectiveWeekCount) 周。")
                    .font(.caption2)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }
        } header: {
            Text("重复规则")
        } footer: {
            Text("单周 / 双周会按学期边界计算：若总周数为奇数，双周课不会出现在最后一周。")
        }
    }

    private var weekChips: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Text("勾选上课周次")
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudyDesign.Colors.labelSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: StudyDesign.Spacing.compact)], spacing: StudyDesign.Spacing.compact) {
                ForEach(1...semester.lastWeek, id: \.self) { week in
                    let isSelected = draft.customWeeks.contains(week)
                    Button {
                        if isSelected {
                            draft.customWeeks.removeAll { $0 == week }
                        } else {
                            draft.customWeeks.append(week)
                        }
                    } label: {
                        Text("\(week)")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                    .fill(isSelected ? StudyDesign.Colors.primary.opacity(0.16) : StudyDesign.Colors.inputBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous)
                                    .stroke(isSelected ? StudyDesign.Colors.primary.opacity(0.5) : StudyDesign.Colors.inputHairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("第 \(week) 周\(isSelected ? "，已选" : "")")
                }
            }

            HStack(spacing: StudyDesign.Spacing.normal) {
                Button("全选") {
                    draft.customWeeks = Array(1...semester.lastWeek)
                }
                .font(.caption)
                Button("清空") {
                    draft.customWeeks = []
                }
                .font(.caption)
                Button("单周") {
                    draft.customWeeks = Array((1...semester.lastWeek).filter { $0 % 2 == 1 })
                }
                .font(.caption)
                Button("双周") {
                    draft.customWeeks = Array((1...semester.lastWeek).filter { $0 % 2 == 0 })
                }
                .font(.caption)
            }
        }
    }

    private func issueRow(_ issue: ScheduleValidationIssue) -> some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.tight) {
            Image(systemName: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(issue.severity == .error ? StudyDesign.Colors.danger : StudyDesign.Colors.warning)
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(StudyDesign.Colors.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 行为

    private var effectiveWeekCount: Int {
        ScheduleValidation.effectiveWeeks(
            parity: draft.parity,
            customWeeks: draft.customWeeks,
            lastWeek: draft.lastWeek,
            semester: semester
        ).count
    }

    private func attemptSave() {
        didAttemptSave = true
        guard blockingErrors.isEmpty else { return }

        let course = draft.makeCourse(semester: semester, templateName: templateNameForSelection)

        // 只有“编辑既有课程”才需要区分作用范围：
        // - 只改了重复规则 → 保存整条规则（无法只对一次改重复规则）。
        // - 改了时间/地点等 → 询问「仅这一次 / 整个重复规则」。
        guard mode.isEditingExisting, let _ = originalCourse else {
            submit { onSave(course) }
            return
        }

        let dayChanged = originalCourse?.weekday != draft.weekday
        let timeOrDetailChanged = affectsWholeSeries && !changesRecurrence

        if dayChanged || timeOrDetailChanged {
            isShowingScopeDialog = true
        } else {
            submit { onSave(course) }
        }
    }

    private func requestCancel() {
        guard !isSaving else { return }
        if hasUnsavedChanges {
            isShowingDiscardConfirmation = true
        } else {
            onCancel()
        }
    }

    private func commit(scope: CourseEditScope) {
        let course = draft.makeCourse(semester: semester, templateName: templateNameForSelection)
        guard let original = originalCourse else {
            submit { onSave(course) }
            return
        }

        switch scope {
        case .entireSeries:
            submit { onSave(course) }
        case .onlyThisTime:
            let payload = makeOnceChange(original: original, edited: course)
            if let onApplyChange {
                submit { onApplyChange(course, .onlyThisTime, payload) }
            } else {
                saveError = "无法保存“仅这一次”的调整：例外保存功能尚未接入，课程规则未修改。"
            }
        }
    }

    private func submit(_ action: () -> StoreChangeResult) {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        let result = action()
        isSaving = false
        saveError = result.errorMessage
        if result.mayCloseEditor { onCancel() }
    }

    /// 生成“仅这一次”的例外。
    ///
    /// - 同一天只改时间/地点 → 一条「换课」。
    /// - 改到别的星期 → 原这一次「停课」+ 新星期「补课」两条，避免重复占用。
    private func makeOnceChange(original: Course, edited: Course) -> [ScheduleException] {
        let day = nextOccurrenceDate(for: original)
        let dayChanged = original.weekday != edited.weekday

        if dayChanged {
            let cancellation = ScheduleException(
                kind: .cancellation,
                courseID: original.id,
                date: day,
                note: "仅这一次：改到 \(edited.weekday.fullLabel)"
            )
            let makeupDate = nextMakeupDate(after: day, weekday: edited.weekday)
            let makeup = ScheduleException(
                kind: .makeup,
                courseID: original.id,
                date: makeupDate,
                replacementStart: edited.startTime,
                replacementEnd: edited.endTime,
                replacementLocation: edited.location.isEmpty ? nil : edited.location,
                note: "仅这一次：补课"
            )
            return [cancellation, makeup]
        }

        return [ScheduleException(
            kind: .relocation,
            courseID: original.id,
            date: day,
            replacementStart: edited.startTime,
            replacementEnd: edited.endTime,
            replacementLocation: edited.location.isEmpty ? nil : edited.location,
            note: "仅这一次调整"
        )]
    }

    /// 停课日期之后、指定星期的最近一天（用于“仅这一次”换天的补课）。
    private func nextMakeupDate(after day: Date, weekday: ScheduleWeekday) -> Date {
        let calendar = semester.calendar
        for offset in 1...14 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: day) else { break }
            if ScheduleResolver.weekday(of: candidate, semester: semester) == weekday {
                return calendar.startOfDay(for: candidate)
            }
        }
        return calendar.startOfDay(for: day)
    }

    /// 该课程从参考日期起的下一次上课日期。
    private func nextOccurrenceDate(for course: Course) -> Date {
        let calendar = semester.calendar
        let start = calendar.startOfDay(for: referenceDate)
        for offset in 0...(semester.lastWeek * 7 + 7) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { break }
            let week = semester.weekIndex(for: day)
            if week >= 1, week <= semester.lastWeek,
               ScheduleResolver.isActive(week: week, recurrence: course.recurrence, semester: semester),
               ScheduleResolver.weekday(of: day, semester: semester) == course.weekday {
                return calendar.startOfDay(for: day)
            }
        }
        return start
    }
}

// MARK: - 辅助

extension View {
    /// `formStyle(.grouped)` 在 iOS 上语义不同，这里只在 macOS 显式指定。
    @ViewBuilder
    func groupedFormChrome() -> some View {
        #if os(macOS)
        self.formStyle(.grouped)
        #else
        self
        #endif
    }
}

extension SubjectRef {
    /// 用于“新科目…”选项的哨兵 id。
    static let newSubjectSentinel = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
}

extension TimeOfDay {
    /// 把时刻落到参考日期上，供 `DatePicker` 使用。
    func dateOnReferenceDay(_ reference: Date, semester: ScheduleSemester) -> Date {
        let calendar = semester.calendar
        let day = calendar.startOfDay(for: reference)
        return date(on: day, calendar: calendar) ?? day
    }
}

// MARK: - 学期设置

struct SemesterEditorSheet: View {
    var semester: ScheduleSemester
    var onSave: (ScheduleSemester) -> StoreChangeResult
    var onCancel: () -> Void

    @State private var firstWeekStart: Date
    @State private var weekCount: Int
    @State private var timeZoneIdentifier: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        semester: ScheduleSemester,
        onSave: @escaping (ScheduleSemester) -> StoreChangeResult,
        onCancel: @escaping () -> Void
    ) {
        self.semester = semester
        self.onSave = onSave
        self.onCancel = onCancel
        _firstWeekStart = State(initialValue: semester.firstWeekStart)
        _weekCount = State(initialValue: semester.lastWeek)
        _timeZoneIdentifier = State(initialValue: semester.timeZoneIdentifier)
    }

    private var resolvedFirstWeekStart: Date {
        // 一律对齐到所选星期的周一，避免“第一周”本身错位。
        var draft = semester
        draft.firstWeekStart = firstWeekStart
        return ScheduleResolver.weekStartDate(containing: firstWeekStart, semester: draft)
    }

    private var timeZoneIdentifiers: [String] {
        var identifiers = TimeZone.knownTimeZoneIdentifiers
        if !identifiers.contains(timeZoneIdentifier) {
            identifiers.insert(timeZoneIdentifier, at: 0)
        }
        return identifiers
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "第一周周一",
                        selection: $firstWeekStart,
                        displayedComponents: .date
                    )
                    .accessibilityLabel("学期第一周周一")
                    Text("实际生效：\(ScheduleViewEnvironment.monthDayText(resolvedFirstWeekStart, semester: adjustedSemester))")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                } header: {
                    Text("学期起点")
                } footer: {
                    Text("无论选哪一天，都会自动对齐到该周的周一，保证星期与周次计算不出错。")
                }

                Section("学期长度") {
                    Stepper("总周数：\(weekCount) 周", value: $weekCount, in: 1...30)
                }

                Section {
                    Picker("学期时区", selection: $timeZoneIdentifier) {
                        ForEach(timeZoneIdentifiers, id: \.self) { identifier in
                            Text(identifier).tag(identifier)
                        }
                    }
                    .accessibilityLabel("学期时区")
                } header: {
                    Text("时区")
                } footer: {
                    Text("课表按学期时区展开。即使设备时区变化，星期也不会错位。")
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
            .navigationTitle("学期设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "正在保存…" : "保存") {
                        guard !isSaving else { return }
                        isSaving = true
                        saveError = nil
                        let result = onSave(adjustedSemester)
                        isSaving = false
                        saveError = result.errorMessage
                    }
                    .disabled(isSaving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 440)
        #endif
    }

    private var adjustedSemester: ScheduleSemester {
        ScheduleSemester(
            firstWeekStart: resolvedFirstWeekStart,
            weekCount: weekCount,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}
