import Foundation

// MARK: - 课表数据契约（模块 A 定稿，B 模块实现算法）
//
// B 模块已经给出 `Course` / `ScheduleSemester` / `ScheduleException` /
// `CourseRecurrence` / `AvailabilitySettings` 的具体实现与持久化键名
// （见 `ScheduleResolver.swift`、`AvailabilityCalculator.swift`、
// `SchedulePersistenceKeys`）。本文件**不重复定义**这些类型，只补齐
// 公共契约要求而现有类型未覆盖的信息：
//
// 1. `Semester`：契约要求"ID + 名称"，而 `ScheduleSemester` 只有时间与周数。
//    这里把身份单独持久化为 `SemesterIdentity`，日期/周数/时区仍以
//    `scheduleSemester` 为唯一来源，避免同一事实两处存储。
// 2. `CourseScheduleRule`：契约要求的"排课规则"视图。B 模块把规则内嵌在
//    `Course` 里，因此这里提供只读投影，不新增第二份存储。
// 3. `CourseBurdenLevel`：契约要求 Course 的"负担等级"。`Course` 属于 B
//    模块，本轮不修改其定义，因此负担等级以"课程 ID → 等级"的旁表持久化，
//    并在这里提供读写访问器；后续 B 并入 `Course` 时只需迁移这张旁表。
// 4. `AvailabilityPreferences`：契约要求的偏好聚合
//    （学习窗口 + 睡眠与固定占用 + 缓冲 + 每日上限 + 自动减量开关）。

// MARK: - 学期身份

/// 学期身份（ID + 名称）。与 `ScheduleSemester` 一一对应，单独持久化。
struct SemesterIdentity: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String = "", createdAt: Date = StudyTimestamp.unspecified) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
    }

    var displayName: String {
        name.isEmpty ? "当前学期" : name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? StudyTimestamp.unspecified
    }
}

