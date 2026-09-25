import Foundation

// MARK: - ScheduleResolver
//
// 课表解析与时间占用计算（纯计算，无 UI、无网络、无全局状态）。
//
// 设计约束（来自本轮公共开发约束）：
// - 算法不直接使用 `Date()`：所有时间入口都要求调用方传入 `now` / `Calendar` / 时区。
// - 学校课表按“学期时区”展开，系统时区变化不能让星期错位。
// - 只读取传入的快照式数据，绝不写入任何存储。
// - 课程只表示“占用与学习背景”，本文件不会生成任何学习完成事件。
//
// 本文件同时给出 G 需要接入的持久化契约（见文件末尾 `SchedulePersistenceKeys`）。

// MARK: - Time primitives

/// 一周中的某一天。`rawValue` 采用 ISO-8601 约定：周一 = 1 … 周日 = 7。
///
/// 刻意不使用 `Calendar.current.firstWeekday`，因为那会随系统区域变化，
/// 从而让“周一 08:00 的课”在别的时区/区域下解析成别的星期。
enum ScheduleWeekday: Int, Codable, CaseIterable, Identifiable, Comparable, Sendable {
    case monday = 1
    case tuesday = 2
    case wednesday = 3
    case thursday = 4
    case friday = 5
    case saturday = 6
    case sunday = 7

    var id: Int { rawValue }

    static func < (lhs: ScheduleWeekday, rhs: ScheduleWeekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 从 `Calendar` 的 `.weekday` 分量（周日 = 1 … 周六 = 7）转换。
    init?(calendarWeekday: Int) {
        switch calendarWeekday {
        case 1: self = .sunday
        case 2: self = .monday
        case 3: self = .tuesday
        case 4: self = .wednesday
        case 5: self = .thursday
        case 6: self = .friday
        case 7: self = .saturday
        default: return nil
        }
    }

    /// 本模块统一使用的 ISO 约定（周一为 1）的数值。
    var isoWeekdayNumber: Int { rawValue }

    var isWeekend: Bool { self == .saturday || self == .sunday }

    var shortLabel: String {
        switch self {
        case .monday: return "周一"
        case .tuesday: return "周二"
        case .wednesday: return "周三"
        case .thursday: return "周四"
        case .friday: return "周五"
        case .saturday: return "周六"
        case .sunday: return "周日"
        }
    }

    var fullLabel: String {
        switch self {
        case .monday: return "星期一"
        case .tuesday: return "星期二"
        case .wednesday: return "星期三"
        case .thursday: return "星期四"
        case .friday: return "星期五"
        case .saturday: return "星期六"
        case .sunday: return "星期日"
        }
    }

    /// 为 `DatePicker` / `Picker` 提供稳定顺序（周一在前）。
    static let ordered: [ScheduleWeekday] = [
        .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday
    ]
}

/// 一天内的本地时刻（无日期、无时区），以“从零点起的分钟数”存储。
///
/// 用分钟数而不是 `Date`，是为了让“学期时区下的 08:00”可以被稳定表达和比较，
/// 不受设备时区或夏令时切换影响。
struct TimeOfDay: Codable, Hashable, Comparable, Sendable {
    /// 0...1439；越大表示越晚。
    var minutes: Int

    init(minutes: Int) {
        self.minutes = min(max(minutes, 0), 24 * 60 - 1)
    }

    init(hour: Int, minute: Int) {
        self.init(minutes: hour * 60 + minute)
    }

    init(clampingHour hour: Int, minute: Int) {
        self.minutes = min(max(hour, 0), 23) * 60 + min(max(minute, 0), 59)
    }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutes < rhs.minutes
    }

    var hour: Int { minutes / 60 }
    var minute: Int { minutes % 60 }

    /// `"08:05"` 形式，始终两位补零，便于测试断言与表单回填。
    var displayText: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// `"8:05"` 形式，用于“8:05–8:45”这类紧凑摘要。
    var compactText: String {
        String(format: "%d:%02d", hour, minute)
    }

    /// 例：`"08:00–08:45"`。
    static func rangeText(_ start: TimeOfDay, _ end: TimeOfDay) -> String {
        "\(start.displayText)–\(end.displayText)"
    }

    /// 从 `Date` 在该日历下的时/分构造。用于把课程锚点日期转成时刻。
    init(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    /// 把时刻落到指定日期上（使用传入日历/时区）。
    func date(on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}

/// 某个星期几上的一段时段；`endDayOffset > 0` 表示跨到次日（例如 23:00–07:00 的睡眠）。
struct DayTimeRange: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var weekday: ScheduleWeekday
    var start: TimeOfDay
    var end: TimeOfDay
    /// 0 = 当天结束；1 = 次日结束。用于跨午夜区间。
    var endDayOffset: Int

    init(
        id: UUID = UUID(),
        weekday: ScheduleWeekday,
        start: TimeOfDay,
        end: TimeOfDay,
        endDayOffset: Int = 0
    ) {
        self.id = id
        self.weekday = weekday
        self.start = start
        self.end = end
        self.endDayOffset = max(0, endDayOffset)
    }

    var displayText: String { TimeOfDay.rangeText(start, end) }

    /// 区间在该星期几上的“分钟长度”。跨午夜时自动加上 24 小时。
    var durationMinutes: Int {
        let raw = (end.minutes + endDayOffset * 24 * 60) - start.minutes
        return max(0, raw)
    }

    /// 同一星期几内的有效区间：结束必须晚于开始（允许跨午夜）。
    var isValid: Bool {
        (end.minutes + endDayOffset * 24 * 60) > start.minutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        weekday = try container.decodeIfPresent(ScheduleWeekday.self, forKey: .weekday) ?? .monday
        start = try container.decodeIfPresent(TimeOfDay.self, forKey: .start) ?? TimeOfDay(hour: 8, minute: 0)
        end = try container.decodeIfPresent(TimeOfDay.self, forKey: .end) ?? TimeOfDay(hour: 8, minute: 45)
        endDayOffset = max(0, try container.decodeIfPresent(Int.self, forKey: .endDayOffset) ?? 0)
    }
}

// `TimeOfDay` 需要容忍手写/旧 JSON 里的 `{"minutes": 480}` 以及越界值。
extension TimeOfDay {
    private enum CodingKeys: String, CodingKey {
        case minutes
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let raw = try? container.decode(Int.self) {
            self.init(minutes: raw)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(minutes: try container.decodeIfPresent(Int.self, forKey: .minutes) ?? 0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(minutes)
    }
}

// MARK: - 节次模板

/// 节次模板项，例如“第一节 08:00–08:45”。
/// 只描述“模板”，不会自动占用时间：只有课程引用它时才会产生占用。
struct PeriodTemplate: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var start: TimeOfDay
    var end: TimeOfDay
    /// 在编辑器里用于排序；允许用户自定义节次顺序。
    var order: Int

    init(
        id: UUID = UUID(),
        name: String,
        start: TimeOfDay,
        end: TimeOfDay,
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
        self.order = order
    }

    var displayText: String { "\(name) \(TimeOfDay.rangeText(start, end))" }

    var durationMinutes: Int { max(0, end.minutes - start.minutes) }

    var isValid: Bool { end.minutes > start.minutes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "自定义节次"
        start = try container.decodeIfPresent(TimeOfDay.self, forKey: .start) ?? TimeOfDay(hour: 8, minute: 0)
        end = try container.decodeIfPresent(TimeOfDay.self, forKey: .end) ?? TimeOfDay(hour: 8, minute: 45)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }

