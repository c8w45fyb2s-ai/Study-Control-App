import Foundation

// MARK: - 学习计划数据层（模块 A）
//
// 本文件是「今日计划 / 最低任务 / 学习记录」三类功能的公共数据契约，
// 只依赖 Foundation，供纯算法测试直接编译使用。
//
// 设计约束：
// - 所有时间入口都由调用方传入 `PlanningContext`（now + 日历 + 规划时区），
//   本文件内部不调用 `Date()`。
// - 类型是值语义，不持有 UI、通知或存储句柄；持久化由 G 的统一入口完成。
// - 学到的内容与答题正确分开、部分完成与整体完成分开、
//   已学习 / 保底完成 / 标准完成分开记录。

// MARK: - 时间

/// 时间戳常量。
///
/// 仅用于「解码时字段缺失」的兜底。运行期算法不允许用 `Date()` 取当前时间，
/// 因此这里的值刻意是一个可识别的历史时刻（1970-01-01），
/// 一旦出现在真实数据里就说明写入方漏传了 `now`。
enum StudyTimestamp {
    static let unspecified = Date(timeIntervalSince1970: 0)
}

/// 规划上下文：统一承载 `now`、日历与规划时区。
///
/// 算法不读系统时钟，也不读 `Calendar.current`；一切时间换算都通过它进行。
struct PlanningContext {
    /// 当前时间（外部注入）。
    var now: Date
    /// 已经设置为 `timeZone` 的日历。
    var calendar: Calendar
    /// 规划时区（学期时区或用户选择的时区）。
    var timeZone: TimeZone
    var locale: Locale

    init(
        now: Date,
        timeZone: TimeZone,
        calendarIdentifier: Calendar.Identifier = .gregorian,
        locale: Locale = Locale(identifier: "zh_CN")
    ) {
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        var calendar = Calendar(identifier: calendarIdentifier)
        calendar.timeZone = timeZone
        calendar.locale = locale
        self.calendar = calendar
    }

    init(
        now: Date,
        timeZoneIdentifier: String,
        calendarIdentifier: Calendar.Identifier = .gregorian,
        locale: Locale = Locale(identifier: "zh_CN")
    ) {
        self.init(
            now: now,
            timeZone: TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current,
            calendarIdentifier: calendarIdentifier,
            locale: locale
        )
    }

    var timeZoneIdentifier: String { timeZone.identifier }

    /// 把某个时间点换算成规划时区下的日期标识。
    func dayKey(for date: Date) -> StudyDayKey {
        StudyDayKey(date: date, timeZone: timeZone)
    }

    /// 当前时刻的日期标识。
    var todayKey: StudyDayKey { dayKey(for: now) }

    func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// 两个时间点之间的整分钟数（向下取整，负数返回 0）。
    func minutes(from start: Date, to end: Date) -> Int {
        max(0, Int(floor(end.timeIntervalSince(start) / 60)))
    }

    /// 与既有 `ScheduleSemester` 共用时区与周次规则。
    var semesterTimeZone: TimeZone { timeZone }
}

/// 本地日期 + 规划时区。
///
/// 刻意不直接用 `Date`：同一时刻在两个时区下可能属于不同「学习日」，
/// 而计划、完成事件、奖励都必须按用户所在时区的学习日归档。
///
/// 身份 = (年, 月, 日, 时区标识)。同一日期在不同时区下是两个不同的键。
struct StudyDayKey: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var timeZoneIdentifier: String

    init(year: Int, month: Int, day: Int, timeZoneIdentifier: String) {
        self.year = year
        self.month = month
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier.isEmpty ? TimeZone.current.identifier : timeZoneIdentifier
    }

    init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1,
            timeZoneIdentifier: timeZone.identifier
        )
    }

    init(date: Date, planningTimeZoneIdentifier: String) {
        self.init(date: date, timeZone: TimeZone(identifier: planningTimeZoneIdentifier) ?? TimeZone.current)
    }

    init(date: Date, context: PlanningContext) {
        self.init(date: date, timeZone: context.timeZone)
    }

    /// `"2026-07-11"`。
    var localDateString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { "\(localDateString)@\(timeZoneIdentifier)" }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current }

    /// 该学习日在规划时区下的零点。
    func startOfDay(calendar: Calendar? = nil) -> Date? {
        var calendar = calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)
    }

    /// 判断某个绝对时间是否落在该学习日内。
    func contains(date: Date, calendar: Calendar? = nil) -> Bool {
        var calendar = calendar ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == year && components.month == month && components.day == day
    }

    /// 前后偏移若干天，时区保持不变。
    func advanced(byDays days: Int) -> StudyDayKey {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let start = startOfDay(calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: days, to: start) else {
            return self
        }
        return StudyDayKey(date: shifted, timeZone: timeZone)
    }

    /// 升序比较：先日期，再时区标识（保证 `sorted()` 结果稳定）。
    static func < (lhs: StudyDayKey, rhs: StudyDayKey) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        return lhs.timeZoneIdentifier < rhs.timeZoneIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        year = try container.decodeIfPresent(Int.self, forKey: .year) ?? 1970
        month = try container.decodeIfPresent(Int.self, forKey: .month) ?? 1
        day = try container.decodeIfPresent(Int.self, forKey: .day) ?? 1
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? TimeZone.current.identifier
    }
}