/// 契约中的 `Semester`：ID、名称、第一周开始日期、周数、时区。
///
/// 它是 `SemesterIdentity` 与 `ScheduleSemester` 的只读聚合视图，
/// 不单独持久化，避免"第一周开始日期"出现两个互相矛盾的副本。
struct Semester: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// 第一周开始日期（该学期时区下的周一零点）。
    var firstWeekStart: Date
    var weekCount: Int
    var timeZoneIdentifier: String

    init(
        id: UUID = UUID(),
        name: String,
        firstWeekStart: Date,
        weekCount: Int,
        timeZoneIdentifier: String
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.firstWeekStart = firstWeekStart
        self.weekCount = max(1, weekCount)
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    init(identity: SemesterIdentity, schedule: ScheduleSemester) {
        self.init(
            id: identity.id,
            name: identity.displayName,
            firstWeekStart: schedule.firstWeekStart,
            weekCount: schedule.weekCount,
            timeZoneIdentifier: schedule.timeZoneIdentifier
        )
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }

    var isConfigured: Bool { firstWeekStart.timeIntervalSince1970 > 0 }

    /// 投影回 B 模块的 `ScheduleSemester`。
    var scheduleSemester: ScheduleSemester {
        ScheduleSemester(
            firstWeekStart: firstWeekStart,
            weekCount: weekCount,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        firstWeekStart = try container.decodeIfPresent(Date.self, forKey: .firstWeekStart)
            ?? StudyTimestamp.unspecified
        weekCount = max(1, try container.decodeIfPresent(Int.self, forKey: .weekCount) ?? 20)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? TimeZone.current.identifier
    }
}

// MARK: - 排课规则投影

/// 契约中的 `CourseScheduleRule`。
///
/// 由 `Course` 的 `weekday` / `startTime` / `endTime` / `recurrence` 投影而来，
/// 是只读视图：修改排课仍然走 B 模块的 `CourseDraft`。
struct CourseScheduleRule: Codable, Hashable, Sendable {
    var courseID: UUID
    var weekday: ScheduleWeekday
    /// 开始分钟（0...1439）。
    var startMinutes: Int
    /// 结束分钟（0...1439）。
    var endMinutes: Int
    /// 0 = 当天结束；1 = 次日结束。
    var endDayOffset: Int
    /// 生效起始周次（1 起）。B 模块的规则默认从第 1 周开始。
    var firstWeek: Int
    /// 生效结束周次；`nil` 表示跟随学期总周数。
    var lastWeek: Int?
    /// 单双周 / 每周 / 指定周。
    var parity: CourseWeekParity
    /// `parity == .custom` 时生效的周次，升序去重。
    var customWeeks: [Int]

    init(
        courseID: UUID,
        weekday: ScheduleWeekday,
        startMinutes: Int,
        endMinutes: Int,
        endDayOffset: Int = 0,
        firstWeek: Int = 1,
        lastWeek: Int? = nil,
        parity: CourseWeekParity = .every,
        customWeeks: [Int] = []
    ) {
        self.courseID = courseID
        self.weekday = weekday
        self.startMinutes = min(max(startMinutes, 0), 24 * 60 - 1)
        self.endMinutes = min(max(endMinutes, 0), 24 * 60 - 1)
        self.endDayOffset = max(0, endDayOffset)
        self.firstWeek = max(1, firstWeek)
        self.lastWeek = lastWeek.map { max(1, $0) }
        self.parity = parity
        self.customWeeks = Array(Set(customWeeks.filter { $0 >= 1 })).sorted()
    }

    var startTimeOfDay: TimeOfDay { TimeOfDay(minutes: startMinutes) }
    var endTimeOfDay: TimeOfDay { TimeOfDay(minutes: endMinutes) }

    /// 该规则在某学期周次是否生效（复用 B 模块的判定，保持一致）。
    func isActive(week: Int, semester: ScheduleSemester) -> Bool {
        guard week >= firstWeek else { return false }
        return ScheduleResolver.isActive(
            week: week,
            recurrence: CourseRecurrence(parity: parity, weeks: customWeeks, lastWeek: lastWeek),
            semester: semester
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courseID = try container.decodeIfPresent(UUID.self, forKey: .courseID) ?? UUID()
        weekday = try container.decodeIfPresent(ScheduleWeekday.self, forKey: .weekday) ?? .monday
        startMinutes = min(max(try container.decodeIfPresent(Int.self, forKey: .startMinutes) ?? 8 * 60, 0), 24 * 60 - 1)
        endMinutes = min(max(try container.decodeIfPresent(Int.self, forKey: .endMinutes) ?? 8 * 60 + 45, 0), 24 * 60 - 1)
        endDayOffset = max(0, try container.decodeIfPresent(Int.self, forKey: .endDayOffset) ?? 0)
        firstWeek = max(1, try container.decodeIfPresent(Int.self, forKey: .firstWeek) ?? 1)
        lastWeek = try container.decodeIfPresent(Int.self, forKey: .lastWeek)
        let rawParity = try container.decodeIfPresent(String.self, forKey: .parity) ?? CourseWeekParity.every.rawValue
        parity = CourseWeekParity(rawValue: rawParity) ?? .every
        customWeeks = (try container.decodeIfPresent([Int].self, forKey: .customWeeks) ?? []).filter { $0 >= 1 }.sorted()
    }
}

extension Course {
    /// 契约要求的排课规则视图。
    var scheduleRule: CourseScheduleRule {
        let derivedFirstWeek: Int
        if recurrence.parity == .custom, let minWeek = recurrence.weeks.min() {
            derivedFirstWeek = minWeek
        } else {
            derivedFirstWeek = 1
        }
        return CourseScheduleRule(
            courseID: id,
            weekday: weekday,
            startMinutes: startTime.minutes,
            endMinutes: endTime.minutes,
            endDayOffset: endDayOffset,
            firstWeek: derivedFirstWeek,
            lastWeek: recurrence.lastWeek,
            parity: recurrence.parity,
            customWeeks: recurrence.weeks
        )
    }
}

// MARK: - 课程负担等级

/// 负担等级：用于计划生成时给重课日减量。
enum CourseBurdenLevel: String, Codable, CaseIterable, Sendable {
    case light
    case moderate
    case heavy
    case veryHeavy

    var label: String {
        switch self {
        case .light: return "轻松"
        case .moderate: return "一般"
        case .heavy: return "较重"
        case .veryHeavy: return "很重"
        }
    }

    /// 建议的学习负荷系数（1.0 = 标准）。只影响排布，不改变任务本身。
    var workloadFactor: Double {
        switch self {
        case .light: return 0.9
        case .moderate: return 1.0
        case .heavy: return 1.15
        case .veryHeavy: return 1.3
        }
    }

    /// 数值越大负担越重，便于排序。
    var rank: Int {
        switch self {
        case .light: return 0
        case .moderate: return 1
        case .heavy: return 2
        case .veryHeavy: return 3
        }
    }
}

/// 课程负担旁表记录（`Course` 本体不改动，见文件头说明）。
struct CourseBurdenAssignment: Identifiable, Codable, Hashable, Sendable {
    var courseID: UUID
    var level: CourseBurdenLevel
    var updatedAt: Date

    var id: UUID { courseID }

    init(courseID: UUID, level: CourseBurdenLevel = .moderate, updatedAt: Date = StudyTimestamp.unspecified) {
        self.courseID = courseID
        self.level = level
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courseID = try container.decodeIfPresent(UUID.self, forKey: .courseID) ?? UUID()
        let rawLevel = try container.decodeIfPresent(String.self, forKey: .level) ?? CourseBurdenLevel.moderate.rawValue
        level = CourseBurdenLevel(rawValue: rawLevel) ?? .moderate
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? StudyTimestamp.unspecified
    }
}

// MARK: - 可用时间偏好

/// 计划偏好中与"容量"相关的部分：
/// 契约要求 `AvailabilityPreferences` 必须包含"每日上限"与"自动减量开关"，
/// 而 B 模块的 `AvailabilitySettings` 只覆盖窗口/睡眠/占用/缓冲。
struct PlanningPreferences: Codable, Hashable, Sendable {
    /// 每日学习上限（分钟）。`nil` = 不设上限。
    var dailyCapMinutes: Int?
    /// 自动减量开关：未完成时是否允许自动降级为保底计划。
    var autoReduceEnabled: Bool
    /// 单个任务的最小预计时长（分钟）。
    var minimumTaskMinutes: Int
    /// 单个任务的最大预计时长（分钟）。
    var maximumTaskMinutes: Int
    var breakMinutes: Int
    /// 计划里分配给"复习任务"的时间占比（0...1）。
    var reviewShareRatio: Double
    /// 规划时区标识。
    var planningTimeZoneIdentifier: String
    /// 保底计划是否允许自动生成。
    var allowsMinimumPlan: Bool
    /// 保底比例：保底范围 = 计划范围 × 该比例。
    var minimumScopeRatio: Double
    /// 用户手动指定的精力档位原始值（`StudyEnergyLevel.rawValue`）。
    ///
    /// `nil` 表示"没有手动设置"，规划时按课表负担自动估计。
    /// 这里刻意存 `String` 而不是直接存 `StudyEnergyLevel`：
    /// 该枚举属于 C 模块的规划引擎，存储层不应反向依赖它。
    var energyLevelIdentifier: String?

    init(
        dailyCapMinutes: Int? = nil,
        autoReduceEnabled: Bool = false,
        minimumTaskMinutes: Int = 10,
        maximumTaskMinutes: Int = 90,
        breakMinutes: Int = 5,
        reviewShareRatio: Double = 0.6,
        planningTimeZoneIdentifier: String = TimeZone.current.identifier,
        allowsMinimumPlan: Bool = true,
        minimumScopeRatio: Double = 0.4,
        energyLevelIdentifier: String? = nil
    ) {
        self.dailyCapMinutes = dailyCapMinutes.map { max(0, $0) }
        self.autoReduceEnabled = autoReduceEnabled
        self.minimumTaskMinutes = max(1, minimumTaskMinutes)
        self.maximumTaskMinutes = max(self.minimumTaskMinutes, maximumTaskMinutes)
        self.breakMinutes = max(0, breakMinutes)
        self.reviewShareRatio = min(max(reviewShareRatio, 0), 1)
        self.planningTimeZoneIdentifier = planningTimeZoneIdentifier
        self.allowsMinimumPlan = allowsMinimumPlan
        self.minimumScopeRatio = min(max(minimumScopeRatio, 0.05), 1)
        self.energyLevelIdentifier = Self.normalizedEnergyIdentifier(energyLevelIdentifier)
    }

    /// 默认偏好：未显式设置每日上限，**自动减量关闭**（用户可主动采用手动方案）。
    static func defaults(planningTimeZoneIdentifier: String) -> PlanningPreferences {
        PlanningPreferences(planningTimeZoneIdentifier: planningTimeZoneIdentifier)
    }

    var timeZone: TimeZone { TimeZone(identifier: planningTimeZoneIdentifier) ?? TimeZone.current }

    /// 保底范围：按比例缩短，并保证不放大。
    func minimumScope(for planned: StudyScope) -> StudyScope? {
        guard allowsMinimumPlan, planned.isPositive else { return nil }
        let ratio = minimumScopeRatio
        guard ratio < 1 else { return nil }
        return planned.scaled(by: ratio)
    }

    /// 把预计分钟裁剪到 [最小值, 最大值]。
    func clampedMinutes(_ minutes: Int) -> Int {
        min(max(minutes, minimumTaskMinutes), maximumTaskMinutes)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cap = try container.decodeIfPresent(Int.self, forKey: .dailyCapMinutes)
        dailyCapMinutes = cap.map { max(0, $0) }
        // 缺少该字段 = 用户从未显式设置过 → 默认关闭自动减量（需求 3）。
        // 已经保存过显式偏好的数据保持不变，不会被升级过程覆盖。
        autoReduceEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoReduceEnabled) ?? false
        minimumTaskMinutes = max(1, try container.decodeIfPresent(Int.self, forKey: .minimumTaskMinutes) ?? 10)
        maximumTaskMinutes = max(minimumTaskMinutes, try container.decodeIfPresent(Int.self, forKey: .maximumTaskMinutes) ?? 90)
        breakMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 5)
        reviewShareRatio = min(max(try container.decodeIfPresent(Double.self, forKey: .reviewShareRatio) ?? 0.6, 0), 1)
        planningTimeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .planningTimeZoneIdentifier)
            ?? TimeZone.current.identifier
        allowsMinimumPlan = try container.decodeIfPresent(Bool.self, forKey: .allowsMinimumPlan) ?? true
        minimumScopeRatio = min(max(try container.decodeIfPresent(Double.self, forKey: .minimumScopeRatio) ?? 0.4, 0.05), 1)
        energyLevelIdentifier = Self.normalizedEnergyIdentifier(
            try container.decodeIfPresent(String.self, forKey: .energyLevelIdentifier)
        )
    }

    /// 只接受"较累 / 正常 / 充足"三个已知档位；其它值一律视为"没有手动设置"，
    /// 避免旧数据或手写 JSON 里出现无法识别的档位后影响规划。
    static func normalizedEnergyIdentifier(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        return ["tired", "normal", "energetic"].contains(raw) ? raw : nil
    }
}