    /// 内置节次模板：仅在用户没有自定义时作为初始值，不写入任何偏好。
    static var defaultTemplates: [PeriodTemplate] {
        [
            PeriodTemplate(name: "第一节", start: TimeOfDay(hour: 8, minute: 0), end: TimeOfDay(hour: 8, minute: 45), order: 0),
            PeriodTemplate(name: "第二节", start: TimeOfDay(hour: 8, minute: 55), end: TimeOfDay(hour: 9, minute: 40), order: 1),
            PeriodTemplate(name: "第三节", start: TimeOfDay(hour: 10, minute: 0), end: TimeOfDay(hour: 10, minute: 45), order: 2),
            PeriodTemplate(name: "第四节", start: TimeOfDay(hour: 10, minute: 55), end: TimeOfDay(hour: 11, minute: 40), order: 3),
            PeriodTemplate(name: "第五节", start: TimeOfDay(hour: 14, minute: 0), end: TimeOfDay(hour: 14, minute: 45), order: 4),
            PeriodTemplate(name: "第六节", start: TimeOfDay(hour: 14, minute: 55), end: TimeOfDay(hour: 15, minute: 40), order: 5),
            PeriodTemplate(name: "第七节", start: TimeOfDay(hour: 16, minute: 0), end: TimeOfDay(hour: 16, minute: 45), order: 6),
            PeriodTemplate(name: "第八节", start: TimeOfDay(hour: 16, minute: 55), end: TimeOfDay(hour: 17, minute: 40), order: 7),
            PeriodTemplate(name: "第九节", start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 19, minute: 45), order: 8),
            PeriodTemplate(name: "第十节", start: TimeOfDay(hour: 19, minute: 55), end: TimeOfDay(hour: 20, minute: 40), order: 9)
        ]
    }
}

// MARK: - 科目与课程

/// 科目的稳定关联。
///
/// 不依赖显示名称：`id` 是唯一身份，`displayName` 只是快照。
/// `linkedKnowledgeSubject` 是给 G 预留的桥接字段——当课程需要和既有
/// `KnowledgePoint.subject`（自由文本）对齐时填入，避免改名后失联。
struct SubjectRef: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var displayName: String
    var linkedKnowledgeSubject: String?

    init(id: UUID = UUID(), displayName: String, linkedKnowledgeSubject: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.linkedKnowledgeSubject = linkedKnowledgeSubject
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "未命名科目"
        linkedKnowledgeSubject = try container.decodeIfPresent(String.self, forKey: .linkedKnowledgeSubject)
    }
}

/// 重复规则的周次类型。
enum CourseWeekParity: String, Codable, CaseIterable, Identifiable, Sendable {
    case every
    case odd
    case even
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .every: return "每周"
        case .odd: return "单周"
        case .even: return "双周"
        case .custom: return "指定周次"
        }
    }

    /// 该规则是否与某个学期周次匹配。`week` 为 1 起的学期周次。
    func matches(week: Int) -> Bool {
        guard week >= 1 else { return false }
        switch self {
        case .every: return true
        case .odd: return week % 2 == 1
        case .even: return week % 2 == 0
        case .custom: return true // 具体周次由 `Course.weeks` 决定
        }
    }
}

/// 课程重复规则。
struct CourseRecurrence: Codable, Hashable, Sendable {
    var parity: CourseWeekParity
    /// 仅当 `parity == .custom` 时生效；保存前应去重并升序排序。
    var weeks: [Int]
    /// 覆盖学期总周数（例如只上前 8 周）。`nil` 表示跟随学期总周数。
    var lastWeek: Int?

    init(parity: CourseWeekParity = .every, weeks: [Int] = [], lastWeek: Int? = nil) {
        self.parity = parity
        self.weeks = weeks
        self.lastWeek = lastWeek
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parity = try container.decodeIfPresent(CourseWeekParity.self, forKey: .parity) ?? .every
        weeks = try container.decodeIfPresent([Int].self, forKey: .weeks) ?? []
        lastWeek = try container.decodeIfPresent(Int.self, forKey: .lastWeek)
    }
}

/// 一门重复课程（学期级定义，不是某一天的实例）。
struct Course: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// 稳定科目关联；不靠名称匹配。
    var subject: SubjectRef
    var weekday: ScheduleWeekday
    var startTime: TimeOfDay
    var endTime: TimeOfDay
    /// 1 = 当天结束；2 = 次日结束。用于允许跨午夜课程。
    var endDayOffset: Int
    var location: String
    var teacher: String
    var recurrence: CourseRecurrence
    /// 使用的节次模板；只作为来源标注，展示与校验用。
    var periodTemplateID: UUID?
    var periodTemplateName: String?
    var note: String
    var isArchived: Bool

    init(
        id: UUID = UUID(),
        name: String,
        subject: SubjectRef,
        weekday: ScheduleWeekday = .monday,
        startTime: TimeOfDay = TimeOfDay(hour: 8, minute: 0),
        endTime: TimeOfDay = TimeOfDay(hour: 8, minute: 45),
        endDayOffset: Int = 0,
        location: String = "",
        teacher: String = "",
        recurrence: CourseRecurrence = CourseRecurrence(),
        periodTemplateID: UUID? = nil,
        periodTemplateName: String? = nil,
        note: String = "",
        isArchived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.subject = subject
        self.weekday = weekday
        self.startTime = startTime
        self.endTime = endTime
        self.endDayOffset = max(0, endDayOffset)
        self.location = location
        self.teacher = teacher
        self.recurrence = recurrence
        self.periodTemplateID = periodTemplateID
        self.periodTemplateName = periodTemplateName
        self.note = note
        self.isArchived = isArchived
    }

    /// 课程时长（分钟）。跨午夜时自动跨天累加。
    var durationMinutes: Int {
        (endTime.minutes + endDayOffset * 24 * 60) - startTime.minutes
    }

    var isOvernight: Bool { endDayOffset > 0 || endTime.minutes <= startTime.minutes }

    var timeText: String {
        if endDayOffset > 0 {
            return "\(startTime.displayText)–次日 \(endTime.displayText)"
        }
        return TimeOfDay.rangeText(startTime, endTime)
    }

    var subjectName: String {
        let trimmed = subject.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名科目" : trimmed
    }

    /// 例：`"周一 08:00–08:45 · 每周"`。
    var summaryLine: String {
        "\(weekday.shortLabel) \(timeText) · \(recurrence.parity.label)"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名课程"
        subject = try container.decodeIfPresent(SubjectRef.self, forKey: .subject)
            ?? SubjectRef(displayName: "未命名科目")
        weekday = try container.decodeIfPresent(ScheduleWeekday.self, forKey: .weekday) ?? .monday
        startTime = try container.decodeIfPresent(TimeOfDay.self, forKey: .startTime) ?? TimeOfDay(hour: 8, minute: 0)
        endTime = try container.decodeIfPresent(TimeOfDay.self, forKey: .endTime) ?? TimeOfDay(hour: 8, minute: 45)
        endDayOffset = max(0, try container.decodeIfPresent(Int.self, forKey: .endDayOffset) ?? 0)
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        teacher = try container.decodeIfPresent(String.self, forKey: .teacher) ?? ""
        recurrence = try container.decodeIfPresent(CourseRecurrence.self, forKey: .recurrence) ?? CourseRecurrence()
        periodTemplateID = try container.decodeIfPresent(UUID.self, forKey: .periodTemplateID)
        periodTemplateName = try container.decodeIfPresent(String.self, forKey: .periodTemplateName)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
}

// MARK: - 学期

/// 学期配置：第一周起点 + 总周数 + 学期时区。
struct ScheduleSemester: Codable, Hashable, Sendable {
    /// 第一周的起点（周一）在该学期时区下的零点。
    var firstWeekStart: Date
    var weekCount: Int
    /// 学期时区标识，例如 `"Asia/Shanghai"`。
    var timeZoneIdentifier: String

