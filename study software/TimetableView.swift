import SwiftUI

// MARK: - ScheduleFeatureSupport
//
// 平台能力开关。放在视图层，方便 G 直接读取来做导航入口的门控。

enum ScheduleFeatureSupport {
    /// 手机默认显示当天课程；Mac 与宽屏默认显示周视图。
    static func defaultsToWeekView(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }

    /// 宽屏（Mac / iPad 横屏）可以并排显示周视图。
    static func supportsSideBySideWeek(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        #if os(macOS)
        return true
        #else
        return horizontalSizeClass == .regular
        #endif
    }
}

// MARK: - TimetableView
//
// 课表页面（纯数据参数 + 保存回调，不直接修改任何快照）。
//
// 接入方式（由调用页面注入）：
// ```
// TimetableView(
//     semester: store.snapshot.scheduleSemester,
//     isSemesterConfigured: store.snapshot.isSemesterConfigured,
//     courses: store.snapshot.scheduleCourses,
//     exceptions: store.snapshot.scheduleExceptions,
//     availabilitySettings: store.snapshot.availabilitySettings,
//     now: Date(),
//     onSaveCourse: { course in store.saveCourse(course) },
//     onDeleteCourse: { id in store.deleteCourse(id) },
//     onSaveException: { exception in store.saveScheduleException(exception) },
//     onDeleteException: { id in store.deleteScheduleException(id) },
//     onSaveSemester: { semester in store.saveSemester(semester) },
//     onSaveAvailabilitySettings: { settings, templates in
//         store.saveAvailabilityAndPeriodTemplates(settings: settings, templates: templates)
//     }
// )
// ```
// 只要回调为 `nil`，对应操作会显示为“未接入”，不会静默丢弃。

struct TimetableView: View {
    // 数据（只读输入）
    var semester: ScheduleSemester
    /// 调用方传入的时间即使是兜底值，也必须明确告知学期是否已配置。
    var isSemesterConfigured: Bool
    var courses: [Course]
    var exceptions: [ScheduleException]
    var availabilitySettings: AvailabilitySettings
    var periodTemplates: [PeriodTemplate] = PeriodTemplate.defaultTemplates
    /// 由调用方注入的“现在”。页面不会自己调用 `Date()`。
    var now: Date

    // 保存回调
    var onSaveCourse: ((Course) -> StoreChangeResult)?
    var onDeleteCourse: ((UUID) -> StoreChangeResult)?
    var onSaveException: ((ScheduleException) -> StoreChangeResult)?
    var onSaveExceptions: (([ScheduleException]) -> StoreChangeResult)?
    var onDeleteException: ((UUID) -> StoreChangeResult)?
    var onSaveSemester: ((ScheduleSemester) -> StoreChangeResult)?
    var onSaveAvailabilitySettings: ((AvailabilitySettings, [PeriodTemplate]) -> StoreChangeResult)?

    // 可选：从既有知识点的 subject 文本补全科目候选，避免让用户重复输入。
    var knownSubjectNames: [String] = []

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var mode: TimetableMode
    @State private var selectedDay: Date
    @State private var weekOffset: Int = 0
    @State private var editorContext: CourseEditorContext?
    @State private var exceptionEditorContext: ScheduleExceptionEditorContext?
    @State private var isShowingAvailabilitySettings = false
    @State private var isShowingSemesterEditor = false
    @State private var deletionErrorMessage: String?

    init(
        semester: ScheduleSemester,
        courses: [Course],
        exceptions: [ScheduleException],
        availabilitySettings: AvailabilitySettings,
        periodTemplates: [PeriodTemplate] = PeriodTemplate.defaultTemplates,
        now: Date,
        onSaveCourse: ((Course) -> StoreChangeResult)? = nil,
        onDeleteCourse: ((UUID) -> StoreChangeResult)? = nil,
        onSaveException: ((ScheduleException) -> StoreChangeResult)? = nil,
        onSaveExceptions: (([ScheduleException]) -> StoreChangeResult)? = nil,
        onDeleteException: ((UUID) -> StoreChangeResult)? = nil,
        onSaveSemester: ((ScheduleSemester) -> StoreChangeResult)? = nil,
        onSaveAvailabilitySettings: ((AvailabilitySettings, [PeriodTemplate]) -> StoreChangeResult)? = nil,
        knownSubjectNames: [String] = [],
        isSemesterConfigured: Bool
    ) {
        self.semester = semester
        self.isSemesterConfigured = isSemesterConfigured
        self.courses = courses
        self.exceptions = exceptions
        self.availabilitySettings = availabilitySettings
        self.periodTemplates = periodTemplates
        self.now = now
        self.onSaveCourse = onSaveCourse
        self.onDeleteCourse = onDeleteCourse
        self.onSaveException = onSaveException
        self.onSaveExceptions = onSaveExceptions
        self.onDeleteException = onDeleteException
        self.onSaveSemester = onSaveSemester
        self.onSaveAvailabilitySettings = onSaveAvailabilitySettings
        self.knownSubjectNames = knownSubjectNames

        let startOfNow = semester.calendar.startOfDay(for: now)
        _selectedDay = State(initialValue: startOfNow)
        _mode = State(initialValue: ScheduleFeatureSupport.defaultsToWeekView(horizontalSizeClass: nil) ? .week : .day)
    }

    // MARK: 派生数据