/// 契约中的 `AvailabilityPreferences`：
/// 每日学习窗口、睡眠与固定占用、缓冲、每日上限、自动减量开关。
struct AvailabilityPreferences: Codable, Hashable, Sendable {
    /// 学习窗口 / 睡眠 / 固定占用 / 通勤 / 缓冲（B 模块 `AvailabilitySettings`）。
    var routine: AvailabilitySettings
    /// 每日上限 / 自动减量开关 / 规划时区。
    var planning: PlanningPreferences

    init(routine: AvailabilitySettings = .unconfigured, planning: PlanningPreferences = PlanningPreferences()) {
        self.routine = routine
        self.planning = planning
    }

    /// 每日学习窗口。
    var studyWindows: [DayTimeRange] {
        routine.weekdayStudyWindows + routine.weekendStudyWindows
    }

    /// 睡眠与固定占用。
    var sleepAndFixedBlocks: [DayTimeRange] {
        routine.sleepWindows + routine.customBlocks
    }

    /// 缓冲时长（分钟）。
    var bufferMinutes: Int { routine.bufferMinutes }

    /// 每日上限（分钟）。
    var dailyCapMinutes: Int? { planning.dailyCapMinutes }

    /// 自动减量开关。
    var autoReduceEnabled: Bool { planning.autoReduceEnabled }