    init(firstWeekStart: Date, weekCount: Int, timeZoneIdentifier: String) {
        self.firstWeekStart = firstWeekStart
        self.weekCount = max(1, weekCount)
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        firstWeekStart = try container.decodeIfPresent(Date.self, forKey: .firstWeekStart) ?? Date(timeIntervalSince1970: 0)
        weekCount = max(1, try container.decodeIfPresent(Int.self, forKey: .weekCount) ?? 20)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? TimeZone.current.identifier
    }

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current
    }

    /// 学期时区下的日历。所有周次计算都必须走这里。
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }

    var lastWeek: Int { max(1, weekCount) }

    /// `date` 落在第几个学期周（1 起）。早于第一周返回 `<= 0`，晚于总周数返回 `> weekCount`。
    func weekIndex(for date: Date) -> Int {
        let calendar = self.calendar
        let start = calendar.startOfDay(for: firstWeekStart)
        let target = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        return Int(floor(Double(days) / 7.0)) + 1
    }

    func contains(date: Date) -> Bool {
        let week = weekIndex(for: date)
        return (1...lastWeek).contains(week)
    }

    /// 把 (week, weekday) 解析成该学期时区下的具体日期。
    func date(week: Int, weekday: ScheduleWeekday, calendar: Calendar) -> Date? {
        var calendar = calendar
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: firstWeekStart)
        let offsetDays = (week - 1) * 7 + (weekday.isoWeekdayNumber - 1)
        guard let day = calendar.date(byAdding: .day, value: offsetDays, to: start) else { return nil }
        return calendar.startOfDay(for: day)
    }

    /// 学期起止（含最后一周最后一天）。
    var dateInterval: DateInterval {
        let calendar = self.calendar
        let start = calendar.startOfDay(for: firstWeekStart)
        let end = calendar.date(byAdding: .day, value: lastWeek * 7, to: start) ?? start
        return DateInterval(start: start, end: end)
    }
}

// MARK: - 一次性例外

enum ScheduleExceptionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 停课：该次不占用时间。
    case cancellation
    /// 换课：同一天改时间或改地点。
    case relocation
    /// 补课：在额外日期增加一次占用。
    case makeup

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cancellation: return "停课"
        case .relocation: return "换课"
        case .makeup: return "补课"
        }
    }
}

/// 一次性例外。日期按“学期时区当天”存储，避免跨时区漂移。
struct ScheduleException: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: ScheduleExceptionKind
    var courseID: UUID
    /// 例外生效的日期（该日期在学期时区下的全天）。
    var date: Date
    var replacementStart: TimeOfDay?
    var replacementEnd: TimeOfDay?
    var replacementLocation: String?
    var note: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: ScheduleExceptionKind,
        courseID: UUID,
        date: Date,
        replacementStart: TimeOfDay? = nil,
        replacementEnd: TimeOfDay? = nil,
        replacementLocation: String? = nil,
        note: String = "",
        createdAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.kind = kind
        self.courseID = courseID
        self.date = date
        self.replacementStart = replacementStart
        self.replacementEnd = replacementEnd
        self.replacementLocation = replacementLocation
        self.note = note
        self.createdAt = createdAt
    }

    var summaryLine: String {
        switch kind {
        case .cancellation:
            return "停课"
        case .relocation:
            if let start = replacementStart, let end = replacementEnd {
                return "换课 \(TimeOfDay.rangeText(start, end))"
            }
            if let location = replacementLocation, !location.isEmpty {
                return "换教室 \(location)"
            }
            return "换课"
        case .makeup:
            if let start = replacementStart, let end = replacementEnd {
                return "补课 \(TimeOfDay.rangeText(start, end))"
            }
            return "补课"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(ScheduleExceptionKind.self, forKey: .kind) ?? .cancellation
        courseID = try container.decodeIfPresent(UUID.self, forKey: .courseID) ?? UUID()
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? Date(timeIntervalSince1970: 0)
        replacementStart = try container.decodeIfPresent(TimeOfDay.self, forKey: .replacementStart)
        replacementEnd = try container.decodeIfPresent(TimeOfDay.self, forKey: .replacementEnd)
        replacementLocation = try container.decodeIfPresent(String.self, forKey: .replacementLocation)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }
}

// MARK: - 课表快照与编辑草稿

/// 课表快照：G 从存储读出来后传给算法/页面的唯一输入。
/// 页面永远不修改它，只产出 `CourseDraft` / `ScheduleExceptionDraft` / `AvailabilitySettings`。
struct ScheduleSnapshot: Codable, Hashable, Sendable {
    var semester: ScheduleSemester
    var courses: [Course]
    var exceptions: [ScheduleException]
    var periodTemplates: [PeriodTemplate]

    init(
        semester: ScheduleSemester,
        courses: [Course] = [],
        exceptions: [ScheduleException] = [],
        periodTemplates: [PeriodTemplate] = PeriodTemplate.defaultTemplates
    ) {
        self.semester = semester
        self.courses = courses
        self.exceptions = exceptions
        self.periodTemplates = periodTemplates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        semester = try container.decodeIfPresent(ScheduleSemester.self, forKey: .semester) ?? ScheduleSemester.fallback
        courses = try container.decodeIfPresent([Course].self, forKey: .courses) ?? []
        exceptions = try container.decodeIfPresent([ScheduleException].self, forKey: .exceptions) ?? []
        periodTemplates = try container.decodeIfPresent([PeriodTemplate].self, forKey: .periodTemplates)
            ?? PeriodTemplate.defaultTemplates
    }

    var activeCourses: [Course] { courses.filter { !$0.isArchived } }

    func course(id: UUID) -> Course? { courses.first { $0.id == id } }

    func exceptions(for courseID: UUID) -> [ScheduleException] {
        exceptions.filter { $0.courseID == courseID }
    }

    /// 没有课时仍可用于计算空闲时间（无课表 ≠ 无作息）。
    var isEmpty: Bool { activeCourses.isEmpty && exceptions.isEmpty }
}

extension ScheduleSemester {
    /// 兜底学期：仅用于“用户还没设置学期”时不崩溃。
    /// 页面必须显式提示“尚未设置学期”，不能把它当作真实学年。
    static var fallback: ScheduleSemester {
        ScheduleSemester(
            firstWeekStart: Date(timeIntervalSince1970: 0),
            weekCount: 20,
            timeZoneIdentifier: TimeZone.current.identifier
        )
    }
}

/// 课程编辑草稿：表单唯一可写的对象，保存前不触碰正式数据。
struct CourseDraft: Identifiable, Hashable, Sendable {
    var id: UUID
    /// 正在被编辑的既有课程；`nil` 表示新建。
    var editingCourseID: UUID?
    var name: String
    var subject: SubjectRef
    var weekday: ScheduleWeekday
    var startTime: TimeOfDay
    var endTime: TimeOfDay
    var endDayOffset: Int
    var location: String
    var teacher: String
    var parity: CourseWeekParity
    var customWeeks: [Int]
    var lastWeek: Int?
    var periodTemplateID: UUID?
    var note: String

    init(
        id: UUID = UUID(),
        editingCourseID: UUID? = nil,
        name: String = "",
        subject: SubjectRef,
        weekday: ScheduleWeekday = .monday,
        startTime: TimeOfDay = TimeOfDay(hour: 8, minute: 0),
        endTime: TimeOfDay = TimeOfDay(hour: 8, minute: 45),
        endDayOffset: Int = 0,
        location: String = "",
        teacher: String = "",
        parity: CourseWeekParity = .every,
        customWeeks: [Int] = [],
        lastWeek: Int? = nil,
        periodTemplateID: UUID? = nil,
        note: String = ""
    ) {
        self.id = id
        self.editingCourseID = editingCourseID
        self.name = name
        self.subject = subject
        self.weekday = weekday
        self.startTime = startTime
        self.endTime = endTime
        self.endDayOffset = max(0, endDayOffset)
        self.location = location
        self.teacher = teacher
        self.parity = parity
        self.customWeeks = customWeeks
        self.lastWeek = lastWeek
        self.periodTemplateID = periodTemplateID
        self.note = note
    }