    /// 未设置学期时，以当前真实日历周作为预览，不使用兜底学期的 1970 起点。
    /// `weekOffset` 在预览模式下移动实际日期，不受兜底周数限制。
    private var displaySemester: ScheduleSemester {
        guard !isSemesterConfigured else { return semester }
        let calendar = semester.calendar
        let currentWeekStart = ScheduleResolver.weekStartDate(containing: now, semester: semester)
        let previewWeekStart = calendar.date(byAdding: .day, value: weekOffset * 7, to: currentWeekStart)
            ?? currentWeekStart
        return ScheduleSemester(
            firstWeekStart: previewWeekStart,
            weekCount: 1,
            timeZoneIdentifier: semester.timeZoneIdentifier
        )
    }

    private var today: Date { ScheduleViewEnvironment.startOfDay(now, semester: displaySemester) }

    private var semesterEditorDraft: ScheduleSemester {
        guard !isSemesterConfigured else { return semester }
        return ScheduleSemester(
            firstWeekStart: ScheduleResolver.weekStartDate(containing: now, semester: semester),
            weekCount: 20,
            timeZoneIdentifier: semester.timeZoneIdentifier
        )
    }

    private var sortedCourses: [Course] {
        courses.sorted {
            if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.name < $1.name
        }
    }

    private var selectedDaySchedule: ScheduleDay {
        ScheduleResolver.day(
            for: selectedDay,
            semester: displaySemester,
            courses: courses,
            exceptions: exceptions
        )
    }

    private var selectedDayAvailability: AvailabilityDay {
        let isToday = ScheduleViewEnvironment.isSameDay(selectedDay, today, semester: displaySemester)
        return AvailabilityCalculator.availability(
            on: selectedDay,
            semester: displaySemester,
            courses: courses,
            exceptions: exceptions,
            settings: availabilitySettings,
            now: isToday ? now : nil
        )
    }

    private var displayedWeekIndex: Int {
        guard isSemesterConfigured else { return 1 }
        let base = semester.weekIndex(for: today)
        let clamped = min(max(base, 1), semester.lastWeek)
        return min(max(clamped + weekOffset, 1), semester.lastWeek)
    }