// MARK: - 任务范围（实际完成范围的量纲）

/// 任务量的量纲。单位不同的两个范围**不可比较**，绝不换算成一个"进度百分比"。
enum StudyScopeUnit: String, Codable, CaseIterable, Sendable {
    case minutes
    case tasks
    case questions
    case pages
    case sections
    case custom

    var label: String {
        switch self {
        case .minutes: return "分钟"
        case .tasks: return "个任务"
        case .questions: return "道题"
        case .pages: return "页"
        case .sections: return "节"
        case .custom: return "自定义"
        }
    }
}

/// 任务范围：计划了多少、实际完成多少都用它表达。
struct StudyScope: Codable, Hashable, Sendable {
    var unit: StudyScopeUnit
    var amount: Double
    /// 仅 `unit == .custom` 时有意义，例如「个单词」。
    var customUnitLabel: String?

    init(unit: StudyScopeUnit, amount: Double, customUnitLabel: String? = nil) {
        self.unit = unit
        self.amount = max(0, amount)
        self.customUnitLabel = customUnitLabel
    }

    static func minutes(_ amount: Double) -> StudyScope { StudyScope(unit: .minutes, amount: amount) }
    static func tasks(_ amount: Double) -> StudyScope { StudyScope(unit: .tasks, amount: amount) }
    static func questions(_ amount: Double) -> StudyScope { StudyScope(unit: .questions, amount: amount) }
    static func pages(_ amount: Double) -> StudyScope { StudyScope(unit: .pages, amount: amount) }
    static func sections(_ amount: Double) -> StudyScope { StudyScope(unit: .sections, amount: amount) }

    static let zero = StudyScope(unit: .minutes, amount: 0)

    var isZero: Bool { amount <= 0 }
    var isPositive: Bool { amount > 0 }