    /// 从既有课程构造草稿（用于“编辑”）。
    init(course: Course) {
        self.init(
            id: course.id,
            editingCourseID: course.id,
            name: course.name,
            subject: course.subject,
            weekday: course.weekday,
            startTime: course.startTime,
            endTime: course.endTime,
            endDayOffset: course.endDayOffset,
            location: course.location,
            teacher: course.teacher,
            parity: course.recurrence.parity,
            customWeeks: course.recurrence.weeks,
            lastWeek: course.recurrence.lastWeek,
            periodTemplateID: course.periodTemplateID,
            note: course.note
        )
    }

    /// 从既有课程构造“复制”草稿：保留内容，丢掉身份。
    init(duplicating course: Course) {
        self.init(
            id: UUID(),
            editingCourseID: nil,
            name: course.name,
            subject: course.subject,
            weekday: course.weekday,
            startTime: course.startTime,
            endTime: course.endTime,
            endDayOffset: course.endDayOffset,
            location: course.location,
            teacher: course.teacher,
            parity: course.recurrence.parity,
            customWeeks: course.recurrence.weeks,
            lastWeek: course.recurrence.lastWeek,
            periodTemplateID: course.periodTemplateID,
            note: course.note
        )
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var durationMinutes: Int {
        (endTime.minutes + max(0, endDayOffset) * 24 * 60) - startTime.minutes
    }

    /// 归一化后的重复规则：去重、升序、裁掉学期范围外的周次。
    func normalizedRecurrence(semester: ScheduleSemester) -> CourseRecurrence {
        let cleaned = Array(Set(customWeeks.filter { $0 >= 1 && $0 <= semester.lastWeek })).sorted()
        let clampedLastWeek = lastWeek.map { min(max($0, 1), semester.lastWeek) }
        return CourseRecurrence(parity: parity, weeks: cleaned, lastWeek: clampedLastWeek)
    }

    /// 生成待落库的课程。`editingCourseID != nil` 时保留原 id，实现“改这一条”。
    func makeCourse(semester: ScheduleSemester, templateName: String?) -> Course {
        Course(
            id: editingCourseID ?? id,
            name: trimmedName,
            subject: subject,
            weekday: weekday,
            startTime: startTime,
            endTime: endTime,
            endDayOffset: endDayOffset,
            location: location.trimmingCharacters(in: .whitespacesAndNewlines),
            teacher: teacher.trimmingCharacters(in: .whitespacesAndNewlines),
            recurrence: normalizedRecurrence(semester: semester),
            periodTemplateID: periodTemplateID,
            periodTemplateName: templateName,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 重复规则摘要：保存前展示给用户确认。
    var recurrenceSummary: String {
        switch parity {
        case .every:
            if let lastWeek { return "每周，共前 \(lastWeek) 周" }
            return "每周（整个学期）"
        case .odd:
            if let lastWeek { return "单周，共前 \(lastWeek) 周" }
            return "单周（整个学期）"
        case .even:
            if let lastWeek { return "双周，共前 \(lastWeek) 周" }
            return "双周（整个学期）"
        case .custom:
            if customWeeks.isEmpty { return "指定周次（尚未勾选）" }
            let weeks = Array(Set(customWeeks)).sorted()
            return "第 \(weeks.map(String.init).joined(separator: "、")) 周"
        }
    }

    /// 保存前的完整摘要，例：`"高等数学 · 周一 08:00–08:45 · 单周（整个学期）"`。
    var saveSummary: String {
        let subjectName = subject.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subjectText = subjectName.isEmpty ? "未命名科目" : subjectName
        let timeText = endDayOffset > 0
            ? "\(startTime.displayText)–次日 \(endTime.displayText)"
            : TimeOfDay.rangeText(startTime, endTime)
        return "\(subjectText) · \(weekday.shortLabel) \(timeText) · \(recurrenceSummary)"
    }
}

/// 例外编辑草稿（“仅这一次”修改走这里）。
struct ScheduleExceptionDraft: Identifiable, Hashable, Sendable {
    var id: UUID
    var editingExceptionID: UUID?
    var kind: ScheduleExceptionKind
    var courseID: UUID
    var date: Date
    var replacementStart: TimeOfDay
    var replacementEnd: TimeOfDay
    var replacementLocation: String
    var note: String

    init(
        id: UUID = UUID(),
        editingExceptionID: UUID? = nil,
        kind: ScheduleExceptionKind = .cancellation,
        courseID: UUID,
        date: Date,
        replacementStart: TimeOfDay = TimeOfDay(hour: 8, minute: 0),
        replacementEnd: TimeOfDay = TimeOfDay(hour: 8, minute: 45),
        replacementLocation: String = "",
        note: String = ""
    ) {
        self.id = id
        self.editingExceptionID = editingExceptionID
        self.kind = kind
        self.courseID = courseID
        self.date = date
        self.replacementStart = replacementStart
        self.replacementEnd = replacementEnd
        self.replacementLocation = replacementLocation
        self.note = note
    }

    init(exception: ScheduleException) {
        self.init(
            id: exception.id,
            editingExceptionID: exception.id,
            kind: exception.kind,
            courseID: exception.courseID,
            date: exception.date,
            replacementStart: exception.replacementStart ?? TimeOfDay(hour: 8, minute: 0),
            replacementEnd: exception.replacementEnd ?? TimeOfDay(hour: 8, minute: 45),
            replacementLocation: exception.replacementLocation ?? "",
            note: exception.note
        )
    }

    func makeException(calendar: Calendar) -> ScheduleException {
        let day = calendar.startOfDay(for: date)
        let usesReplacementTime = kind == .relocation || kind == .makeup
        return ScheduleException(
            id: editingExceptionID ?? id,
            kind: kind,
            courseID: courseID,
            date: day,
            replacementStart: usesReplacementTime ? replacementStart : nil,
            replacementEnd: usesReplacementTime ? replacementEnd : nil,
            replacementLocation: kind == .cancellation
                ? nil
                : (replacementLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : replacementLocation.trimmingCharacters(in: .whitespacesAndNewlines)),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var summaryLine: String {
        switch kind {
        case .cancellation: return "停课（恢复为自由时间）"
        case .relocation: return "换课 \(TimeOfDay.rangeText(replacementStart, replacementEnd))"
        case .makeup: return "补课 \(TimeOfDay.rangeText(replacementStart, replacementEnd))"
        }
    }
}

// MARK: - 校验

enum ScheduleValidationSeverity: String, Sendable {
    case error
    case warning
}

struct ScheduleValidationIssue: Identifiable, Hashable, Sendable {
    var id: UUID
    var severity: ScheduleValidationSeverity
    var message: String
    /// 冲突课程 id，便于界面高亮。
    var relatedCourseID: UUID?

    init(
        id: UUID = UUID(),
        severity: ScheduleValidationSeverity,
        message: String,
        relatedCourseID: UUID? = nil
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.relatedCourseID = relatedCourseID
    }
}

enum ScheduleValidation {
    /// 校验课程草稿。`blockingErrors` 为空才允许保存。
    static func issues(
        for draft: CourseDraft,
        semester: ScheduleSemester,
        existingCourses: [Course]
    ) -> [ScheduleValidationIssue] {
        var issues: [ScheduleValidationIssue] = []

        if draft.trimmedName.isEmpty {
            issues.append(.init(
                severity: .error,
                message: "请填写课程名称。"
            ))
        }

        if draft.subject.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                severity: .error,
                message: "请选择或填写科目。"
            ))
        }

        if draft.durationMinutes <= 0 {
            issues.append(.init(
                severity: .error,
                message: "结束时间必须晚于开始时间（跨午夜请勾选“次日结束”）。"
            ))
        }

        if semester.weekCount < 1 {
            issues.append(.init(
                severity: .error,
                message: "学期总周数至少为 1 周。"
            ))
        }

        if draft.parity == .custom {
            let valid = Set(draft.customWeeks.filter { $0 >= 1 && $0 <= semester.lastWeek })
            if valid.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "指定周次至少要勾选一个有效周（1–\(semester.lastWeek)）。"
                ))
            }
            let outOfRange = draft.customWeeks.filter { $0 < 1 || $0 > semester.lastWeek }
            if !outOfRange.isEmpty {
                issues.append(.init(
                    severity: .error,
                    message: "有 \(outOfRange.count) 个周次超出学期范围（1–\(semester.lastWeek)）。"
                ))
            }
        }