    private var displayedWeek: ScheduleWeek {
        ScheduleResolver.week(
            index: displayedWeekIndex,
            semester: displaySemester,
            courses: courses,
            exceptions: exceptions,
            today: today
        )
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StudyDesign.Spacing.roomy) {
                StudyPageHeader(
                    title: "课表",
                    subtitle: "安排课程占用，并据此计算每天可用于自主学习的时间。",
                    icon: "calendar.badge.clock",
                    tint: StudyDesign.Colors.info
                )

                semesterBar
                headerControls

                if !isSemesterConfigured {
                    warningBanner(
                        icon: "info.circle",
                        tint: StudyDesign.Colors.info,
                        title: "尚未设置学期",
                        message: "周课表按真实日历周预览。点击「学期设置」填写第一周和总周数后，单双周与指定周规则才能准确显示。"
                    )
                }

                if let deletionErrorMessage {
                    warningBanner(
                        icon: "exclamationmark.triangle",
                        tint: StudyDesign.Colors.warning,
                        title: "删除未完成",
                        message: deletionErrorMessage
                    )
                }

                if periodTemplatesFailValidation {
                    warningBanner(
                        icon: "exclamationmark.triangle",
                        tint: StudyDesign.Colors.warning,
                        title: "节次模板有无效项",
                        message: "有节次模板的结束时间不晚于开始时间，这些模板不会被使用。请到「可用时间设置」检查。"
                    )
                }

                if mode == .day {
                    daySection
                } else {
                    weekSection
                }

                courseListSection
            }
            .padding(.horizontal, StudyDesign.Spacing.relaxed)
            .padding(.vertical, StudyDesign.Spacing.roomy)
            .frame(maxWidth: StudyDesign.Layout.contentMaxWidth, alignment: .leading)
        }
        .background(StudyDesign.Gradients.pageBackdrop.ignoresSafeArea())
        .navigationTitle("课表")
        .sheet(item: $editorContext) { context in
            CourseEditorSheet(
                mode: context.mode,
                semester: displaySemester,
                existingCourses: courses,
                periodTemplates: periodTemplates,
                knownSubjectNames: knownSubjectNames,
                initialDraft: context.draft,
                referenceDate: selectedDay,
                onSave: { course in handleCourseSave(context: context, course: course) },
                onApplyChange: { base, scope, newExceptions in
                    applyOnceChange(context: context, base: base, scope: scope, exceptions: newExceptions)
                },
                onDeleteCourse: context.mode.isEditingExisting ? onDeleteCourse : nil,
                onCancel: { editorContext = nil }
            )
        }
        .sheet(item: $exceptionEditorContext) { context in
            ScheduleExceptionEditor(
                semester: displaySemester,
                course: context.course,
                initialDraft: context.draft,
                onSave: { exception in
                    let result = onSaveException?(exception) ?? .failed("课表例外保存入口不可用，请关闭后重试。")
                    if result.mayCloseEditor { exceptionEditorContext = nil }
                    return result
                },
                onDelete: context.editingExceptionID.map { id in
                    {
                        let result = onDeleteException?(id) ?? .failed("课表例外删除入口不可用，请关闭后重试。")
                        if result.mayCloseEditor { exceptionEditorContext = nil }
                        return result
                    }
                },
                onCancel: { exceptionEditorContext = nil }
            )
        }
        .sheet(isPresented: $isShowingAvailabilitySettings) {
            AvailabilitySettingsView(
                semester: displaySemester,
                settings: availabilitySettings,
                courses: courses,
                exceptions: exceptions,
                now: now,
                periodTemplates: periodTemplates,
                onSaveSettings: { settings, templates in
                    let result = onSaveAvailabilitySettings?(settings, templates) ?? .failed("作息保存入口不可用，请关闭后重试。")
                    if result.mayCloseEditor { isShowingAvailabilitySettings = false }
                    return result
                },
                onCancel: { isShowingAvailabilitySettings = false }
            )
        }
        .sheet(isPresented: $isShowingSemesterEditor) {
            SemesterEditorSheet(
                semester: semesterEditorDraft,
                onSave: { updated in
                    let result = onSaveSemester?(updated) ?? .failed("学期保存入口不可用，请关闭后重试。")
                    if result.mayCloseEditor { isShowingSemesterEditor = false }
                    return result
                },
                onCancel: { isShowingSemesterEditor = false }
            )
        }
    }

    // MARK: 顶栏

    private var semesterBar: some View {
        HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: "graduationcap.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(StudyDesign.Colors.primary)
                .frame(width: 34, height: 34)
                .background(StudyDesign.Colors.inputBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small))
                .overlay(
                    RoundedRectangle(cornerRadius: StudyDesign.Radius.small)
                        .stroke(StudyDesign.Colors.primary.opacity(0.28), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(semesterSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(semesterDetail)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            Button {
                isShowingSemesterEditor = true
            } label: {
                Label("学期设置", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(onSaveSemester == nil)
            .help(onSaveSemester == nil ? "需要 G 接入 onSaveSemester 回调" : "设置第一周与总周数")
        }
        .studyCard(fill: StudyDesign.Colors.cardBackground)
        .studyCardStroke()
    }

    private var semesterSummary: String {
        guard isSemesterConfigured else { return "尚未设置学期" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.timeZone = semester.timeZone
        return "第一周 \(formatter.string(from: semester.firstWeekStart)) 起 · 共 \(semester.lastWeek) 周"
    }

    private var semesterDetail: String {
        guard isSemesterConfigured else { return "日历周预览 · \(weekRangeText)" }
        return "学期时区 \(semester.timeZoneIdentifier)｜第 \(displayedWeekIndex) / \(semester.lastWeek) 周"
    }

    private var headerControls: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(spacing: StudyDesign.Spacing.normal) {
                Picker("视图", selection: $mode) {
                    Text("当天").tag(TimetableMode.day)
                    Text("周课表").tag(TimetableMode.week)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityLabel("课表视图模式")

                Spacer(minLength: StudyDesign.Spacing.tight)

                Button {
                    weekOffset = 0
                    selectedDay = today
                } label: {
                    Label("回到今天", systemImage: "location.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityHint("把课表跳到今天所在的一周")

                Button {
                    isShowingAvailabilitySettings = true
                } label: {
                    Label("可用时间", systemImage: "clock.badge.checkmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(onSaveAvailabilitySettings == nil)
                .help(onSaveAvailabilitySettings == nil ? "需要 G 接入 onSaveAvailabilitySettings 回调" : "设置作息与最短可用空档")

                addCourseButton
            }

            if mode == .week {
                HStack(spacing: StudyDesign.Spacing.normal) {
                    Button {
                        moveWeek(by: -1)
                    } label: {
                        Label("上一周", systemImage: "chevron.left").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSemesterConfigured && displayedWeekIndex <= 1)
                    .accessibilityLabel("上一周")

                    Text(weekRangeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)

                    Button {
                        moveWeek(by: 1)
                    } label: {
                        Label("下一周", systemImage: "chevron.right").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isSemesterConfigured && displayedWeekIndex >= semester.lastWeek)
                    .accessibilityLabel("下一周")

                    Spacer(minLength: StudyDesign.Spacing.tight)

                    if weekOffset != 0 {
                        Text("已离开今天")
                            .font(.caption2.weight(.bold))
                            .studyMetaPill(tint: StudyDesign.Colors.warning)
                    }
                }
            }
        }
    }

    private var weekRangeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        formatter.timeZone = displaySemester.timeZone
        let start = displayedWeek.days.first?.date ?? displayedWeek.start
        let end = displayedWeek.days.last?.date ?? start
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    private func moveWeek(by offset: Int) {
        weekOffset += offset
        if let shiftedDay = displaySemester.calendar.date(byAdding: .day, value: offset * 7, to: selectedDay) {
            selectedDay = shiftedDay
        }
    }

    @ViewBuilder
    private var addCourseButton: some View {
        let enabled = onSaveCourse != nil
        Group {
            #if os(macOS)
            Button {
                presentNewCourse()
            } label: {
                Label("添加课程", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(StudyActionPillButtonStyle(tint: StudyDesign.Colors.primary, prominence: .primary, minWidth: 118))
            #else
            Button {
                presentNewCourse()
            } label: {
                Label("添加课程", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            #endif
        }
        .disabled(!enabled)
        .help(enabled ? "新建一门课程" : "需要 G 接入 onSaveCourse 回调后才能保存")
        .accessibilityHint(enabled ? "打开课程编辑表单" : "尚未接入存储，暂不可用")
    }

    // MARK: 当天视图

    private var daySection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            dayPicker

            let schedule = selectedDaySchedule
            let availability = selectedDayAvailability

            if schedule.courses.isEmpty {
                StudyEmptyState(
                    title: schedule.weekIndex == nil ? "这一天不在学期范围内" : "这一天没有课程",
                    subtitle: schedule.weekIndex == nil
                        ? "当前学期从 \(semesterSummary)，可以到「学期设置」调整。"
                        : "没有课程占用时，可安排时间就是你的学习窗口。仍然可以添加临时补课。",
                    icon: "calendar",
                    accentIcon: "clock",
                    accentTint: StudyDesign.Colors.info,
                    actionLabel: onSaveCourse != nil ? "添加课程" : nil,
                    action: onSaveCourse != nil ? { presentNewCourse() } : nil
                )
            } else {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.tight) {
                    ForEach(schedule.courses) { occurrence in
                        courseRow(occurrence: occurrence)
                    }
                }
            }

            if schedule.hasConflict {
                warningBanner(
                    icon: "arrow.triangle.branch",
                    tint: StudyDesign.Colors.warning,
                    title: "有课程时间重叠",
                    message: "重叠时段只会被计算一次，不会重复占用你的可安排时间。可以在课程列表里调整时间。"
                )
            }

            ForEach(schedule.notes, id: \.self) { note in
                warningBanner(
                    icon: "info.circle",
                    tint: StudyDesign.Colors.info,
                    title: "提示",
                    message: note
                )
            }

            availabilityCard(availability)
        }
    }

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: StudyDesign.Spacing.compact) {
                ForEach(displayedWeek.days) { day in
                    dayChip(day)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func dayChip(_ day: ScheduleWeekDay) -> some View {
        let isSelected = ScheduleViewEnvironment.isSameDay(day.date, selectedDay, semester: displaySemester)
        let tint = day.isToday ? StudyDesign.Colors.primary : StudyDesign.Colors.labelSecondary
        return Button {
            selectedDay = day.date
        } label: {
            VStack(spacing: 2) {
                Text(day.weekday.shortLabel)
                    .font(.caption2.weight(.semibold))
                Text(ScheduleViewEnvironment.dayNumberText(day.date, semester: displaySemester))
                    .font(.callout.weight(.bold))
                Text(day.courses.isEmpty ? "无课" : "\(day.courses.count) 节")
                    .font(.caption2)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
            }
            .frame(minWidth: 58)
            .padding(.vertical, StudyDesign.Spacing.tight)
            .padding(.horizontal, StudyDesign.Spacing.compact)
            .background(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.16) : StudyDesign.Colors.inputBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(isSelected ? tint.opacity(0.55) : StudyDesign.Colors.inputHairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.weekday.fullLabel)\(day.isToday ? "，今天" : "")，\(day.courses.count) 节课程")
    }

    // MARK: 周视图

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            if courses.isEmpty {
                StudyEmptyState(
                    title: "还没有任何课程",
                    subtitle: "添加课程后，周课表会显示每天的占用与可选自习时间。没有课表时仍然可以按作息偏好计算可用时间。",
                    icon: "calendar.badge.plus",
                    accentIcon: "clock",
                    accentTint: StudyDesign.Colors.info,
                    actionLabel: onSaveCourse != nil ? "添加第一门课" : nil,
                    action: onSaveCourse != nil ? { presentNewCourse() } : nil
                )
            } else {
                TimetableWeekGrid(
                    week: displayedWeek,
                    semester: displaySemester,
                    tintForCourse: subjectTint(for:),
                    onSelectDay: { day in
                        selectedDay = day
                        mode = .day
                    }
                )
            }

            availabilityCard(selectedDayAvailability)
        }
    }

    // MARK: 课程行 / 列表

    private func courseRow(occurrence: ResolvedCourseOccurrence) -> some View {
        let tint = subjectTint(for: occurrence.subject.id)
        return HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
            VStack(spacing: 2) {
                Text(ScheduleViewEnvironment.timeText(occurrence.start, semester: displaySemester))
                    .font(.callout.weight(.bold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Rectangle()
                    .fill(tint.opacity(0.5))
                    .frame(width: 2, height: 18)
                Text(ScheduleViewEnvironment.timeText(occurrence.end, semester: displaySemester))
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }
            .frame(width: 56)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                HStack(spacing: StudyDesign.Spacing.compact) {
                    Text(occurrence.courseName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    if occurrence.isMakeup {
                        Text("补课").studyMetaPill(tint: StudyDesign.Colors.warning)
                    }
                    if occurrence.isReplaced {
                        Text("换课").studyMetaPill(tint: StudyDesign.Colors.info)
                    }
                }

                HStack(spacing: StudyDesign.Spacing.compact) {
                    Label(occurrence.subjectName, systemImage: "book.closed")
                    if !occurrence.location.isEmpty {
                        Label(occurrence.location, systemImage: "mappin.and.ellipse")
                    }
                    if !occurrence.teacher.isEmpty {
                        Label(occurrence.teacher, systemImage: "person")
                    }
                    if let template = occurrence.templateName {
                        Text(template)
                    }
                }
                .font(.caption)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .lineLimit(1)
            }

            Spacer(minLength: StudyDesign.Spacing.tight)

            if let course = courses.first(where: { $0.id == occurrence.courseID }) {
                courseActions(course)
            }
        }
        .padding(StudyDesign.Spacing.normal)
        .background(StudyDesign.Colors.surfaceFill, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(occurrence.courseName)，\(ScheduleViewEnvironment.timeText(occurrence.start, semester: displaySemester)) 到 \(ScheduleViewEnvironment.timeText(occurrence.end, semester: displaySemester))，\(occurrence.subjectName)"
        )
    }

    private var courseListSection: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack {
                Label("全部课程", systemImage: "list.bullet.rectangle")
                    .font(StudyDesign.Typography.sectionTitle)
                Spacer()
                Text("\(courses.count) 门")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }

            if sortedCourses.isEmpty {
                Text("还没有课程。添加课程只会记录占用与学习背景，不会自动生成学习完成记录。")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            } else {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    ForEach(sortedCourses) { course in
                        courseListRow(course)
                    }
                }
            }

            if !exceptions.isEmpty {
                Divider()
                Label("临时调整（\(exceptions.count) 条）", systemImage: "calendar.badge.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    ForEach(exceptionSummaryItems) { item in
                        exceptionRow(item)
                    }
                }
            }
        }
        .studyCard(fill: StudyDesign.Colors.cardBackground)
        .studyCardStroke()
    }

    private func courseListRow(_ course: Course) -> some View {
        let tint = subjectTint(for: course.subject.id)
        return HStack(alignment: .center, spacing: StudyDesign.Spacing.normal) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(tint)
                .frame(width: 3, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text("\(course.summaryLine) · \(course.subjectName)")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                if let lastWeek = course.recurrence.lastWeek, course.recurrence.parity != .custom {
                    Text("止于第 \(lastWeek) 周")
                        .font(.caption2)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }
            }

            Spacer(minLength: StudyDesign.Spacing.tight)
            courseActions(course)
        }
        .padding(.vertical, StudyDesign.Spacing.compact)
        .padding(.horizontal, StudyDesign.Spacing.tight)
        .background(StudyDesign.Colors.inputBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: StudyDesign.Radius.compact, style: .continuous))
    }

    @ViewBuilder
    private func courseActions(_ course: Course) -> some View {
        HStack(spacing: StudyDesign.Spacing.compact) {
            Button {
                editorContext = CourseEditorContext(
                    mode: .edit(course.id),
                    draft: CourseDraft(course: course)
                )
            } label: {
                Label("编辑", systemImage: "pencil").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(onSaveCourse == nil)
            .help("编辑课程")
            .accessibilityLabel("编辑 \(course.name)")

            Button {
                editorContext = CourseEditorContext(
                    mode: .duplicate(sourceID: course.id),
                    draft: CourseDraft(duplicating: course)
                )
            } label: {
                Label("复制", systemImage: "doc.on.doc").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(onSaveCourse == nil)
            .help("复制一门同样的课程")
            .accessibilityLabel("复制 \(course.name)")

            Button {
                exceptionEditorContext = ScheduleExceptionEditorContext(
                    course: course,
                    draft: ScheduleExceptionDraft(courseID: course.id, date: nextOccurrenceDate(after: now, for: course)),
                    editingExceptionID: nil
                )
            } label: {
                Label("临时调整", systemImage: "calendar.badge.minus").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(onSaveException == nil)
            .help("添加停课 / 换课 / 补课")
            .accessibilityLabel("为 \(course.name) 添加临时调整")

            Button(role: .destructive) {
                let result = onDeleteCourse?(course.id)
                    ?? .failed("课程删除入口不可用，请稍后重试。")
                handleDeletionResult(result)
            } label: {
                Label("删除", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(onDeleteCourse == nil)
            .help(onDeleteCourse == nil ? "需要 G 接入 onDeleteCourse 回调" : "删除这门课程")
            .accessibilityLabel("删除 \(course.name)")
        }
        .font(.caption)
    }

    // MARK: 可用时间卡片

    private func availabilityCard(_ availability: AvailabilityDay) -> some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.normal) {
            HStack(alignment: .firstTextBaseline) {
                Label("可安排时间", systemImage: "clock.badge.checkmark")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(ScheduleViewEnvironment.durationText(availability.totalFreeMinutes))
                    .font(StudyDesign.Typography.cardTitle)
                    .foregroundStyle(availability.hasFreeTime ? StudyDesign.Colors.success : StudyDesign.Colors.labelSecondary)
            }

            Text(availability.state.explanation)
                .font(.caption)
                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !availability.studyWindows.isEmpty {
                HStack(spacing: StudyDesign.Spacing.compact) {
                    Text("学习窗口")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    ForEach(availability.studyWindows, id: \.start) { window in
                        Text(ScheduleViewEnvironment.intervalText(window, semester: displaySemester))
                            .font(.caption2.weight(.semibold))
                            .studyMetaPill(tint: StudyDesign.Colors.secondary)
                    }
                }
            }

            if availability.freeIntervals.isEmpty {
                Text(availability.occupiedMinutesWithinWindows > 0
                     ? "当天学习窗口内已被占用 \(ScheduleViewEnvironment.durationText(availability.occupiedMinutesWithinWindows))。"
                     : "当天没有可安排的空档。")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            } else {
                VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                    ForEach(availability.freeIntervals) { interval in
                        HStack(spacing: StudyDesign.Spacing.normal) {
                            Image(systemName: interval.trimmedByNow ? "clock.arrow.circlepath" : "circle.dashed")
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.success)
                                .frame(width: 18)
                            Text(ScheduleViewEnvironment.intervalText(
                                DateInterval(start: interval.start, end: interval.end),
                                semester: displaySemester
                            ))
                            .font(.subheadline.weight(.semibold))
                            Spacer(minLength: StudyDesign.Spacing.tight)
                            Text(ScheduleViewEnvironment.durationText(interval.durationMinutes))
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(ScheduleViewEnvironment.intervalText(DateInterval(start: interval.start, end: interval.end), semester: displaySemester))，可用 \(interval.durationMinutes) 分钟"
                        )
                    }
                }
            }

            if !availability.discardedIntervals.isEmpty {
                Text("另有 \(availability.discardedIntervals.count) 段空档小于 \(availability.minimumFreeBlockMinutes) 分钟，未计入容量（\(availability.discardedIntervals.map { "\($0.durationMinutes) 分钟" }.joined(separator: "、"))）。")
                    .font(.caption2)
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !availability.occupiedIntervals.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
                        ForEach(availability.occupiedIntervals) { interval in
                            HStack(spacing: StudyDesign.Spacing.normal) {
                                Image(systemName: icon(for: interval.kind))
                                    .font(.caption)
                                    .foregroundStyle(tint(for: interval.kind))
                                    .frame(width: 18)
                                Text(interval.sourceText)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: StudyDesign.Spacing.tight)
                                Text(ScheduleViewEnvironment.intervalText(
                                    DateInterval(start: interval.start, end: interval.end),
                                    semester: displaySemester
                                ))
                                .font(.caption)
                                .foregroundStyle(StudyDesign.Colors.labelSecondary)
                            }
                        }
                    }
                    .padding(.top, StudyDesign.Spacing.compact)
                } label: {
                    Text("当天占用明细（\(availability.occupiedIntervals.count) 段）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudyDesign.Colors.labelSecondary)
                }
            }

            ForEach(availability.assumptions, id: \.self) { assumption in
                warningBanner(
                    icon: "questionmark.circle",
                    tint: StudyDesign.Colors.warning,
                    title: "默认假设",
                    message: assumption
                )
            }
        }
        .studyCard(fill: StudyDesign.Colors.cardBackground)
        .studyCardStroke(color: availability.hasFreeTime ? StudyDesign.Colors.success.opacity(0.30) : StudyDesign.Colors.accentHairline)
    }

    private func warningBanner(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: StudyDesign.Spacing.normal) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(StudyDesign.Spacing.normal)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func icon(for kind: OccupancyKind) -> String {
        switch kind {
        case .course: return "book.closed"
        case .custom: return "pin"
        case .commute: return "bus"
        case .buffer: return "hourglass"
        }
    }

    private func tint(for kind: OccupancyKind) -> Color {
        switch kind {
        case .course: return StudyDesign.Colors.info
        case .custom: return StudyDesign.Colors.secondary
        case .commute: return StudyDesign.Colors.warning
        case .buffer: return StudyDesign.Colors.labelTertiary
        }
    }

    // MARK: 例外列表

    private struct ExceptionSummaryItem: Identifiable {
        var exception: ScheduleException
        var courseName: String
        var id: UUID { exception.id }
    }

    private var exceptionSummaryItems: [ExceptionSummaryItem] {
        exceptions
            .compactMap { exception in
                guard let course = courses.first(where: { $0.id == exception.courseID }) else { return nil }
                return ExceptionSummaryItem(exception: exception, courseName: course.name)
            }
            .sorted { $0.exception.date < $1.exception.date }
    }

    private func exceptionRow(_ item: ExceptionSummaryItem) -> some View {
        HStack(spacing: StudyDesign.Spacing.normal) {
            Text(ScheduleViewEnvironment.dateText(item.exception.date, semester: displaySemester))
                .font(.caption.weight(.semibold))
                .frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.courseName) · \(item.exception.summaryLine)")
                    .font(.caption)
                    .foregroundStyle(StudyDesign.Colors.labelPrimary)
                if !item.exception.note.isEmpty {
                    Text(item.exception.note)
                        .font(.caption2)
                        .foregroundStyle(StudyDesign.Colors.labelTertiary)
                }
            }
            Spacer(minLength: StudyDesign.Spacing.tight)
            Button {
                guard let course = courses.first(where: { $0.id == item.exception.courseID }) else { return }
                exceptionEditorContext = ScheduleExceptionEditorContext(
                    course: course,
                    draft: ScheduleExceptionDraft(exception: item.exception),
                    editingExceptionID: item.exception.id
                )
            } label: {
                Label("编辑", systemImage: "pencil").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(onSaveException == nil)

            Button(role: .destructive) {
                let result = onDeleteException?(item.exception.id)
                    ?? .failed("课表例外删除入口不可用，请稍后重试。")
                handleDeletionResult(result)
            } label: {
                Label("删除", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(onDeleteException == nil)
        }
        .padding(.vertical, 2)
    }

    // MARK: 交互

    static func deletionErrorMessage(for result: StoreChangeResult) -> String? {
        switch result {
        case .saved, .unchanged:
            return nil
        case .failed(let message):
            return message
        }
    }

    private func handleDeletionResult(_ result: StoreChangeResult) {
        deletionErrorMessage = Self.deletionErrorMessage(for: result)
    }

    private func presentNewCourse() {
        let weekday = ScheduleResolver.weekday(of: selectedDay, semester: displaySemester)
        editorContext = CourseEditorContext(
            mode: .create,
            draft: CourseDraft(
                subject: SubjectRef(displayName: knownSubjectNames.first ?? ""),
                weekday: weekday
            )
        )
    }

    private func handleCourseSave(context: CourseEditorContext, course: Course) -> StoreChangeResult {
        let result = onSaveCourse?(course) ?? .failed("课程保存入口不可用，请关闭后重试。")
        guard result.mayCloseEditor else { return result }
        editorContext = nil
        // 新增/修改后把视图切到这门课所在的那一天，避免用户以为没保存成功。
        selectedDay = nextOccurrenceDate(after: now.addingTimeInterval(-86_400 * 6), for: course)
        return result
    }

    /// “仅这一次”修改：不触碰重复规则，只写一条例外。
    private func applyOnceChange(
        context: CourseEditorContext,
        base: Course,
        scope: CourseEditScope,
        exceptions newExceptions: [ScheduleException]
    ) -> StoreChangeResult {
        switch scope {
        case .entireSeries:
            return handleCourseSave(context: context, course: base)
        case .onlyThisTime:
            guard let onSaveExceptions else {
                return .failed("无法保存“仅这一次”的调整：例外保存功能尚未接入，课程规则未修改。")
            }
            let result = onSaveExceptions(newExceptions)
            guard result.mayCloseEditor else { return result }
            editorContext = nil
            selectedDay = nextOccurrenceDate(after: now.addingTimeInterval(-86_400 * 6), for: base)
            return result
        }
    }

    /// 该课程下一次出现的日期（含今天），用于确定例外默认日期。
    private func nextOccurrenceDate(after reference: Date, for course: Course) -> Date {
        let calendar = displaySemester.calendar
        let start = calendar.startOfDay(for: reference)
        for offset in 0...(displaySemester.lastWeek * 7) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { break }
            let scheduleDay = ScheduleResolver.day(
                for: day,
                semester: displaySemester,
                courses: [course],
                exceptions: exceptions
            )
            if !scheduleDay.courses.isEmpty {
                return calendar.startOfDay(for: day)
            }
        }
        return calendar.startOfDay(for: reference)
    }

    // MARK: 样式辅助

    private var periodTemplatesFailValidation: Bool {
        periodTemplates.contains { !$0.isValid }
    }

    /// 科目配色：只用稳定科目 id 决定，改名不会换色。
    private func subjectTint(for subjectID: UUID) -> Color {
        let palette: [Color] = [
            StudyDesign.Colors.primary,
            StudyDesign.Colors.secondary,
            StudyDesign.Colors.info,
            StudyDesign.Colors.success,
            StudyDesign.Colors.warning,
            StudyDesign.Colors.danger
        ]
        var hasher = StableHasher()
        hasher.combine(subjectID.uuidString)
        let uuid = hasher.finalize()
        let index = Int(uuid.uuid.0) % palette.count
        return palette[index]
    }
}

/// Shared sheet wrapper for the Plan and Settings timetable entry points.
/// The completion action only dismisses the sheet; all edits remain owned by
/// TimetableView's existing save callbacks.
struct TimetableSheetHost: View {
    @EnvironmentObject private var store: AppStore
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            TimetableView(
                semester: store.snapshot.scheduleSemester ?? .fallback,
                courses: store.snapshot.scheduleCourses,
                exceptions: store.snapshot.scheduleExceptions,
                availabilitySettings: store.snapshot.availabilitySettings,
                periodTemplates: store.snapshot.schedulePeriodTemplates,
                now: Date(),
                onSaveCourse: { store.saveCourse($0) },
                onDeleteCourse: { store.deleteCourse(id: $0) },
                onSaveException: { store.saveScheduleException($0) },
                onSaveExceptions: { store.saveScheduleExceptions($0) },
                onDeleteException: { store.deleteScheduleException(id: $0) },
                onSaveSemester: { store.saveSemester($0) },
                onSaveAvailabilitySettings: { settings, templates in
                    store.saveAvailabilityAndPeriodTemplates(settings: settings, templates: templates)
                },
                knownSubjectNames: Array(Set(store.snapshot.knowledgePoints.map(\.subject))).sorted(),
                isSemesterConfigured: store.snapshot.isSemesterConfigured
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                        .help("关闭课表")
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 1_020, minHeight: 720)
#endif
    }
}