    var unitLabel: String {
        if unit == .custom {
            let trimmed = (customUnitLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? StudyScopeUnit.custom.label : trimmed
        }
        return unit.label
    }

    var displayText: String {
        let formatted = amount == amount.rounded() ? String(Int(amount)) : String(format: "%.1f", amount)
        return "\(formatted) \(unitLabel)"
    }

    /// 量纲是否一致。只有一致时才允许比较。
    func isComparable(to other: StudyScope) -> Bool {
        guard unit == other.unit else { return false }
        if unit == .custom {
            let lhs = (customUnitLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = (other.customUnitLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return lhs == rhs
        }
        return true
    }

    /// 完成比例。量纲不同或计划量为 0 时返回 `nil`——表示"无法比较"，
    /// 调用方必须显式处理，而不是拿到一个编造的 0%/100%。
    func completionRatio(relativeTo planned: StudyScope) -> Double? {
        guard isComparable(to: planned), planned.amount > 0 else { return nil }
        return amount / planned.amount
    }

    /// 是否属于"部分完成"。无法比较时返回 `nil`。
    func isPartial(relativeTo planned: StudyScope) -> Bool? {
        guard let ratio = completionRatio(relativeTo: planned) else { return nil }
        return ratio > 0 && ratio < 1
    }

    /// 按比例缩短（用于自动减量）。量纲不同时返回自身，不做换算。
    func scaled(by ratio: Double, rounding: FloatingPointRoundingRule = .down) -> StudyScope {
        guard ratio > 0, ratio < 1 else { return self }
        let scaled = (amount * ratio).rounded(rounding)
        return StudyScope(unit: unit, amount: scaled, customUnitLabel: customUnitLabel)
    }

    func clamped(minimum: StudyScope?, maximum: StudyScope?) -> StudyScope {
        var result = self
        if let maximum, isComparable(to: maximum), result.amount > maximum.amount {
            result = maximum
        }
        if let minimum, isComparable(to: minimum), result.amount < minimum.amount {
            result = minimum
        }
        return result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawUnit = try container.decodeIfPresent(String.self, forKey: .unit) ?? StudyScopeUnit.minutes.rawValue
        unit = StudyScopeUnit(rawValue: rawUnit) ?? .minutes
        amount = max(0, try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0)
        customUnitLabel = try container.decodeIfPresent(String.self, forKey: .customUnitLabel)
    }
}

// MARK: - 完成档次

/// 已学习 / 保底完成 / 标准完成——三者分别记录，不互相折叠。
enum PlanCompletionTier: String, Codable, CaseIterable, Sendable {
    /// 已学习：产生了有效学习，但没到保底门槛。
    case studied
    /// 保底完成：达到减量后的最低范围。
    case minimum
    /// 标准完成：达到原计划范围。
    case standard

    var label: String {
        switch self {
        case .studied: return "已学习"
        case .minimum: return "保底完成"
        case .standard: return "标准完成"
        }
    }

    /// 判档规则。范围不可比时返回 `nil`，由调用方显式处理（不猜档）。
    static func resolve(
        completed: StudyScope,
        planned: StudyScope,
        minimum: StudyScope?
    ) -> PlanCompletionTier? {
        guard let ratio = completed.completionRatio(relativeTo: planned) else { return nil }
        guard ratio > 0 else { return nil }
        if ratio >= 1 { return .standard }
        if let minimum, completed.isComparable(to: minimum), completed.amount >= minimum.amount, minimum.amount > 0 {
            return .minimum
        }
        return .studied
    }

    /// 是否计入"保底完成"及以上。
    var satisfiesMinimum: Bool {
        self == .minimum || self == .standard
    }
}

// MARK: - 任务来源

/// 计划任务来源：复习任务 / 课程回顾 / 预习 / 用户手动。
enum DailyPlanItemSourceKind: String, Codable, CaseIterable, Sendable {
    case reviewTask
    case courseReview
    case preview
    case manual

    var label: String {
        switch self {
        case .reviewTask: return "复习任务"
        case .courseReview: return "课程回顾"
        case .preview: return "预习"
        case .manual: return "手动任务"
        }
    }

    /// 是否必须绑定真实课程资料/课程记录，避免编造内容。
    var requiresRealCourse: Bool {
        self == .courseReview || self == .preview
    }
}

/// 用户创建并持久化的独立学习任务。
struct ManualStudyTask: Codable, Hashable, Identifiable, Sendable {
    static let estimatedMinutesRange = 1...1440

    nonisolated static func precedesInCandidateOrder(_ lhs: ManualStudyTask, _ rhs: ManualStudyTask) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case (.none, .some): return true
        case (.some, .none): return false
        case let (.some(left), .some(right)) where left != right: return left < right
        default:
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var id: UUID
    var title: String
    /// 旧版手动任务备注。新建入口不再收集备注，但迁移时保留旧值。
    var note: String
    /// 到期日可选；为空表示立即进入候选任务池。
    var dueDate: Date?
    var estimatedMinutes: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        dueDate: Date? = nil,
        estimatedMinutes: Int = 15,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dueDate = dueDate
        self.estimatedMinutes = min(max(estimatedMinutes, Self.estimatedMinutesRange.lowerBound), Self.estimatedMinutesRange.upperBound)
        self.createdAt = createdAt
    }

    /// 兼容迁移前测试数据与旧调用点：原安排日转成新的可选到期日。
    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        dayKey: StudyDayKey,
        estimatedMinutes: Int = 15,
        createdAt: Date = Date()
    ) {
        self.init(
            id: id,
            title: title,
            note: note,
            dueDate: dayKey.startOfDay(),
            estimatedMinutes: estimatedMinutes,
            createdAt: createdAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case note
        case dueDate
        case estimatedMinutes
        case createdAt
        case dayKey // v6 legacy field; decoded as a date during migration.
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = (try container.decodeIfPresent(String.self, forKey: .title) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        note = (try container.decodeIfPresent(String.self, forKey: .note) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate) {
            self.dueDate = dueDate
        } else if let legacyDayKey = try container.decodeIfPresent(StudyDayKey.self, forKey: .dayKey) {
            self.dueDate = legacyDayKey.startOfDay()
        } else {
            dueDate = nil
        }
        let decodedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes) ?? 15
        estimatedMinutes = min(max(decodedMinutes, Self.estimatedMinutesRange.lowerBound), Self.estimatedMinutesRange.upperBound)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(note, forKey: .note)
        try container.encodeIfPresent(dueDate, forKey: .dueDate)
        try container.encode(estimatedMinutes, forKey: .estimatedMinutes)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// 任务来源。所有计划项都必须能回答"这条任务从哪来"。
struct DailyPlanItemSource: Codable, Hashable, Sendable {
    var kind: DailyPlanItemSourceKind
    /// 既有 `ReviewTask.id`。
    var reviewTaskID: UUID?
    /// 课程 ID（课程回顾 / 预习）。
    var courseID: UUID?
    /// `ScheduleResolver` 解析出的课程实例 ID。
    var occurrenceID: UUID?
    var knowledgePointID: UUID?
    /// 可持久化的手动任务身份，保证同名任务互不合并。
    var manualTaskID: UUID?
    /// 用户手动任务时由用户填写的来源说明，可以为空。
    var manualNote: String?

    init(
        kind: DailyPlanItemSourceKind,
        reviewTaskID: UUID? = nil,
        courseID: UUID? = nil,
        occurrenceID: UUID? = nil,
        knowledgePointID: UUID? = nil,
        manualNote: String? = nil,
        manualTaskID: UUID? = nil
    ) {
        self.kind = kind
        self.reviewTaskID = reviewTaskID
        self.courseID = courseID
        self.occurrenceID = occurrenceID
        self.knowledgePointID = knowledgePointID
        self.manualNote = manualNote
        self.manualTaskID = manualTaskID
    }

    static func reviewTask(_ id: UUID, knowledgePointID: UUID? = nil) -> DailyPlanItemSource {
        DailyPlanItemSource(kind: .reviewTask, reviewTaskID: id, knowledgePointID: knowledgePointID)
    }

    static func courseReview(courseID: UUID, occurrenceID: UUID? = nil) -> DailyPlanItemSource {
        DailyPlanItemSource(kind: .courseReview, courseID: courseID, occurrenceID: occurrenceID)
    }

    static func preview(courseID: UUID, occurrenceID: UUID? = nil) -> DailyPlanItemSource {
        DailyPlanItemSource(kind: .preview, courseID: courseID, occurrenceID: occurrenceID)
    }

    static func manual(
        note: String? = nil,
        knowledgePointID: UUID? = nil,
        manualTaskID: UUID? = nil
    ) -> DailyPlanItemSource {
        DailyPlanItemSource(kind: .manual, knowledgePointID: knowledgePointID, manualNote: note, manualTaskID: manualTaskID)
    }

    /// 通用标题：只使用真实存在的课程/任务名称，没有资料时退化为通用表述，
    /// 绝不编造章节号、题号或知识点。
    static func genericTitle(kind: DailyPlanItemSourceKind, name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .reviewTask:
            return trimmed.isEmpty ? "复习任务" : trimmed
        case .courseReview:
            return trimmed.isEmpty ? "课程回顾" : "课程回顾：\(trimmed)"
        case .preview:
            return trimmed.isEmpty ? "课前预习" : "课前预习：\(trimmed)"
        case .manual:
            return trimmed.isEmpty ? "手动任务" : trimmed
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? DailyPlanItemSourceKind.manual.rawValue
        kind = DailyPlanItemSourceKind(rawValue: rawKind) ?? .manual
        reviewTaskID = try container.decodeIfPresent(UUID.self, forKey: .reviewTaskID)
        courseID = try container.decodeIfPresent(UUID.self, forKey: .courseID)
        occurrenceID = try container.decodeIfPresent(UUID.self, forKey: .occurrenceID)
        knowledgePointID = try container.decodeIfPresent(UUID.self, forKey: .knowledgePointID)
        manualTaskID = try container.decodeIfPresent(UUID.self, forKey: .manualTaskID)
        manualNote = try container.decodeIfPresent(String.self, forKey: .manualNote)
    }
}

// MARK: - 计划项

enum DailyPlanItemStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case inProgress
    case completed
    case skipped
    case carriedOver

    var label: String {
        switch self {
        case .pending: return "待开始"
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        case .skipped: return "已跳过"
        case .carriedOver: return "已顺延"
        }
    }
}

/// 计划任务。保留来源与"实际完成范围"，为部分完成与后续复习提供依据。
///
/// 到期日期（`dueDate`，来自 `ReviewTask`）与安排日期（`scheduledDayKey` /
/// `scheduledStart`）是两个独立字段，任何一侧变化都不影响另一侧。
struct DailyPlanItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var planID: UUID
    var source: DailyPlanItemSource
    /// 展示标题。必须来自真实数据（任务名、课程名或用户输入）。
    var title: String
    /// 计划完成的完整范围。
    var plannedScope: StudyScope
    /// 减量后的保底范围；`nil` 表示这条任务不可减量。
    var minimumScope: StudyScope?
    var estimatedMinutes: Int
    /// 实际安排时间（与到期日期无关）。
    var scheduledStart: Date?
    var scheduledEnd: Date?
    /// 实际安排到哪个学习日。
    var scheduledDayKey: StudyDayKey
    /// 任务到期日期（复习任务才有）。
    var dueDate: Date?
    var status: DailyPlanItemStatus
    /// 完成档次缓存；权威来源是 `CompletionEvent`。
    var completionTier: PlanCompletionTier?
    /// 已完成范围缓存；权威来源是 `CompletionEvent`。
    var achievedScope: StudyScope?
    var completedAt: Date?
    /// 用户固定：重排/减量时不得移动或删除。
    var isPinned: Bool
    /// 是否允许拆分到多天。
    var isSplittable: Bool
    var carryOverCount: Int
    var note: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        planID: UUID,
        source: DailyPlanItemSource,
        title: String,
        plannedScope: StudyScope,
        minimumScope: StudyScope? = nil,
        estimatedMinutes: Int,
        scheduledStart: Date? = nil,
        scheduledEnd: Date? = nil,
        scheduledDayKey: StudyDayKey,
        dueDate: Date? = nil,
        status: DailyPlanItemStatus = .pending,
        completionTier: PlanCompletionTier? = nil,
        achievedScope: StudyScope? = nil,
        completedAt: Date? = nil,
        isPinned: Bool = false,
        isSplittable: Bool = false,
        carryOverCount: Int = 0,
        note: String = "",
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.planID = planID
        self.source = source
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.plannedScope = plannedScope
        self.minimumScope = minimumScope
        self.estimatedMinutes = max(0, estimatedMinutes)
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.scheduledDayKey = scheduledDayKey
        self.dueDate = dueDate
        self.status = status
        self.completionTier = completionTier
        self.achievedScope = achievedScope
        self.completedAt = completedAt
        self.isPinned = isPinned
        self.isSplittable = isSplittable
        self.carryOverCount = max(0, carryOverCount)
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 是否部分完成（相对 `plannedScope`）。无法比较时返回 `nil`。
    var isPartialCompletion: Bool? {
        guard let achievedScope else { return nil }
        return achievedScope.isPartial(relativeTo: plannedScope)
    }

    /// 是否整体完成。
    var isFullCompletion: Bool {
        guard let achievedScope, let ratio = achievedScope.completionRatio(relativeTo: plannedScope) else { return false }
        return ratio >= 1
    }

    /// 该任务是否"到期日与安排日不同"（用于界面提示与顺延统计）。
    var isScheduledAfterDueDate: Bool {
        guard let dueDate else { return false }
        return scheduledDayKey.localDateString > StudyDayKey(date: dueDate, timeZone: scheduledDayKey.timeZone).localDateString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        planID = try container.decodeIfPresent(UUID.self, forKey: .planID) ?? UUID()
        source = try container.decodeIfPresent(DailyPlanItemSource.self, forKey: .source)
            ?? DailyPlanItemSource(kind: .manual)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        plannedScope = try container.decodeIfPresent(StudyScope.self, forKey: .plannedScope) ?? .zero
        minimumScope = try container.decodeIfPresent(StudyScope.self, forKey: .minimumScope)
        estimatedMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes) ?? 0)
        scheduledStart = try container.decodeIfPresent(Date.self, forKey: .scheduledStart)
        scheduledEnd = try container.decodeIfPresent(Date.self, forKey: .scheduledEnd)
        scheduledDayKey = try container.decodeIfPresent(StudyDayKey.self, forKey: .scheduledDayKey)
            ?? StudyDayKey(date: StudyTimestamp.unspecified, timeZone: TimeZone.current)
        dueDate = try container.decodeIfPresent(Date.self, forKey: .dueDate)
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status) ?? DailyPlanItemStatus.pending.rawValue
        status = DailyPlanItemStatus(rawValue: rawStatus) ?? .pending
        completionTier = try container.decodeIfPresent(PlanCompletionTier.self, forKey: .completionTier)
        achievedScope = try container.decodeIfPresent(StudyScope.self, forKey: .achievedScope)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isSplittable = try container.decodeIfPresent(Bool.self, forKey: .isSplittable) ?? false
        carryOverCount = max(0, try container.decodeIfPresent(Int.self, forKey: .carryOverCount) ?? 0)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? StudyTimestamp.unspecified
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

// MARK: - 计划

enum DailyPlanMode: String, Codable, CaseIterable, Sendable {
    /// 按可用容量正常安排。
    case standard
    /// 自动减量后的计划。
    case reduced
    /// 保底计划（时间极少或未完成后的兜底）。
    case minimum
    /// 休息状态：剩余时间不足或已进入用户配置的睡眠时段，不安排新任务。
    case rest