        if let lastWeek = draft.lastWeek {
            if lastWeek < 1 || lastWeek > semester.lastWeek {
                issues.append(.init(
                    severity: .error,
                    message: "结束周必须在 1–\(semester.lastWeek) 之间。"
                ))
            }
            if lastWeek == 1 {
                issues.append(.init(
                    severity: .warning,
                    message: "该课程只安排 1 周，请确认是否符合预期。"
                ))
            }
        }

        if draft.parity != .custom,
           let lastWeek = draft.lastWeek,
           lastWeek < semester.lastWeek,
           draft.parity == .odd,
           lastWeek % 2 == 0 {
            issues.append(.init(
                severity: .warning,
                message: "单周课程在偶数周结束，最后一周不会安排该课程。"
            ))
        }

        issues.append(contentsOf: conflicts(
            for: draft,
            semester: semester,
            existingCourses: existingCourses
        ))

        return issues
    }

    /// 冲突检测：同一星期几、周次有交集、时间区间重叠。
    /// 冲突只作为提示（`warning`），不阻止保存，也不会导致重复扣时——
    /// 时间计算侧会先合并重叠占用再扣除。
    static func conflicts(
        for draft: CourseDraft,
        semester: ScheduleSemester,
        existingCourses: [Course]
    ) -> [ScheduleValidationIssue] {
        let candidateWeeks = effectiveWeeks(
            parity: draft.parity,
            customWeeks: draft.customWeeks,
            lastWeek: draft.lastWeek,
            semester: semester
        )
        guard !candidateWeeks.isEmpty else { return [] }

        let draftStart = draft.startTime.minutes + 0
        let draftEnd = draft.endTime.minutes + max(0, draft.endDayOffset) * 24 * 60
        guard draftEnd > draftStart else { return [] }

        var issues: [ScheduleValidationIssue] = []
        for course in existingCourses where !course.isArchived {
            if let editing = draft.editingCourseID, editing == course.id { continue }
            guard course.weekday == draft.weekday else { continue }

            let otherWeeks = effectiveWeeks(
                parity: course.recurrence.parity,
                customWeeks: course.recurrence.weeks,
                lastWeek: course.recurrence.lastWeek,
                semester: semester
            )
            guard !candidateWeeks.isDisjoint(with: otherWeeks) else { continue }

            let otherStart = course.startTime.minutes
            let otherEnd = course.endTime.minutes + max(0, course.endDayOffset) * 24 * 60
            guard otherEnd > otherStart else { continue }

            guard draftStart < otherEnd, otherStart < draftEnd else { continue }

            let sharedCount = candidateWeeks.intersection(otherWeeks).count
            issues.append(.init(
                severity: .warning,
                message: "与「\(course.name)」（\(course.timeText)）有 \(sharedCount) 周时间重叠，可继续保存；重叠时段只会计算一次。",
                relatedCourseID: course.id
            ))
        }
        return issues
    }

    /// 某条重复规则在学期内实际生效的周次集合。
    static func effectiveWeeks(
        parity: CourseWeekParity,
        customWeeks: [Int],
        lastWeek: Int?,
        semester: ScheduleSemester
    ) -> Set<Int> {
        let upper = min(lastWeek ?? semester.lastWeek, semester.lastWeek)
        guard upper >= 1 else { return [] }
        switch parity {
        case .every:
            return Set(1...upper)
        case .odd:
            return Set((1...upper).filter { $0 % 2 == 1 })
        case .even:
            return Set((1...upper).filter { $0 % 2 == 0 })
        case .custom:
            let upperBound = lastWeek ?? semester.lastWeek
            return Set(customWeeks.filter { $0 >= 1 && $0 <= upperBound })
        }
    }
}

// MARK: - 占用块

/// 占用的来源。用于界面标注与测试断言，不参与业务判断。
enum OccupancyKind: String, Codable, CaseIterable, Sendable {
    case course
    case custom
    case commute
    case buffer

    var label: String {
        switch self {
        case .course: return "课程"
        case .custom: return "固定占用"
        case .commute: return "通勤"
        case .buffer: return "缓冲"
        }
    }
}

/// 绝对时间上的一个占用区间。
///
/// 说明：`end` 可能落在次日（跨午夜课程/睡眠），因此所有下游计算都必须
/// 用“区间”而不是“当天的分钟数”来做，避免出现负数时长。
struct ScheduleBlock: Identifiable, Hashable, Sendable {
    var id: UUID
    var kind: OccupancyKind
    var label: String
    var start: Date
    var end: Date
    /// 关联的课程 id（自定义占用为 `nil`）。
    var sourceCourseID: UUID?
    /// 合并后保留下来的全部来源标签，供界面解释“这段时间被什么占了”。
    var contributorLabels: [String]

    init(
        id: UUID = UUID(),
        kind: OccupancyKind,
        label: String,
        start: Date,
        end: Date,
        sourceCourseID: UUID? = nil,
        contributorLabels: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.start = start
        self.end = end
        self.sourceCourseID = sourceCourseID
        self.contributorLabels = contributorLabels.isEmpty ? [label] : contributorLabels
    }

    var durationMinutes: Int {
        max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
    }

    var isValid: Bool { end > start }
}

// MARK: - 解析结果

/// 某一天解析出的课程实例。
///
/// 注意：这里只产出“占用与背景”，**不产生任何学习完成事件**。
struct ResolvedCourseOccurrence: Identifiable, Hashable, Sendable {
    /// 稳定实例 id：同一次课在多次计算中保持不变，便于幂等与去重。
    var id: UUID
    var courseID: UUID
    var courseName: String
    var subject: SubjectRef
    var weekday: ScheduleWeekday
    var start: Date
    var end: Date
    var location: String
    var teacher: String
    var weekIndex: Int
    var templateName: String?
    /// 该次是补课（额外日期），用于界面标注。
    var isMakeup: Bool
    /// 该次的时间/地点来自“换课”例外。
    var isReplaced: Bool
    /// 该次是停课（不会出现在结果里，仅用于日志/说明）。
    var isCancelled: Bool

    init(
        id: UUID,
        courseID: UUID,
        courseName: String,
        subject: SubjectRef,
        weekday: ScheduleWeekday,
        start: Date,
        end: Date,
        location: String,
        teacher: String,
        weekIndex: Int,
        templateName: String?,
        isMakeup: Bool = false,
        isReplaced: Bool = false,
        isCancelled: Bool = false
    ) {
        self.id = id
        self.courseID = courseID
        self.courseName = courseName
        self.subject = subject
        self.weekday = weekday
        self.start = start
        self.end = end
        self.location = location
        self.teacher = teacher
        self.weekIndex = weekIndex
        self.templateName = templateName
        self.isMakeup = isMakeup
        self.isReplaced = isReplaced
        self.isCancelled = isCancelled
    }