// MARK: - 模式与编辑上下文

enum TimetableMode: String, CaseIterable, Identifiable {
    case day
    case week

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "当天"
        case .week: return "周课表"
        }
    }
}

enum CourseEditorMode: Hashable {
    case create
    /// 编辑既有课程：保持 id 不变，实现“改这一条”。
    case edit(UUID)
    /// 复制既有课程：内容照抄，身份是新的。
    case duplicate(sourceID: UUID)

    var title: String {
        switch self {
        case .create: return "添加课程"
        case .edit: return "编辑课程"
        case .duplicate: return "复制课程"
        }
    }

    var isEditingExisting: Bool {
        if case .edit = self { return true }
        return false
    }
}

struct CourseEditorContext: Identifiable {
    var id = UUID()
    var mode: CourseEditorMode
    var draft: CourseDraft
}

struct ScheduleExceptionEditorContext: Identifiable {
    var id = UUID()
    var course: Course
    var draft: ScheduleExceptionDraft
    var editingExceptionID: UUID?
}

// MARK: - 周课表网格

struct TimetableWeekGrid: View {
    var week: ScheduleWeek
    var semester: ScheduleSemester
    var tintForCourse: (UUID) -> Color
    var onSelectDay: (Date) -> Void

    private let hourHeight: CGFloat = 44
    private let timeColumnWidth: CGFloat = 44
    private let dayColumnMinWidth: CGFloat = 96