    var timeZoneIdentifier: String { planning.planningTimeZoneIdentifier }

    var hasStudyWindows: Bool { !studyWindows.isEmpty }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routine = try container.decodeIfPresent(AvailabilitySettings.self, forKey: .routine) ?? .unconfigured
        planning = try container.decodeIfPresent(PlanningPreferences.self, forKey: .planning) ?? PlanningPreferences()
    }
}

extension AvailabilitySettings {
    /// "用户尚未配置作息"的空偏好。
    ///
    /// 不用 `AvailabilitySettings()`：那个默认值会预填工作日晚间/周末窗口，
    /// 于是 `hasExplicitRoutine` 永远为真，B 模块的"未设置作息，以下为默认假设"
    /// 提示就永远不会出现。空偏好让默认假设只作为**解释**出现，而不被当成
    /// 用户已确认的设置写进存储。
    static var unconfigured: AvailabilitySettings {
        AvailabilitySettings(
            weekdayStudyWindows: [],
            weekendStudyWindows: [],
            sleepWindows: [],
            customBlocks: []
        )
    }

    /// 默认假设（与 `AvailabilityCalculator` 内部使用的默认值一致）。
    static var assumedDefaults: AvailabilitySettings {
        AvailabilitySettings(
            weekdayStudyWindows: AvailabilitySettings.defaultWeekdayStudyWindows,
            weekendStudyWindows: AvailabilitySettings.defaultWeekendStudyWindows,
            sleepWindows: AvailabilitySettings.defaultSleepWindows,
            customBlocks: []
        )
    }
}