    var subjectName: String {
        let trimmed = subject.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名科目" : trimmed
    }

    /// 时间文本。时区必须由调用方给出，避免依赖设备当前时区。
    func timeText(in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }

    var asBlock: ScheduleBlock {
        ScheduleBlock(
            id: id,
            kind: .course,
            label: courseName,
            start: start,
            end: end,
            sourceCourseID: courseID
        )
    }
}

enum CourseOccurrenceStatus: String, Hashable, Sendable {
    case scheduled
    case cancelled
    /// 补课日期落在学期范围之外。
    case outsideSemester
}

/// 课程在某一周内的发生情况（供给编辑界面展示“单双周在学期边界”的结果）。
struct CourseWeekEntry: Identifiable, Hashable, Sendable {
    var weekIndex: Int
    var status: CourseOccurrenceStatus
    var start: Date?
    var end: Date?
    var note: String?

    var id: Int { weekIndex }
}

/// 某一天完整的解析结果。
struct ScheduleDay: Hashable, Sendable {
    /// 这一天的零点（学期时区）。
    var day: Date
    var weekday: ScheduleWeekday
    /// `nil` 表示这一天不在学期范围内。
    var weekIndex: Int?
    var courses: [ResolvedCourseOccurrence]
    /// 课程 + 例外补课合并后的占用块（重叠保持原样，交由计算侧合并）。
    var blocks: [ScheduleBlock]
    var hasConflict: Bool
    /// 需要用户注意的说明（例如“补课日期在学期外”）。
    var notes: [String]

    var isEmpty: Bool { courses.isEmpty }

    var totalCourseMinutes: Int {
        blocks.reduce(0) { $0 + $1.durationMinutes }
    }
}

/// 一周中某一天的最小信息，供周视图渲染。
struct ScheduleWeekDay: Identifiable, Hashable, Sendable {
    var date: Date
    var weekday: ScheduleWeekday
    var weekIndex: Int?
    var courses: [ResolvedCourseOccurrence]
    var isToday: Bool

    var id: Date { date }
}

struct ScheduleWeek: Hashable, Sendable {
    var weekIndex: Int
    var start: Date
    var days: [ScheduleWeekDay]
}

// MARK: - Resolver

/// 课表解析器。纯函数集合，无可变状态。
enum ScheduleResolver {

    // MARK: 星期/时区

    /// 学期时区下的星期几。系统时区变化不会影响结果。
    static func weekday(of date: Date, semester: ScheduleSemester) -> ScheduleWeekday {
        let calendar = semester.calendar
        let component = calendar.component(.weekday, from: date)
        return ScheduleWeekday(calendarWeekday: component) ?? .monday
    }

    static func startOfDay(_ date: Date, semester: ScheduleSemester) -> Date {
        semester.calendar.startOfDay(for: date)
    }

    /// 把课程时刻解析到指定星期的某一天上；跨午夜时结束时间顺延到次日。
    static func resolveInterval(
        weekday: ScheduleWeekday,
        startTime: TimeOfDay,
        endTime: TimeOfDay,
        endDayOffset: Int,
        onDay day: Date,
        semester: ScheduleSemester
    ) -> (start: Date, end: Date)? {
        let calendar = semester.calendar
        let dayStart = calendar.startOfDay(for: day)
        guard let start = startTime.date(on: dayStart, calendar: calendar) else { return nil }
        let offset = max(0, endDayOffset)
        if offset > 0 {
            guard let shiftedDay = calendar.date(byAdding: .day, value: offset, to: dayStart),
                  let end = endTime.date(on: shiftedDay, calendar: calendar) else { return nil }
            return (start, end)
        }
        // 未勾选“次日结束”但结束时刻不晚于开始时刻：按同日跨午夜处理，避免出现负时长。
        guard let endSameDay = endTime.date(on: dayStart, calendar: calendar) else { return nil }
        if endTime.minutes > startTime.minutes {
            return (start, endSameDay)
        }
        guard let end = calendar.date(byAdding: .day, value: 1, to: endSameDay) else { return nil }
        return (start, end)
    }

    // MARK: 周次

    /// 某条课程规则在某学期周次是否生效。
    static func isActive(week: Int, recurrence: CourseRecurrence, semester: ScheduleSemester) -> Bool {
        guard week >= 1, week <= semester.lastWeek else { return false }
        guard recurrence.parity.matches(week: week) else { return false }
        if let lastWeek = recurrence.lastWeek, week > lastWeek { return false }
        if recurrence.parity == .custom, !recurrence.weeks.contains(week) { return false }
        return true
    }

    /// 某条课程规则在整个学期内生效的所有周次，按升序排列。
    static func activeWeeks(for course: Course, semester: ScheduleSemester) -> [Int] {
        (1...semester.lastWeek).filter {
            isActive(week: $0, recurrence: course.recurrence, semester: semester)
        }
    }

    /// 该课程在学期内实际有课的第一次/最后一次日期。
    static func activeDateRange(
        for course: Course,
        semester: ScheduleSemester
    ) -> (first: Date, last: Date)? {
        let weeks = activeWeeks(for: course, semester: semester)
        guard let firstWeek = weeks.first, let lastWeek = weeks.last else { return nil }
        guard let first = semester.date(week: firstWeek, weekday: course.weekday, calendar: semester.calendar),
              let last = semester.date(week: lastWeek, weekday: course.weekday, calendar: semester.calendar) else {
            return nil
        }
        return (first, last)
    }

    // MARK: 单日解析