    init(
        week: ScheduleWeek,
        semester: ScheduleSemester,
        tintForCourse: @escaping (UUID) -> Color,
        onSelectDay: @escaping (Date) -> Void
    ) {
        self.week = week
        self.semester = semester
        self.tintForCourse = tintForCourse
        self.onSelectDay = onSelectDay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StudyDesign.Spacing.compact) {
            headerRow

            ScrollView(.vertical, showsIndicators: true) {
                HStack(alignment: .top, spacing: 0) {
                    hourColumn
                    ForEach(week.days) { day in
                        dayColumn(day)
                    }
                }
            }
            .frame(height: 460)
            .background(StudyDesign.Colors.dataBackground, in: RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StudyDesign.Radius.small, style: .continuous)
                    .stroke(StudyDesign.Colors.accentHairline, lineWidth: 1)
            )

            Text("周视图按学期时区（\(semester.timeZoneIdentifier)）显示，切换设备时区不会让星期错位。点任意一天可切回当天详情。")
                .font(.caption2)
                .foregroundStyle(StudyDesign.Colors.labelTertiary)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Color.clear.frame(width: timeColumnWidth, height: 1)
            ForEach(week.days) { day in
                Button {
                    onSelectDay(day.date)
                } label: {
                    VStack(spacing: 1) {
                        Text(day.weekday.shortLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(day.isToday ? StudyDesign.Colors.primary : StudyDesign.Colors.labelSecondary)
                        Text(ScheduleViewEnvironment.dayNumberText(day.date, semester: semester))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(StudyDesign.Colors.labelPrimary)
                    }
                    .frame(minWidth: dayColumnMinWidth, maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看 \(day.weekday.fullLabel) 的课程")
            }
        }
    }

    private var hourColumn: some View {
        VStack(spacing: 0) {
            ForEach(hourRange, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(StudyDesign.Colors.labelTertiary)
                    .frame(width: timeColumnWidth, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, StudyDesign.Spacing.compact)
            }
        }
    }

    private func dayColumn(_ day: ScheduleWeekDay) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(hourRange, id: \.self) { _ in
                    Rectangle()
                        .fill(StudyDesign.Colors.inputHairline.opacity(0.55))
                        .frame(height: hourHeight)
                }
            }