// MARK: - StoreSnapshot 课表访问器

extension StoreSnapshot {
    /// 课表快照；未设置学期时返回 `nil`（调用方必须显式提示"尚未设置学期"）。
    var schedule: ScheduleSnapshot? {
        guard let scheduleSemester else { return nil }
        return ScheduleSnapshot(
            semester: scheduleSemester,
            courses: scheduleCourses,
            exceptions: scheduleExceptions,
            periodTemplates: schedulePeriodTemplates
        )
    }

    /// 契约 `Semester` 视图。
    var semester: Semester? {
        guard let scheduleSemester else { return nil }
        return Semester(identity: semesterIdentity, schedule: scheduleSemester)
    }

    var isSemesterConfigured: Bool { scheduleSemester != nil }

    /// 有效课表（缺学期时用兜底学期，仅供算法不崩溃；界面必须提示未设置）。
    var scheduleForComputation: ScheduleSnapshot {
        if let schedule { return schedule }
        // 无学期也要按用户的规划时区解释学习窗口，不能随运行设备时区漂移。
        var fallbackSemester = ScheduleSemester.fallback
        fallbackSemester.timeZoneIdentifier = planningTimeZoneIdentifier ?? TimeZone.current.identifier
        return ScheduleSnapshot(semester: fallbackSemester)
    }

    /// 聚合可用时间偏好。
    var availabilityPreferences: AvailabilityPreferences {
        AvailabilityPreferences(routine: availabilitySettings, planning: planningPreferences)
    }

    /// 统一规划上下文：时区优先级 = 计划偏好 > 学期时区 > 系统时区。
    func planningContext(now: Date) -> PlanningContext {
        let identifier = planningTimeZoneIdentifier ?? scheduleSemester?.timeZoneIdentifier ?? TimeZone.current.identifier
        return PlanningContext(now: now, timeZoneIdentifier: identifier)
    }

    /// 当前生效的规划时区标识。
    var planningTimeZoneIdentifier: String? {
        let trimmed = planningPreferences.planningTimeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: 负担等级旁表

    func courseBurdenLevel(forCourseID courseID: UUID) -> CourseBurdenLevel? {
        courseBurdenLevels.first { $0.courseID == courseID }?.level
    }

    /// 写入负担等级（纯值操作，不落盘）。等级相同则原样返回，避免无意义写入。
    func settingCourseBurdenLevel(
        _ level: CourseBurdenLevel,
        forCourseID courseID: UUID,
        at now: Date
    ) -> StoreSnapshot {
        guard courseBurdenLevel(forCourseID: courseID) != level else { return self }
        var copy = self
        copy.courseBurdenLevels.removeAll { $0.courseID == courseID }
        copy.courseBurdenLevels.append(CourseBurdenAssignment(courseID: courseID, level: level, updatedAt: now))
        copy.courseBurdenLevels.sort { $0.courseID.uuidString < $1.courseID.uuidString }
        return copy
    }

    /// 负担等级映射（供计划生成一次性读取）。
    ///
    /// 手工去重而不是 `Dictionary(uniqueKeysWithValues:)`：解码来的旁表可能含
    /// 重复课程 ID，那种情况下数据层必须降级而不是崩溃。
    var courseBurdenMap: [UUID: CourseBurdenLevel] {
        var result: [UUID: CourseBurdenLevel] = [:]
        for assignment in courseBurdenLevels where result[assignment.courseID] == nil {
            result[assignment.courseID] = assignment.level
        }
        return result
    }
}