    /// 解析某一天的课程与占用。
    ///
    /// - 停课：从结果中移除（该次不占时间，空闲时间自动恢复）。
    /// - 换课：替换时间/地点，不额外增加占用。
    /// - 补课：在额外日期增加一次占用；若与原课同日同时间则自动去重。
    static func day(
        for date: Date,
        semester: ScheduleSemester,
        courses: [Course],
        exceptions: [ScheduleException] = []
    ) -> ScheduleDay {
        let calendar = semester.calendar
        let dayStart = calendar.startOfDay(for: date)
        let weekday = weekday(of: dayStart, semester: semester)
        let weekIndex = semester.weekIndex(for: dayStart)
        let inSemester = (1...semester.lastWeek).contains(weekIndex)

        var occurrences: [ResolvedCourseOccurrence] = []
        var notes: [String] = []
        var seenIdentity = Set<String>()

        func identity(courseID: UUID, start: Date, end: Date, isMakeup: Bool) -> String {
            "\(courseID.uuidString)|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))|\(isMakeup)"
        }

        for course in courses where !course.isArchived {
            let courseExceptions = exceptions.filter {
                $0.courseID == course.id && calendar.isDate($0.date, inSameDayAs: dayStart)
            }
            let cancellation = courseExceptions.first { $0.kind == .cancellation }
            let replacement = courseExceptions.first { $0.kind == .relocation }

            // 补课（额外日期）：无论当天是否为学期内、是否是该课程的正常星期，都要展开。
            for makeup in courseExceptions where makeup.kind == .makeup {
                guard let start = makeup.replacementStart, let end = makeup.replacementEnd else { continue }
                guard let interval = resolveInterval(
                    weekday: weekday,
                    startTime: start,
                    endTime: end,
                    endDayOffset: 0,
                    onDay: dayStart,
                    semester: semester
                ) else { continue }
                let key = identity(courseID: course.id, start: interval.start, end: interval.end, isMakeup: true)
                guard !seenIdentity.contains(key) else { continue }
                seenIdentity.insert(key)
                if !inSemester {
                    notes.append("「\(course.name)」的补课安排在学期范围之外（第 \(weekIndex) 周）。")
                }
                occurrences.append(ResolvedCourseOccurrence(
                    id: stableOccurrenceID(courseID: course.id, start: interval.start, isMakeup: true),
                    courseID: course.id,
                    courseName: course.name,
                    subject: course.subject,
                    weekday: weekday,
                    start: interval.start,
                    end: interval.end,
                    location: makeup.replacementLocation ?? course.location,
                    teacher: course.teacher,
                    weekIndex: weekIndex,
                    templateName: course.periodTemplateName,
                    isMakeup: true
                ))
            }

            // 正常重复课程。
            guard inSemester else { continue }
            guard isActive(week: weekIndex, recurrence: course.recurrence, semester: semester) else { continue }
            guard course.weekday == weekday else { continue }
            guard cancellation == nil else { continue }

            let startTime = replacement?.replacementStart ?? course.startTime
            let endTime = replacement?.replacementEnd ?? course.endTime
            let endOffset = replacement?.replacementStart != nil ? 0 : course.endDayOffset
            guard let interval = resolveInterval(
                weekday: weekday,
                startTime: startTime,
                endTime: endTime,
                endDayOffset: endOffset,
                onDay: dayStart,
                semester: semester
            ) else { continue }

            let key = identity(courseID: course.id, start: interval.start, end: interval.end, isMakeup: false)
            guard !seenIdentity.contains(key) else { continue }
            seenIdentity.insert(key)

            occurrences.append(ResolvedCourseOccurrence(
                id: stableOccurrenceID(courseID: course.id, start: interval.start, isMakeup: false),
                courseID: course.id,
                courseName: course.name,
                subject: course.subject,
                weekday: weekday,
                start: interval.start,
                end: interval.end,
                location: replacement?.replacementLocation ?? course.location,
                teacher: course.teacher,
                weekIndex: weekIndex,
                templateName: course.periodTemplateName,
                isReplaced: replacement != nil
            ))
        }

        occurrences.sort { $0.start < $1.start }
        let blocks = occurrences.map(\.asBlock).filter(\.isValid)
        let conflicts = conflicts(in: blocks)

        if !courses.isEmpty {
            if weekIndex < 1 {
                notes.append("这一天在学期开始之前。")
            } else if weekIndex > semester.lastWeek {
                notes.append("这一天在学期结束之后。")
            }
        }

        return ScheduleDay(
            day: dayStart,
            weekday: weekday,
            weekIndex: inSemester ? weekIndex : nil,
            courses: occurrences,
            blocks: blocks,
            hasConflict: !conflicts.isEmpty,
            notes: notes
        )
    }

    /// 稳定实例 id：同一门课 + 同一起点 + 是否补课 → 同一 id。
    /// 这让“重复调用不重复执行”在数据层面成立。
    static func stableOccurrenceID(courseID: UUID, start: Date, isMakeup: Bool) -> UUID {
        var hasher = StableHasher()
        hasher.combine(courseID.uuidString)
        hasher.combine(String(Int(start.timeIntervalSince1970)))
        hasher.combine(isMakeup ? "makeup" : "regular")
        return hasher.finalize()
    }

    /// 周视图时间轴的像素无关布局（单位：分钟）。
    ///
    /// 抽到这里而不是留在视图里，是为了让“跨午夜课程不会出现负高度”这类
    /// 不变量可以被测试覆盖。
    struct TimelineLayout: Hashable, Sendable {
        /// 距时间轴顶部的分钟数，`>= 0`。
        var offsetMinutes: Int
        /// 区块高度（分钟），`> 0`。
        var heightMinutes: Int
    }

    /// 计算某次课在给定小时刻度时间轴上的位置。
    ///
    /// - Parameters:
    ///   - occurrence: 已解析的课程实例。
    ///   - hourRange: 时间轴包含的小时（例如 `Array(7...22)`）。
    ///   - semester: 提供学期时区。
    ///   - minimumVisibleMinutes: 最小可见高度，避免极短课程看不见。
    static func timelineLayout(
        for occurrence: ResolvedCourseOccurrence,
        hourRange: [Int],
        semester: ScheduleSemester,
        minimumVisibleMinutes: Int = 20
    ) -> TimelineLayout {
        let firstHour = hourRange.first ?? 0
        let lastHour = hourRange.last ?? 23
        let axisStart = firstHour * 60
        let axisEnd = (lastHour + 1) * 60

        let calendar = semester.calendar
        let startMinutes = calendar.component(.hour, from: occurrence.start) * 60
            + calendar.component(.minute, from: occurrence.start)
        var endMinutes = calendar.component(.hour, from: occurrence.end) * 60
            + calendar.component(.minute, from: occurrence.end)
        if endMinutes <= startMinutes {
            // 跨午夜：结束落在次日，按时间轴末端处理。
            endMinutes = axisEnd
        }

        let offset = max(0, startMinutes - axisStart)
        let clampedEnd = min(max(endMinutes, startMinutes + minimumVisibleMinutes), axisEnd)
        let height = max(minimumVisibleMinutes, clampedEnd - axisStart - offset)
        return TimelineLayout(offsetMinutes: offset, heightMinutes: height)
    }

    // MARK: 区间工具

    /// 找出所有重叠的区间对（用于冲突提示）。
    static func conflicts(in blocks: [ScheduleBlock]) -> [(ScheduleBlock, ScheduleBlock)] {
        let sorted = blocks.filter(\.isValid).sorted { $0.start < $1.start }
        var result: [(ScheduleBlock, ScheduleBlock)] = []
        for index in sorted.indices {
            var cursor = index + 1
            while cursor < sorted.count, sorted[cursor].start < sorted[index].end {
                result.append((sorted[index], sorted[cursor]))
                cursor += 1
            }
        }
        return result
    }

    /// 合并重叠/相邻区间。存在的意义：两段重叠占用只能扣一次。
    ///
    /// 合并后的区间保留“最有信息量”的来源：
    /// 只要有课程参与，就标注为课程（并保留课程 id），否则沿用第一段的来源，
    /// 同时把所有参与来源收进 `contributorLabels` 供界面解释。
    static func merged(_ blocks: [ScheduleBlock]) -> [ScheduleBlock] {
        let sorted = blocks.filter(\.isValid).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var result: [ScheduleBlock] = []
        for block in sorted {
            guard let last = result.last, block.start <= last.end else {
                result.append(block)
                continue
            }
            var merged = last
            merged.end = max(last.end, block.end)
            merged.contributorLabels = uniqueLabels(last.contributorLabels + block.contributorLabels)

            let courseBlock = block.kind == .course ? block : (last.kind == .course ? last : nil)
            if let courseBlock {
                merged.kind = .course
                merged.label = courseBlock.label
                merged.sourceCourseID = courseBlock.sourceCourseID
            } else if last.sourceCourseID == nil {
                merged.sourceCourseID = block.sourceCourseID
            }
            result[result.count - 1] = merged
        }
        return result
    }