            ForEach(day.courses) { occurrence in
                courseBlock(occurrence)
            }
        }
        .frame(minWidth: dayColumnMinWidth, maxWidth: .infinity)
        .frame(height: CGFloat(hourRange.count) * hourHeight, alignment: .top)
        .background(day.isToday ? StudyDesign.Colors.primary.opacity(0.045) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelectDay(day.date) }
    }

    private func courseBlock(_ occurrence: ResolvedCourseOccurrence) -> some View {
        let tint = tintForCourse(occurrence.subject.id)
        // 布局算法在 ScheduleResolver 里（可测试），这里只做分钟 → 点数的换算。
        let layout = ScheduleResolver.timelineLayout(
            for: occurrence,
            hourRange: hourRange,
            semester: semester
        )
        let metrics = (
            offset: CGFloat(layout.offsetMinutes) / 60 * hourHeight,
            height: CGFloat(layout.heightMinutes) / 60 * hourHeight
        )
        return VStack(alignment: .leading, spacing: 1) {
            Text(occurrence.courseName)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(2)
            if metrics.height > 32 {
                Text(ScheduleViewEnvironment.timeText(occurrence.start, semester: semester))
                    .font(.system(size: 9))
                    .foregroundStyle(StudyDesign.Colors.labelSecondary)
            }
        }
        .foregroundStyle(StudyDesign.Colors.labelPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(height: max(metrics.height, 18), alignment: .top)
        .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(tint.opacity(0.55), lineWidth: 1)
        )
        .padding(.horizontal, 2)
        .offset(y: metrics.offset)
        .accessibilityLabel(
            "\(occurrence.courseName)，\(ScheduleViewEnvironment.timeText(occurrence.start, semester: semester))"
        )
    }

    /// 只渲染有课的时段，避免在手机上铺满 24 小时。
    private var hourRange: [Int] {
        let all = week.days.flatMap { $0.courses }
        guard !all.isEmpty else { return Array(7...22) }
        let calendar = semester.calendar
        let startHours = all.map { calendar.component(.hour, from: $0.start) }
        let endHours = all.map { occurrence -> Int in
            let hourComponent = calendar.component(.hour, from: occurrence.end)
            let minuteComponent = calendar.component(.minute, from: occurrence.end)
            return minuteComponent > 0 ? hourComponent + 1 : max(hourComponent, 1)
        }
        let lower = max(0, (startHours.min() ?? 7) - 1)
        let upper = min(24, (endHours.max() ?? 22) + 1)
        guard lower < upper else { return Array(7...22) }
        return Array(lower..<upper)
    }
}

