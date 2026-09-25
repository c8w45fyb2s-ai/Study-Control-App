import SwiftUI

// MARK: - AvailabilitySettingsView
//
// 可用时间设置：学习窗口、睡眠、固定占用、通勤/缓冲与最短空档阈值。
// 同样只编辑本地草稿，保存回调交给 G。

struct AvailabilitySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var semester: ScheduleSemester
    var settings: AvailabilitySettings
    var courses: [Course]
    var exceptions: [ScheduleException]
    /// 由调用方注入的“现在”，用于当天重算与未来 7 天预览。
    var now: Date
    var periodTemplates: [PeriodTemplate]

    var onSaveSettings: (AvailabilitySettings, [PeriodTemplate]) -> StoreChangeResult
    var onCancel: () -> Void

    @State private var draft: AvailabilitySettings
    @State private var templates: [PeriodTemplate]
    @State private var selectedWeekday: ScheduleWeekday
    @State private var isSaving = false
    @State private var saveError: String?

    init(
        semester: ScheduleSemester,
        settings: AvailabilitySettings,
        courses: [Course],
        exceptions: [ScheduleException],
        now: Date,
        periodTemplates: [PeriodTemplate] = PeriodTemplate.defaultTemplates,
        onSaveSettings: @escaping (AvailabilitySettings, [PeriodTemplate]) -> StoreChangeResult,
        onCancel: @escaping () -> Void
    ) {
        self.semester = semester
        self.settings = settings
        self.courses = courses
        self.exceptions = exceptions
        self.now = now
        self.periodTemplates = periodTemplates
        self.onSaveSettings = onSaveSettings
        self.onCancel = onCancel
        _draft = State(initialValue: settings)
        _templates = State(initialValue: periodTemplates)
        _selectedWeekday = State(
            initialValue: ScheduleResolver.weekday(of: now, semester: semester)
        )
    }

    // MARK: 派生

    private var todayStart: Date {
        semester.calendar.startOfDay(for: now)
    }

    private var selectedDayAvailability: AvailabilityDay {
        AvailabilityCalculator.availability(
            on: previewDay(for: selectedWeekday),
            semester: semester,
            courses: courses,
            exceptions: exceptions,
            settings: draft,
            now: ScheduleViewEnvironment.isSameDay(previewDay(for: selectedWeekday), todayStart, semester: semester) ? now : nil
        )
    }

    private var weekPreview: [(date: Date, weekday: ScheduleWeekday, availability: AvailabilityDay)] {
        let calendar = semester.calendar
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: todayStart) else { return nil }
            let availability = AvailabilityCalculator.availability(
                on: day,
                semester: semester,
                courses: courses,
                exceptions: exceptions,
                settings: draft,
                now: offset == 0 ? now : nil
            )
            return (day, ScheduleResolver.weekday(of: day, semester: semester), availability)
        }
    }

    private var weeklyTotalMinutes: Int {
        weekPreview.reduce(0) { $0 + $1.availability.totalFreeMinutes }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("这里设置的是“你愿意用来学习的时间”。课程、睡眠、通勤与缓冲会从这些窗口里扣除，剩下的才是可安排容量。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                studyWindowSections
                sleepSection
                fixedBlockSection

                Section {
                    Stepper(
                        "通勤 \(draft.commuteMinutes) 分钟 / 次课",
                        value: $draft.commuteMinutes,
                        in: 0...180,
                        step: 5
                    )
                    .accessibilityLabel("通勤时长")
                    Stepper(
                        "缓冲 \(draft.bufferMinutes) 分钟 / 次课",
                        value: $draft.bufferMinutes,
                        in: 0...60,
                        step: 5
                    )
                    .accessibilityLabel("缓冲时长")
                } header: {
                    Text("通勤与缓冲")
                } footer: {
                    Text("有课的每一天，按每次课扣除一次通勤与前后缓冲（默认 0 分钟，即不扣）。重叠部分只会扣一次。")
                }

                Section {
                    Stepper(
                        "最短可用空档 \(draft.minimumFreeBlockMinutes) 分钟",
                        value: $draft.minimumFreeBlockMinutes,
                        in: 0...60,
                        step: 1
                    )
                    .accessibilityLabel("最短可用空档")
                } header: {
                    Text("最短可用空档")
                } footer: {
                    Text("小于该值的空档不会计入可安排容量，但仍会单独列出，方便你决定是否调整。默认 5 分钟。")
                }

                previewSection
                templateSection

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
            .navigationTitle("可用时间设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "正在保存…" : "保存") {
                        guard !isSaving else { return }
                        // 归一化：清掉无效窗口，避免把坏数据写进存储。
                        var normalized = draft
                        normalized.weekdayStudyWindows = draft.weekdayStudyWindows.filter(\.isValid)
                        normalized.weekendStudyWindows = draft.weekendStudyWindows.filter(\.isValid)
                        normalized.sleepWindows = draft.sleepWindows.filter(\.isValid)
                        normalized.customBlocks = draft.customBlocks.filter(\.isValid)
                        isSaving = true
                        saveError = nil
                        let result = onSaveSettings(normalized, templates)
                        isSaving = false
                        saveError = result.errorMessage
                        if result.mayCloseEditor { dismiss() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    // MARK: 学习窗口

    @ViewBuilder
    private var studyWindowSections: some View {
        ForEach(ScheduleWeekday.ordered) { weekday in
            studyWindowSection(for: weekday)
        }
    }

    private func studyWindowSection(for weekday: ScheduleWeekday) -> some View {
        let windows = windows(for: weekday)
        let totalMinutes = windows.reduce(0) { $0 + $1.durationMinutes }
        return Section {
            if windows.isEmpty {
                Text("这一天没有学习窗口。")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            } else {
                ForEach(windows) { range in
                    windowEditor(
                        range: range,
                        onChange: { updateWindow($0) },
                        onDelete: { deleteWindow(id: range.id, weekday: weekday) }
                    )
                }
            }

            Button {
                addWindow(weekday: weekday)
            } label: {
                Label("添加时间段", systemImage: "plus.circle")
                    .font(.caption.weight(.semibold))
            }
        } header: {
            HStack {
                Text(weekday.isWeekend ? "\(weekday.fullLabel)（周末）" : weekday.fullLabel)
                Spacer()
                if totalMinutes > 0 {
                    Text(ScheduleViewEnvironment.durationText(totalMinutes))
                        .font(.caption2)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }
            }
        }
    }

    /// 某个星期几的学习窗口（工作日与周末分开存放）。
    private func windows(for weekday: ScheduleWeekday) -> [DayTimeRange] {
        weekday.isWeekend
            ? draft.weekendStudyWindows.filter { $0.weekday == weekday }
            : draft.weekdayStudyWindows.filter { $0.weekday == weekday }
    }

    private func addWindow(weekday: ScheduleWeekday) {
        let range = DayTimeRange(
            weekday: weekday,
            start: TimeOfDay(hour: 19, minute: 0),
            end: TimeOfDay(hour: 22, minute: 0)
        )
        if weekday.isWeekend {
            draft.weekendStudyWindows.append(range)
        } else {
            draft.weekdayStudyWindows.append(range)
        }
    }

    private func updateWindow(_ updated: DayTimeRange) {
        replaceWindow(id: updated.id, with: updated)
    }

    private func deleteWindow(id: UUID, weekday: ScheduleWeekday) {
        if weekday.isWeekend {
            draft.weekendStudyWindows.removeAll { $0.id == id }
        } else {
            draft.weekdayStudyWindows.removeAll { $0.id == id }
        }
    }

    private func replaceWindow(id: UUID, with updated: DayTimeRange) {
        if let index = draft.weekdayStudyWindows.firstIndex(where: { $0.id == id }) {
            draft.weekdayStudyWindows[index] = updated
            return
        }
        if let index = draft.weekendStudyWindows.firstIndex(where: { $0.id == id }) {
            draft.weekendStudyWindows[index] = updated
            return
        }
        if let index = draft.sleepWindows.firstIndex(where: { $0.id == id }) {
            draft.sleepWindows[index] = updated
            return
        }
        if let index = draft.customBlocks.firstIndex(where: { $0.id == id }) {
            draft.customBlocks[index] = updated
        }
    }

    // MARK: 睡眠

    private var sleepSection: some View {
        Section {
            if draft.sleepWindows.isEmpty {
                Text("没有设置睡眠时间。跨午夜睡眠请打开「次日结束」。")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            } else {
                ForEach(draft.sleepWindows) { range in
                    windowEditor(
                        range: range,
                        allowCrossMidnight: true,
                        onChange: { replaceWindow(id: range.id, with: $0) },
                        onDelete: { draft.sleepWindows.removeAll { $0.id == range.id } }
                    )
                }
            }

            Button {
                draft.sleepWindows.append(DayTimeRange(
                    weekday: .monday,
                    start: TimeOfDay(hour: 23, minute: 0),
                    end: TimeOfDay(hour: 7, minute: 0),
                    endDayOffset: 1
                ))
            } label: {
                Label("添加睡眠时间段", systemImage: "plus.circle")
                    .font(.caption.weight(.semibold))
            }
        } header: {
            Text("睡眠")
        } footer: {
            Text("睡眠会从学习窗口中扣除。默认 23:00–次日 07:00，跨午夜会算进次日凌晨。")
        }
    }

    // MARK: 固定占用

    private var fixedBlockSection: some View {
        Section {
            if draft.customBlocks.isEmpty {
                Text("没有固定占用。实习、例会、健身等可以加在这里。")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            } else {
                ForEach(draft.customBlocks) { range in
                    windowEditor(
                        range: range,
                        allowCrossMidnight: true,
                        onChange: { replaceWindow(id: range.id, with: $0) },
                        onDelete: { draft.customBlocks.removeAll { $0.id == range.id } }
                    )
                }
            }

            Button {
                draft.customBlocks.append(DayTimeRange(
                    weekday: selectedWeekday,
                    start: TimeOfDay(hour: 12, minute: 0),
                    end: TimeOfDay(hour: 13, minute: 0)
                ))
            } label: {
                Label("添加固定占用", systemImage: "plus.circle")
                    .font(.caption.weight(.semibold))
            }
        } header: {
            Text("固定占用")
        } footer: {
            Text("固定占用与课程一样，先合并重叠再从学习窗口中扣除，不会重复扣减。")
        }
    }

    // MARK: 时间段编辑器

    private func windowEditor(
        range: DayTimeRange,
        allowCrossMidnight: Bool = false,
        onChange: @escaping (DayTimeRange) -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            Picker("星期", selection: Binding(
                get: { range.weekday },
                set: { newValue in
                    var updated = range
                    updated.weekday = newValue
                    onChange(updated)
                }
            )) {
                ForEach(ScheduleWeekday.ordered) { weekday in
                    Text(weekday.shortLabel).tag(weekday)
                }
            }
            .accessibilityLabel("时间段所属星期")

            timeRow(title: "开始", time: range.start, referenceDay: previewDay(for: range.weekday)) { updated in
                var draftRange = range
                draftRange.start = updated
                onChange(draftRange)
            }

            timeRow(title: "结束", time: range.end, referenceDay: previewDay(for: range.weekday)) { updated in
                var draftRange = range
                draftRange.end = updated
                onChange(draftRange)
            }

            if allowCrossMidnight {
                Toggle("次日结束", isOn: Binding(
                    get: { range.endDayOffset > 0 },
                    set: { newValue in
                        var updated = range
                        updated.endDayOffset = newValue ? 1 : 0
                        onChange(updated)
                    }
                ))
                .accessibilityHint("跨午夜的睡眠或占用请打开")
            }

            HStack(spacing: StudyDesign.Spacing.normal) {
                Text(range.isValid
                     ? ScheduleViewEnvironment.durationText(range.durationMinutes)
                     : "结束时间必须晚于开始时间")
                    .font(.caption)
                    .foregroundStyle(range.isValid ? StudyDesign.Colors.labelSecondary : StudyDesign.Colors.danger)

                Spacer(minLength: StudyDesign.Spacing.tight)

                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除该时间段")
            }
        }
        .padding(.vertical, 2)
    }

    private func timeRow(
        title: String,
        time: TimeOfDay,
        referenceDay: Date,
        onChange: @escaping (TimeOfDay) -> Void
    ) -> some View {
        DatePicker(
            title,
            selection: Binding(
                get: { time.dateOnReferenceDay(referenceDay, semester: semester) },
                set: { onChange(TimeOfDay(date: $0, calendar: semester.calendar)) }
            ),
            displayedComponents: .hourAndMinute
        )
        .accessibilityLabel(title)
    }

    // MARK: 预览

    private var previewSection: some View {
        Section {
            HStack {
                Label("未来 7 天可安排", systemImage: "chart.bar")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(ScheduleViewEnvironment.durationText(weeklyTotalMinutes))
                    .font(StudyDesign.Typography.cardTitle)
                    .foregroundStyle(weeklyTotalMinutes > 0 ? StudyDesign.Colors.success : StudyDesign.Colors.labelSecondary)
            }

            ForEach(weekPreview, id: \.date) { item in
                HStack(spacing: StudyDesign.Spacing.normal) {
                    Text(item.weekday.shortLabel)
                        .font(.caption.weight(.semibold))
                        .frame(width: 32, alignment: .leading)
                    Text(ScheduleViewEnvironment.dayNumberText(item.date, semester: semester))
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        .frame(width: 24, alignment: .leading)
                    Text(item.availability.state.label)
                        .font(.caption2)
                        .studyMetaPill(tint: tint(for: item.availability.state))
                    Spacer(minLength: StudyDesign.Spacing.tight)
                    Text(ScheduleViewEnvironment.durationText(item.availability.totalFreeMinutes))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.availability.hasFreeTime ? StudyDesign.Colors.labelPrimary : StudyDesign.Colors.labelTertiary)
                }
                .accessibilityElement(children: .combine)
            }

            let selected = selectedDayAvailability
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                Text("\(selected.weekday.fullLabel) 明细")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                if selected.freeIntervals.isEmpty {
                    Text("没有满足阈值的空档。")
                        .font(.caption)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                } else {
                    ForEach(selected.freeIntervals) { interval in
                        Text("\(ScheduleViewEnvironment.intervalText(DateInterval(start: interval.start, end: interval.end), semester: semester)) · \(ScheduleViewEnvironment.durationText(interval.durationMinutes))")
                            .font(.caption)
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    }
                }
            }
            .padding(.top, 2)

            if let assumption = selected.assumptions.first {
                Text(assumption)
                    .font(.caption2)
                    .foregroundStyle(StudyDesign.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("预览只是试算，点击保存后才会写入存储。")
                .font(.caption2)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        } header: {
            Text("预览")
        }
    }

    private func tint(for state: AvailabilityState) -> Color {
        switch state {
        case .fullyFree: return StudyDesign.Colors.success
        case .partiallyFree: return StudyDesign.Colors.info
        case .fullyOccupied: return StudyDesign.Colors.warning
        case .noStudyWindow, .noRoutineConfigured: return StudyDesign.Colors.labelTertiary
        }
    }

    // MARK: 节次模板

    private var templateSection: some View {
        Section {
            ForEach(templates) { template in
                HStack(spacing: StudyDesign.Spacing.normal) {
                    TextField("节次名称", text: Binding(
                        get: { template.name },
                        set: { newValue in
                            updateTemplate(id: template.id) { $0.name = newValue }
                        }
                    ))
                    .studyInputChrome(size: .compact)
                    .frame(maxWidth: 120)
                    .accessibilityLabel("节次名称")

                    timeRow(title: "开始", time: template.start, referenceDay: todayStart) { updated in
                        updateTemplate(id: template.id) { $0.start = updated }
                    }
                    timeRow(title: "结束", time: template.end, referenceDay: todayStart) { updated in
                        updateTemplate(id: template.id) { $0.end = updated }
                    }
                }
                .font(.caption)
            }
            .onDelete { offsets in
                templates.remove(atOffsets: offsets)
            }

            Button {
                templates.append(PeriodTemplate(
                    name: "自定义节次",
                    start: TimeOfDay(hour: 8, minute: 0),
                    end: TimeOfDay(hour: 8, minute: 45),
                    order: templates.count
                ))
            } label: {
                Label("添加节次模板", systemImage: "plus.circle")
                    .font(.caption.weight(.semibold))
            }
        } header: {
            Text("节次模板")
        } footer: {
            Text("节次模板只是填时间用的快捷方式，不会自己占用时间。改动会随保存一起写入。")
        }
    }

    private func updateTemplate(id: UUID, mutate: (inout PeriodTemplate) -> Void) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        var template = templates[index]
        mutate(&template)
        templates[index] = template
    }

    // MARK: 辅助

    /// 取某个星期几在本周内的代表日期，用于把时刻落到具体某天。
    private func previewDay(for weekday: ScheduleWeekday) -> Date {
        let calendar = semester.calendar
        let offset = weekday.isoWeekdayNumber - 1
        return calendar.date(byAdding: .day, value: offset, to: ScheduleResolver.weekStartDate(containing: todayStart, semester: semester)) ?? todayStart
    }
}