    var label: String {
        switch self {
        case .standard: return "标准计划"
        case .reduced: return "轻量计划"
        case .minimum: return "保底计划"
        case .rest: return "休息"
        }
    }
}

enum DailyPlanStatus: String, Codable, CaseIterable, Sendable {
    case active
    case superseded
    case archived

    var label: String {
        switch self {
        case .active: return "生效中"
        case .superseded: return "已被新版本替换"
        case .archived: return "已归档"
        }
    }
}

/// 计划预算：容量从哪来、用了多少、还剩多少。
struct DailyPlanBudget: Codable, Hashable, Sendable {
    /// 当天可安排容量（来自 `AvailabilityCalculator`，已扣除课程/作息）。
    var capacityMinutes: Int
    /// 每日上限（来自偏好），`nil` 表示不设上限。
    var dailyCapMinutes: Int?
    /// 本计划实际安排的总分钟数。
    var plannedMinutes: Int

    init(capacityMinutes: Int, dailyCapMinutes: Int? = nil, plannedMinutes: Int = 0) {
        self.capacityMinutes = max(0, capacityMinutes)
        self.dailyCapMinutes = dailyCapMinutes.map { max(0, $0) }
        self.plannedMinutes = max(0, plannedMinutes)
    }

    /// 有效容量 = min(容量, 每日上限)。
    var effectiveCapacityMinutes: Int {
        guard let dailyCapMinutes else { return capacityMinutes }
        return min(capacityMinutes, dailyCapMinutes)
    }