// MARK: - 视图层时间格式化（不使用 Calendar.current）

enum ScheduleViewEnvironment {
    /// 学期时区下的当天零点。
    static func startOfDay(_ date: Date, semester: ScheduleSemester) -> Date {
        semester.calendar.startOfDay(for: date)
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date, semester: ScheduleSemester) -> Bool {
        semester.calendar.isDate(lhs, inSameDayAs: rhs)
    }

    static func timeText(_ date: Date, semester: ScheduleSemester) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = semester.timeZone
        return formatter.string(from: date)
    }

    static func intervalText(_ interval: DateInterval, semester: ScheduleSemester) -> String {
        "\(timeText(interval.start, semester: semester))–\(timeText(interval.end, semester: semester))"
    }

    static func dayNumberText(_ date: Date, semester: ScheduleSemester) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "d"
        formatter.timeZone = semester.timeZone
        return formatter.string(from: date)
    }

    static func dateText(_ date: Date, semester: ScheduleSemester) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d EEE"
        formatter.timeZone = semester.timeZone
        return formatter.string(from: date)
    }

    static func monthDayText(_ date: Date, semester: ScheduleSemester) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.timeZone = semester.timeZone
        return formatter.string(from: date)
    }

    static func durationText(_ minutes: Int) -> String {
        guard minutes > 0 else { return "0 分钟" }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) 分钟" }
        if remainder == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(remainder) 分钟"
    }
}