    private static func uniqueLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for label in labels where !label.isEmpty {
            guard !seen.contains(label) else { continue }
            seen.insert(label)
            result.append(label)
        }
        return result
    }

    /// 区间差集：`windows - blocks`，并裁掉短于 `minMinutes` 的碎片。
    static func freeIntervals(
        windows: [DateInterval],
        blocks: [DateInterval],
        minMinutes: Int
    ) -> [DateInterval] {
        let mergedBlocks = mergedIntervals(blocks)
        var result: [DateInterval] = []
        let threshold = max(0, minMinutes)

        for window in windows where window.duration > 0 {
            var cursor = window.start
            for block in mergedBlocks {
                if block.end <= cursor { continue }
                if block.start >= window.end { break }
                if block.start > cursor {
                    let candidate = DateInterval(start: cursor, end: min(block.start, window.end))
                    if candidate.duration >= Double(threshold) * 60 {
                        result.append(candidate)
                    }
                }
                cursor = max(cursor, min(block.end, window.end))
                if cursor >= window.end { break }
            }
            if cursor < window.end {
                let candidate = DateInterval(start: cursor, end: window.end)
                if candidate.duration >= Double(threshold) * 60 {
                    result.append(candidate)
                }
            }
        }

        return result.sorted { $0.start < $1.start }
    }

    /// 合并裸 `DateInterval`（相邻也算合并，避免出现 0 分钟的“缝隙”）。
    static func mergedIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        for interval in sorted {
            if let last = result.last, interval.start <= last.end {
                if interval.end > last.end {
                    result[result.count - 1] = DateInterval(start: last.start, end: interval.end)
                }
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// 交集：`a ∩ b`。
    static func intersect(_ a: [DateInterval], _ b: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for left in a {
            for right in b {
                let start = max(left.start, right.start)
                let end = min(left.end, right.end)
                if end > start {
                    result.append(DateInterval(start: start, end: end))
                }
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    // MARK: 周解析

    /// 一周的起止日：以传入 `day` 所在的 ISO 周（周一为首日）。
    static func weekStartDate(containing day: Date, semester: ScheduleSemester) -> Date {
        let calendar = semester.calendar
        let weekday = weekday(of: day, semester: semester)
        let dayStart = calendar.startOfDay(for: day)
        let offset = -(weekday.isoWeekdayNumber - 1)
        return calendar.date(byAdding: .day, value: offset, to: dayStart) ?? dayStart
    }

    /// 某一周的课表（`weekIndex` 与学期无关，可传入超出范围的周次，返回的 `weekIndex` 为 `nil` 的日期仍会给出 weekday）。
    static func week(
        index weekIndex: Int,
        semester: ScheduleSemester,
        courses: [Course],
        exceptions: [ScheduleException] = [],
        today: Date?
    ) -> ScheduleWeek {
        let calendar = semester.calendar
        let todayStart = today.map { calendar.startOfDay(for: $0) }
        var days: [ScheduleWeekDay] = []

        for offset in 0..<7 {
            let clampedWeek = max(1, weekIndex)
            let start = semester.date(week: clampedWeek, weekday: .monday, calendar: calendar)
                ?? calendar.startOfDay(for: semester.firstWeekStart)
            let base = calendar.date(byAdding: .day, value: (weekIndex - clampedWeek) * 7 + offset, to: start)
                ?? start
            let dayStart = calendar.startOfDay(for: base)
            let day = self.day(
                for: dayStart,
                semester: semester,
                courses: courses,
                exceptions: exceptions
            )
            days.append(ScheduleWeekDay(
                date: dayStart,
                weekday: day.weekday,
                weekIndex: day.weekIndex,
                courses: day.courses,
                isToday: todayStart.map { calendar.isDate($0, inSameDayAs: dayStart) } ?? false
            ))
        }

        let firstDay = days.first?.date ?? semester.firstWeekStart
        return ScheduleWeek(
            weekIndex: weekIndex,
            start: firstDay,
            days: days
        )
    }

    // MARK: 课程周次概览

    /// 课程在学期内的逐周状态：用于编辑界面展示“单双周在学期边界正确”。
    static func weekEntries(
        for course: Course,
        semester: ScheduleSemester,
        exceptions: [ScheduleException] = []
    ) -> [CourseWeekEntry] {
        let calendar = semester.calendar
        let courseExceptions = exceptions.filter { $0.courseID == course.id }

        return (1...semester.lastWeek).map { week in
            guard let date = semester.date(week: week, weekday: course.weekday, calendar: calendar) else {
                return CourseWeekEntry(weekIndex: week, status: .scheduled, start: nil, end: nil, note: nil)
            }
            let dayExceptions = courseExceptions.filter { calendar.isDate($0.date, inSameDayAs: date) }
            if dayExceptions.contains(where: { $0.kind == .cancellation }) {
                return CourseWeekEntry(weekIndex: week, status: .cancelled, start: nil, end: nil, note: "停课")
            }
            guard isActive(week: week, recurrence: course.recurrence, semester: semester) else {
                return CourseWeekEntry(weekIndex: week, status: .cancelled, start: nil, end: nil, note: "本周不上课")
            }
            let replacement = dayExceptions.first { $0.kind == .relocation }
            let startTime = replacement?.replacementStart ?? course.startTime
            let endTime = replacement?.replacementEnd ?? course.endTime
            let offset = replacement?.replacementStart != nil ? 0 : course.endDayOffset
            let interval = resolveInterval(
                weekday: course.weekday,
                startTime: startTime,
                endTime: endTime,
                endDayOffset: offset,
                onDay: date,
                semester: semester
            )
            return CourseWeekEntry(
                weekIndex: week,
                status: .scheduled,
                start: interval?.start,
                end: interval?.end,
                note: replacement != nil ? "换课" : nil
            )
        }
    }
}

// MARK: - 稳定哈希（幂等 id）

/// 使用 FNV-1a 生成稳定 UUID，替代 `UUID()` 的随机性。
/// Swift 的 `Hasher` 每次进程启动都会随机加盐，不能用在这里。
struct StableHasher {
    private var hash: UInt64 = 0xcbf29ce484222325
    private let prime: UInt64 = 0x100000001b3

    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        hash ^= 0x1F
        hash = hash &* prime
    }

    mutating func finalize() -> UUID {
        var second = hash &* prime
        second ^= 0x9E3779B97F4A7C15
        let bytes = withUnsafeBytes(of: (hash, second)) { Array($0) }
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 {
            uuidBytes[index] = bytes[index]
        }
        // 固定 version/variant 位，保证生成的 UUID 合法且稳定。
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }
}

// MARK: - G 接入契约（持久化）

/// 交给 G 接入 `StoreSnapshot` 时使用的键名与迁移说明。
///
/// 本轮不修改 `Models.swift`：所有持久化写入由 G 统一入口完成。
enum SchedulePersistenceKeys {
    /// `StoreSnapshot` 新增字段建议键名（Codable 默认键名）。
    static let semester = "scheduleSemester"
    static let courses = "scheduleCourses"
    static let exceptions = "scheduleExceptions"
    static let periodTemplates = "schedulePeriodTemplates"
    static let availabilitySettings = "availabilitySettings"

    /// 需要 G 在 `StoreSnapshot.init(from:)` 中补齐的默认值，
    /// 保证旧 `store.json` 仍可解码。
    static func decodedSchedule(from container: KeyedDecodingContainer<StoreSnapshotCodingKey>) -> ScheduleSnapshot? {
        guard let semester = try? container.decodeIfPresent(ScheduleSemester.self, forKey: .init(stringValue: semester)) else {
            return nil
        }
        let courses = (try? container.decodeIfPresent([Course].self, forKey: .init(stringValue: courses))) ?? []
        let exceptions = (try? container.decodeIfPresent([ScheduleException].self, forKey: .init(stringValue: exceptions))) ?? []
        let templates = (try? container.decodeIfPresent([PeriodTemplate].self, forKey: .init(stringValue: periodTemplates)))
            ?? PeriodTemplate.defaultTemplates
        return ScheduleSnapshot(
            semester: semester,
            courses: courses,
            exceptions: exceptions,
            periodTemplates: templates
        )
    }
}

/// 仅用于在 `SchedulePersistenceKeys.decodedSchedule` 中构造键，
/// 避免引用 `Models.swift` 的私有 `CodingKeys`。
struct StoreSnapshotCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