    var remainingMinutes: Int { max(0, effectiveCapacityMinutes - plannedMinutes) }

    var isOversubscribed: Bool { plannedMinutes > effectiveCapacityMinutes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capacity = try container.decodeIfPresent(Int.self, forKey: .capacityMinutes) ?? 0
        let cap = try container.decodeIfPresent(Int.self, forKey: .dailyCapMinutes)
        let planned = try container.decodeIfPresent(Int.self, forKey: .plannedMinutes) ?? 0
        self.init(capacityMinutes: capacity, dailyCapMinutes: cap, plannedMinutes: planned)
    }
}

struct DailyPlanGoal: Codable, Hashable, Sendable {
    var targetMinutes: Int
    var targetScope: StudyScope?
    /// 计划目标说明（只描述安排策略，不编造学习内容）。
    var label: String
    var isUserEdited: Bool

    init(targetMinutes: Int = 0, targetScope: StudyScope? = nil, label: String = "", isUserEdited: Bool = false) {
        self.targetMinutes = max(0, targetMinutes)
        self.targetScope = targetScope
        self.label = label
        self.isUserEdited = isUserEdited
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .targetMinutes) ?? 0)
        targetScope = try container.decodeIfPresent(StudyScope.self, forKey: .targetScope)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        isUserEdited = try container.decodeIfPresent(Bool.self, forKey: .isUserEdited) ?? false
    }
}

/// 计划解释：说清"为什么这么排"，包括假设与受阻原因。
struct DailyPlanExplanation: Codable, Hashable, Sendable {
    var lines: [String]
    var assumptions: [String]
    var blockedReasons: [String]

    init(lines: [String] = [], assumptions: [String] = [], blockedReasons: [String] = []) {
        self.lines = lines
        self.assumptions = assumptions
        self.blockedReasons = blockedReasons
    }

    var isEmpty: Bool { lines.isEmpty && assumptions.isEmpty && blockedReasons.isEmpty }

    var summaryText: String {
        (lines + assumptions + blockedReasons).joined(separator: "\n")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decodeIfPresent([String].self, forKey: .lines) ?? []
        assumptions = try container.decodeIfPresent([String].self, forKey: .assumptions) ?? []
        blockedReasons = try container.decodeIfPresent([String].self, forKey: .blockedReasons) ?? []
    }
}

/// 无法安排的任务及原因。
enum UnplaceableReason: String, Codable, CaseIterable, Sendable {
    case insufficientCapacity
    case pinnedConflict
    case minimumScopeTooLarge
    case notSplittable
    case missingSourceData

    var label: String {
        switch self {
        case .insufficientCapacity: return "当天容量不足"
        case .pinnedConflict: return "与固定任务冲突"
        case .minimumScopeTooLarge: return "保底范围也放不下"
        case .notSplittable: return "不可拆分且剩余时间不足"
        case .missingSourceData: return "缺少来源数据"
        }
    }
}

struct UnplaceablePlanItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var source: DailyPlanItemSource
    var title: String
    var plannedScope: StudyScope
    var estimatedMinutes: Int
    var reason: UnplaceableReason
    var detail: String

    init(
        id: UUID = UUID(),
        source: DailyPlanItemSource,
        title: String,
        plannedScope: StudyScope,
        estimatedMinutes: Int,
        reason: UnplaceableReason,
        detail: String = ""
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.plannedScope = plannedScope
        self.estimatedMinutes = max(0, estimatedMinutes)
        self.reason = reason
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try container.decodeIfPresent(DailyPlanItemSource.self, forKey: .source)
            ?? DailyPlanItemSource(kind: .manual)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        plannedScope = try container.decodeIfPresent(StudyScope.self, forKey: .plannedScope) ?? .zero
        estimatedMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes) ?? 0)
        let rawReason = try container.decodeIfPresent(String.self, forKey: .reason)
            ?? UnplaceableReason.insufficientCapacity.rawValue
        reason = UnplaceableReason(rawValue: rawReason) ?? .insufficientCapacity
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

/// 今日计划。一个学习日可以有多个版本，只有一个是 `active`。
struct DailyStudyPlan: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var dayKey: StudyDayKey
    /// 同一学习日内的版本号，从 1 递增。
    var version: Int
    var mode: DailyPlanMode
    var status: DailyPlanStatus
    var budget: DailyPlanBudget
    var goal: DailyPlanGoal
    var explanation: DailyPlanExplanation
    var items: [DailyPlanItem]
    var unplaceable: [UnplaceablePlanItem]
    /// 输入指纹：计划生成时的输入摘要。指纹相同表示"重复生成，无需重建"。
    var inputFingerprint: String
    var supersedesPlanID: UUID?
    /// 这个版本是否由一次可撤销的减量操作产生。
    var isUndoableReduction: Bool
    /// 本次减量之前应恢复到的明确版本；独立于仅用于审计的 `supersedesPlanID`。
    /// 旧数据没有此字段时不猜测恢复目标，因此不能撤销。
    var reductionUndoTargetPlanID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        dayKey: StudyDayKey,
        version: Int = 1,
        mode: DailyPlanMode = .standard,
        status: DailyPlanStatus = .active,
        budget: DailyPlanBudget,
        goal: DailyPlanGoal = DailyPlanGoal(),
        explanation: DailyPlanExplanation = DailyPlanExplanation(),
        items: [DailyPlanItem] = [],
        unplaceable: [UnplaceablePlanItem] = [],
        inputFingerprint: String = "",
        supersedesPlanID: UUID? = nil,
        isUndoableReduction: Bool = false,
        reductionUndoTargetPlanID: UUID? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.dayKey = dayKey
        self.version = max(1, version)
        self.mode = mode
        self.status = status
        self.budget = budget
        self.goal = goal
        self.explanation = explanation
        self.items = items
        self.unplaceable = unplaceable
        self.inputFingerprint = inputFingerprint
        self.supersedesPlanID = supersedesPlanID
        self.isUndoableReduction = isUndoableReduction
        self.reductionUndoTargetPlanID = reductionUndoTargetPlanID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isActive: Bool { status == .active }

    var pendingItems: [DailyPlanItem] { items.filter { $0.status == .pending || $0.status == .inProgress } }

    var plannedMinutesFromItems: Int { items.reduce(0) { $0 + $1.estimatedMinutes } }

    func item(id: UUID) -> DailyPlanItem? { items.first { $0.id == id } }

    /// 同一输入指纹 → 重复生成，调用方应当直接复用本计划而不是新建版本。
    func hasSameInput(as fingerprint: String) -> Bool {
        !inputFingerprint.isEmpty && inputFingerprint == fingerprint
    }

    /// 生成新版本：旧版本置为 `superseded`，新版本 `version + 1`。
    func supersededCopy(now: Date) -> DailyStudyPlan {
        var copy = self
        copy.status = .superseded
        copy.updatedAt = now
        return copy
    }

    /// 按完成事件重算计划项状态（完成事件是唯一权威来源）。
    ///
    /// 该函数是纯函数且幂等：同一批事件重算多次结果一致；
    /// 没有事件的任务不会被"推算"成已完成。
    func recomputingItemStates(from events: [CompletionEvent]) -> DailyStudyPlan {
        var copy = self
        copy.items = items.map { item in
            let related = events.filter { !$0.isRevoked && $0.planItemID == item.id }
            var updated = item
            guard !related.isEmpty else {
                updated.achievedScope = nil
                updated.completionTier = nil
                updated.completedAt = nil
                if updated.status == .completed || updated.status == .inProgress {
                    updated.status = .pending
                }
                return updated
            }
            let achieved = related.reduce(StudyScope(unit: item.plannedScope.unit, amount: 0, customUnitLabel: item.plannedScope.customUnitLabel)) { partial, event in
                guard partial.isComparable(to: event.completedScope) else { return partial }
                return StudyScope(unit: partial.unit, amount: partial.amount + event.completedScope.amount, customUnitLabel: partial.customUnitLabel)
            }
            let tier = PlanCompletionTier.resolve(completed: achieved, planned: item.plannedScope, minimum: item.minimumScope)
            updated.achievedScope = achieved
            updated.completionTier = tier
            updated.completedAt = related.map(\.completedAt).max()
            // 档次决定生命周期状态；量纲不可比（tier == nil）时保持"进行中"，
            // 绝不因为"有记录"就标成已完成。
            switch tier {
            case .standard, .minimum:
                updated.status = .completed
            case .studied, .none:
                updated.status = .inProgress
            }
            return updated
        }
        return copy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dayKey = try container.decodeIfPresent(StudyDayKey.self, forKey: .dayKey)
            ?? StudyDayKey(date: StudyTimestamp.unspecified, timeZone: TimeZone.current)
        version = max(1, try container.decodeIfPresent(Int.self, forKey: .version) ?? 1)
        let rawMode = try container.decodeIfPresent(String.self, forKey: .mode) ?? DailyPlanMode.standard.rawValue
        mode = DailyPlanMode(rawValue: rawMode) ?? .standard
        let rawStatus = try container.decodeIfPresent(String.self, forKey: .status) ?? DailyPlanStatus.active.rawValue
        status = DailyPlanStatus(rawValue: rawStatus) ?? .active
        budget = try container.decodeIfPresent(DailyPlanBudget.self, forKey: .budget)
            ?? DailyPlanBudget(capacityMinutes: 0)
        goal = try container.decodeIfPresent(DailyPlanGoal.self, forKey: .goal) ?? DailyPlanGoal()
        explanation = try container.decodeIfPresent(DailyPlanExplanation.self, forKey: .explanation) ?? DailyPlanExplanation()
        items = try container.decodeIfPresent([DailyPlanItem].self, forKey: .items) ?? []
        unplaceable = try container.decodeIfPresent([UnplaceablePlanItem].self, forKey: .unplaceable) ?? []
        inputFingerprint = try container.decodeIfPresent(String.self, forKey: .inputFingerprint) ?? ""
        supersedesPlanID = try container.decodeIfPresent(UUID.self, forKey: .supersedesPlanID)
        isUndoableReduction = try container.decodeIfPresent(Bool.self, forKey: .isUndoableReduction) ?? false
        reductionUndoTargetPlanID = try container.decodeIfPresent(UUID.self, forKey: .reductionUndoTargetPlanID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? StudyTimestamp.unspecified
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

// MARK: - 计划项校验（不编造内容）

enum DailyPlanValidationIssue: String, Codable, CaseIterable, Sendable {
    case emptyTitle
    case missingCourseReference
    case missingReviewReference
    case missingUserInput
    case nonPositiveScope
    case negativeMinutes

    var message: String {
        switch self {
        case .emptyTitle: return "任务标题为空，无法展示。"
        case .missingCourseReference: return "课程回顾/预习任务缺少课程或课程实例关联。"
        case .missingReviewReference: return "复习任务缺少关联的复习任务 ID。"
        case .missingUserInput: return "手动任务缺少用户输入内容。"
        case .nonPositiveScope: return "任务范围必须大于 0。"
        case .negativeMinutes: return "预计分钟数不能为负。"
        }
    }
}

enum DailyPlanValidation {
    /// 校验单条计划项。返回空数组表示通过。
    static func issues(for item: DailyPlanItem) -> [DailyPlanValidationIssue] {
        var issues: [DailyPlanValidationIssue] = []
        if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyTitle)
        }
        if item.plannedScope.isZero {
            issues.append(.nonPositiveScope)
        }
        if item.estimatedMinutes < 0 {
            issues.append(.negativeMinutes)
        }
        switch item.source.kind {
        case .reviewTask:
            if item.source.reviewTaskID == nil { issues.append(.missingReviewReference) }
        case .courseReview, .preview:
            if item.source.courseID == nil && item.source.occurrenceID == nil {
                issues.append(.missingCourseReference)
            }
        case .manual:
            let note = (item.source.manualNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if note.isEmpty && item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.missingUserInput)
            }
        }
        return issues
    }

    /// 校验整份计划。
    static func issues(for plan: DailyStudyPlan) -> [DailyPlanValidationIssue] {
        plan.items.flatMap { issues(for: $0) }
    }
}

// MARK: - 每日学习汇总（统一状态来源）

enum DailySummarySource: String, Codable, Sendable {
    /// 有真实完成事件。
    case recordedEvents
    /// 只有旧版本的"每日完成总数"。
    case legacyAggregate
    /// 没有任何记录。
    case none

    var label: String {
        switch self {
        case .recordedEvents: return "完成事件"
        case .legacyAggregate: return "旧版本每日总数"
        case .none: return "无记录"
        }
    }
}

/// 每日学习汇总。
///
/// 旧数据只有"每日完成总数"，因此：
/// - `legacyCompletedTaskCount` 原样保留；
/// - `recordedMinutes` 为 `nil`（未知，绝不从任务数推算时长）；
/// - `isEntertainmentEligible` 为 `nil`（无法判定，不补发娱乐资格）。
struct DailyStudySummary: Hashable, Sendable {
    var dayKey: StudyDayKey
    var source: DailySummarySource
    var standardCompletedItemCount: Int
    var minimumCompletedItemCount: Int
    var studiedItemCount: Int
    var recordedMinutes: Int?
    /// 当天"记为完成但没有记录时长"的项数。这些项不计入 `recordedMinutes`。
    var unrecordedDurationItemCount: Int
    var legacyCompletedTaskCount: Int?
    var isEntertainmentEligible: Bool?
    var planID: UUID?
    var planMode: DailyPlanMode?
    var explanation: String

    init(
        dayKey: StudyDayKey,
        source: DailySummarySource,
        standardCompletedItemCount: Int = 0,
        minimumCompletedItemCount: Int = 0,
        studiedItemCount: Int = 0,
        recordedMinutes: Int? = nil,
        unrecordedDurationItemCount: Int = 0,
        legacyCompletedTaskCount: Int? = nil,
        isEntertainmentEligible: Bool? = nil,
        planID: UUID? = nil,
        planMode: DailyPlanMode? = nil,
        explanation: String = ""
    ) {
        self.dayKey = dayKey
        self.source = source
        self.standardCompletedItemCount = max(0, standardCompletedItemCount)
        self.minimumCompletedItemCount = max(0, minimumCompletedItemCount)
        self.studiedItemCount = max(0, studiedItemCount)
        self.recordedMinutes = recordedMinutes
        self.unrecordedDurationItemCount = max(0, unrecordedDurationItemCount)
        self.legacyCompletedTaskCount = legacyCompletedTaskCount
        self.isEntertainmentEligible = isEntertainmentEligible
        self.planID = planID
        self.planMode = planMode
        self.explanation = explanation
    }

    /// 标准完成 + 保底完成的任务数。
    var completedItemCount: Int { standardCompletedItemCount + minimumCompletedItemCount }
}
