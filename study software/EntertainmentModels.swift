import Foundation

// MARK: - 娱乐解锁与奖励（模块 A 数据契约）
//
// 三条硬约束：
// 1. 奖励必须关联"当时的规则版本"：`RewardGrant` 内嵌 `ruleSnapshot`，
//    规则后续被编辑甚至删除，都不会改写历史发放记录。
// 2. 发放必须有稳定唯一键：同一天同一规则版本只发一次；同一规则同一天也不重复获益。
// 3. 领取 / 开始 / 结束是三个独立状态，重复领取不会产生第二条记录。

// MARK: - 解锁条件

/// 条件度量口径。全部来自真实完成事件或计划项，不读网络、不读 API。
enum RewardMetric: String, Codable, CaseIterable, Sendable {
    /// 标准完成的任务数。
    case standardCompletedItemCount
    /// 保底完成及以上的任务数。
    case minimumCompletedItemCount
    /// 产生过学习记录的任务数（含"已学习"）。
    case studiedItemCount
    /// 记录到的学习时长（分钟）。旧版本每日总数**不**参与该口径。
    case recordedMinutes
    /// 标准完成比例（0...1），无计划时为 0。
    case standardCompletionRatio
    /// 只要当天有任意学习记录。
    case anyStudied

    var label: String {
        switch self {
        case .standardCompletedItemCount: return "标准完成任务数"
        case .minimumCompletedItemCount: return "保底完成任务数"
        case .studiedItemCount: return "已学习任务数"
        case .recordedMinutes: return "学习时长（分钟）"
        case .standardCompletionRatio: return "标准完成比例"
        case .anyStudied: return "当天有学习"
        }
    }

    var unitLabel: String {
        switch self {
        case .standardCompletedItemCount, .minimumCompletedItemCount, .studiedItemCount: return "项"
        case .recordedMinutes: return "分钟"
        case .standardCompletionRatio: return "%"
        case .anyStudied: return ""
        }
    }
}

/// 解锁条件（可持久化）。
struct EntertainmentUnlockCondition: Codable, Hashable, Sendable {
    var metric: RewardMetric
    var requiredValue: Double
    /// 展示文案（由规则编辑者填写，不编造学习内容）。
    var label: String

    init(metric: RewardMetric, requiredValue: Double, label: String = "") {
        self.metric = metric
        self.requiredValue = max(0, requiredValue)
        self.label = label
    }

    static func standardItems(_ count: Int) -> EntertainmentUnlockCondition {
        EntertainmentUnlockCondition(metric: .standardCompletedItemCount, requiredValue: Double(count))
    }

    static func minimumItems(_ count: Int) -> EntertainmentUnlockCondition {
        EntertainmentUnlockCondition(metric: .minimumCompletedItemCount, requiredValue: Double(count))
    }

    static func minutes(_ minutes: Int) -> EntertainmentUnlockCondition {
        EntertainmentUnlockCondition(metric: .recordedMinutes, requiredValue: Double(minutes))
    }

    static var anyStudied: EntertainmentUnlockCondition {
        EntertainmentUnlockCondition(metric: .anyStudied, requiredValue: 1)
    }

    var displayText: String {
        if !label.isEmpty { return label }
        switch metric {
        case .anyStudied:
            return "当天有任意学习记录"
        case .standardCompletionRatio:
            return "标准完成比例达到 \(Int((requiredValue * 100).rounded()))%"
        default:
            return "\(metric.label)达到 \(formattedRequiredValue) \(metric.unitLabel)"
        }
    }

    private var formattedRequiredValue: String {
        requiredValue == requiredValue.rounded() ? String(Int(requiredValue)) : String(format: "%.1f", requiredValue)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMetric = try container.decodeIfPresent(String.self, forKey: .metric)
            ?? RewardMetric.standardCompletedItemCount.rawValue
        metric = RewardMetric(rawValue: rawMetric) ?? .standardCompletedItemCount
        requiredValue = max(0, try container.decodeIfPresent(Double.self, forKey: .requiredValue) ?? 0)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

// MARK: - 保底适配方式

/// 减量 / 保底日的娱乐奖励适配方式。
enum EntertainmentFallbackMode: Codable, Hashable, Sendable {
    /// 不做适配：未达标就不发放。
    case none
    /// 按完成比例缩短奖励，但保留至少 `ratio` 的比例。
    case scaledReward(ratio: Double)
    /// 保底日固定发放若干分钟（不超过规则时长）。
    case fixedMinimumReward(minutes: Int)
    /// 无论如何都解锁（例如休息日）。
    case unlockRegardless
    /// 当天不发放奖励。
    case suspend

    var label: String {
        switch self {
        case .none: return "不适配"
        case .scaledReward: return "按完成比例缩短"
        case .fixedMinimumReward: return "保底固定时长"
        case .unlockRegardless: return "始终解锁"
        case .suspend: return "当天不发放"
        }
    }

    var detailText: String {
        switch self {
        case .none:
            return "未达标则不发奖励。"
        case .scaledReward(let ratio):
            return "按完成比例缩短奖励，至少保留 \(Int((min(max(ratio, 0), 1) * 100).rounded()))%。"
        case .fixedMinimumReward(let minutes):
            return "只要当天有学习记录，就发放 \(max(0, minutes)) 分钟奖励。"
        case .unlockRegardless:
            return "即使未达标也照常解锁。"
        case .suspend:
            return "当天不发放任何奖励。"
        }
    }

    /// 计算实际发放分钟数。
    ///
    /// - Parameters:
    ///   - ruleMinutes: 规则定义的奖励时长。
    ///   - isConditionSatisfied: 是否达到解锁条件。
    ///   - achievedRatio: 当天完成比例（0...1）。无记录时为 0。
    /// - Returns: 发放分钟数；`nil` 表示不发放。
    func grantedMinutes(ruleMinutes: Int, isConditionSatisfied: Bool, achievedRatio: Double) -> Int? {
        let ruleMinutes = max(0, ruleMinutes)
        guard ruleMinutes > 0 else { return nil }
        if isConditionSatisfied { return ruleMinutes }
        let ratio = min(max(achievedRatio, 0), 1)
        switch self {
        case .none, .suspend:
            return nil
        case .unlockRegardless:
            return ruleMinutes
        case .scaledReward(let floorRatio):
            guard ratio > 0 else { return nil }
            let floor = min(max(floorRatio, 0), 1)
            let effective = max(floor, ratio)
            let granted = Int((Double(ruleMinutes) * effective).rounded(.down))
            return granted > 0 ? granted : nil
        case .fixedMinimumReward(let minutes):
            guard ratio > 0 else { return nil }
            let granted = min(max(0, minutes), ruleMinutes)
            return granted > 0 ? granted : nil
        }
    }

    private enum Kind: String, Codable {
        case none
        case scaledReward
        case fixedMinimumReward
        case unlockRegardless
        case suspend
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case ratio
        case minutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? Kind.none.rawValue
        switch Kind(rawValue: rawKind) ?? .none {
        case .none:
            self = .none
        case .scaledReward:
            self = .scaledReward(ratio: min(max(try container.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5, 0), 1))
        case .fixedMinimumReward:
            self = .fixedMinimumReward(minutes: max(0, try container.decodeIfPresent(Int.self, forKey: .minutes) ?? 0))
        case .unlockRegardless:
            self = .unlockRegardless
        case .suspend:
            self = .suspend
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .scaledReward(let ratio):
            try container.encode(Kind.scaledReward, forKey: .kind)
            try container.encode(ratio, forKey: .ratio)
        case .fixedMinimumReward(let minutes):
            try container.encode(Kind.fixedMinimumReward, forKey: .kind)
            try container.encode(minutes, forKey: .minutes)
        case .unlockRegardless:
            try container.encode(Kind.unlockRegardless, forKey: .kind)
        case .suspend:
            try container.encode(Kind.suspend, forKey: .kind)
        }
    }
}

// MARK: - 目标绑定（E 模块需求，A 定稿的可选字段）
//
// "完成指定计划任务或具体复习实例"必须绑定到**具体实例**：
// - 计划项绑定带 `dayKey`，昨天完成同一个知识点不会解锁今天；
// - `displayName` 只记录真实标题，便于规则编辑与诊断说明"绑定的是哪一条"。
//
// 这些字段全部可选：旧数据缺失即 `nil`，语义等于"通用条件 + 每天生效"，
// 因此不需要提升 schema 版本。

/// 规则绑定到的具体任务 / 复习实例。
struct EntertainmentTargetBinding: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// 某条计划项实例（必须带学习日）。
        case planItem
        /// 既有 `ReviewTask`。
        case reviewTask
        /// `ScheduleResolver` 解析出的某次课程实例。
        case courseOccurrence
        /// 知识点（按完成事件来源匹配，仍受学习日限制）。
        case knowledgePoint

        var label: String {
            switch self {
            case .planItem: return "计划任务"
            case .reviewTask: return "复习任务"
            case .courseOccurrence: return "课程实例"
            case .knowledgePoint: return "知识点"
            }
        }
    }

    var kind: Kind
    var id: UUID
    /// 绑定时所属学习日。计划项实例必须带，用于防止跨日误解锁。
    var dayKey: StudyDayKey?
    /// 真实展示名（任务名 / 课程名 / 知识点名），不编造。
    var displayName: String

    init(kind: Kind, id: UUID, dayKey: StudyDayKey? = nil, displayName: String = "") {
        self.kind = kind
        self.id = id
        self.dayKey = dayKey
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayText: String {
        let name = displayName.isEmpty ? kind.label : displayName
        guard let dayKey else { return "\(kind.label)：\(name)" }
        return "\(kind.label)：\(name)（\(dayKey.localDateString)）"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind) ?? Kind.planItem.rawValue
        kind = Kind(rawValue: rawKind) ?? .planItem
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dayKey = try container.decodeIfPresent(StudyDayKey.self, forKey: .dayKey)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
    }
}

// MARK: - 规则

/// 娱乐规则。
///
/// 编辑规则不会修改已有记录：`revised(...)` 生成新的 `revisionID` 与 `ruleVersion`，
/// 历史 `RewardGrant` 保留旧版本的 `ruleSnapshot`。
struct EntertainmentRule: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// 生效起始学习日；`nil` = 立即生效。
    var effectiveFrom: StudyDayKey?
    /// 生效结束学习日；`nil` = 长期有效。
    var effectiveUntil: StudyDayKey?
    var condition: EntertainmentUnlockCondition
    /// 绑定的具体任务 / 复习实例；`nil` 或空 = 通用条件（只按度量口径判定）。
    var targets: [EntertainmentTargetBinding]?
    /// 每周重复的星期（1 = 周日 … 7 = 周六，与 `Calendar` 一致）；`nil` 或空 = 每天生效。
    var repeatWeekdays: [Int]?
    /// 保底适配方式。
    var fallback: EntertainmentFallbackMode
    /// 奖励时长（分钟）。
    var rewardMinutes: Int
    /// 规则版本号，从 1 递增。
    var ruleVersion: Int
    /// 版本身份：每次编辑生成新的 `revisionID`。
    var revisionID: UUID
    var isEnabled: Bool
    var isArchived: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        effectiveFrom: StudyDayKey? = nil,
        effectiveUntil: StudyDayKey? = nil,
        condition: EntertainmentUnlockCondition,
        targets: [EntertainmentTargetBinding]? = nil,
        repeatWeekdays: [Int]? = nil,
        fallback: EntertainmentFallbackMode = .none,
        rewardMinutes: Int,
        ruleVersion: Int = 1,
        revisionID: UUID? = nil,
        isEnabled: Bool = true,
        isArchived: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.condition = condition
        self.targets = Self.normalizedTargets(targets)
        self.repeatWeekdays = Self.normalizedWeekdays(repeatWeekdays)
        self.fallback = fallback
        self.rewardMinutes = max(0, rewardMinutes)
        self.ruleVersion = max(1, ruleVersion)
        self.revisionID = revisionID ?? id
        self.isEnabled = isEnabled
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isUsable: Bool { isEnabled && !isArchived }

    /// 绑定实例；空数组与 `nil` 语义相同。
    var boundTargets: [EntertainmentTargetBinding] {
        targets ?? []
    }

    /// 是否每天都生效（没有设置每周重复）。
    var occursEveryDay: Bool {
        (repeatWeekdays ?? []).isEmpty
    }

    /// 重复规则的展示文案。
    var repeatText: String {
        guard let weekdays = repeatWeekdays, !weekdays.isEmpty else { return "每天" }
        let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return weekdays.compactMap { (1...7).contains($0) ? names[$0] : nil }.joined(separator: "、")
    }

    /// 该规则在指定学习日是否生效。
    func isEffective(on dayKey: StudyDayKey) -> Bool {
        guard isUsable else { return false }
        if let effectiveFrom, dayKey < effectiveFrom { return false }
        if let effectiveUntil, dayKey > effectiveUntil { return false }
        return true
    }

    /// 该规则在指定学习日是否生效（同时考虑每周重复日期）。
    ///
    /// 星期从外部传入的日历与学习日推导，不在模型里读系统时钟。
    func isEffective(on dayKey: StudyDayKey, calendar: Calendar) -> Bool {
        guard isEffective(on: dayKey) else { return false }
        guard let weekdays = repeatWeekdays, !weekdays.isEmpty else { return true }
        guard let start = dayKey.startOfDay(calendar: calendar) else { return false }
        return weekdays.contains(calendar.component(.weekday, from: start))
    }

    private static func normalizedTargets(_ raw: [EntertainmentTargetBinding]?) -> [EntertainmentTargetBinding]? {
        guard let raw, !raw.isEmpty else { return nil }
        var seen = Set<String>()
        return raw.filter {
            seen.insert("\($0.kind.rawValue)|\($0.id.uuidString)|\($0.dayKey?.localDateString ?? "")").inserted
        }
    }

    private static func normalizedWeekdays(_ raw: [Int]?) -> [Int]? {
        guard let raw else { return nil }
        let values = Set(raw.filter { (1...7).contains($0) })
        return values.isEmpty ? nil : values.sorted()
    }

    /// 当前版本的快照（写入 `RewardGrant` 用）。
    var snapshotValue: EntertainmentRuleSnapshot {
        EntertainmentRuleSnapshot(
            ruleID: id,
            name: name,
            condition: condition,
            targets: targets,
            fallback: fallback,
            rewardMinutes: rewardMinutes,
            ruleVersion: ruleVersion,
            revisionID: revisionID
        )
    }

    /// 编辑规则：生成新版本（`ruleVersion + 1`、新 `revisionID`），旧版本留在历史奖励里。
    func revised(
        name: String? = nil,
        effectiveFrom: StudyDayKey?? = nil,
        effectiveUntil: StudyDayKey?? = nil,
        condition: EntertainmentUnlockCondition? = nil,
        targets: [EntertainmentTargetBinding]?? = nil,
        repeatWeekdays: [Int]?? = nil,
        fallback: EntertainmentFallbackMode? = nil,
        rewardMinutes: Int? = nil,
        isEnabled: Bool? = nil,
        at now: Date
    ) -> EntertainmentRule {
        EntertainmentRule(
            id: id,
            name: name ?? self.name,
            effectiveFrom: effectiveFrom ?? self.effectiveFrom,
            effectiveUntil: effectiveUntil ?? self.effectiveUntil,
            condition: condition ?? self.condition,
            targets: targets ?? self.targets,
            repeatWeekdays: repeatWeekdays ?? self.repeatWeekdays,
            fallback: fallback ?? self.fallback,
            rewardMinutes: rewardMinutes ?? self.rewardMinutes,
            ruleVersion: ruleVersion + 1,
            revisionID: UUID(),
            isEnabled: isEnabled ?? self.isEnabled,
            isArchived: isArchived,
            createdAt: createdAt,
            updatedAt: now
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        effectiveFrom = try container.decodeIfPresent(StudyDayKey.self, forKey: .effectiveFrom)
        effectiveUntil = try container.decodeIfPresent(StudyDayKey.self, forKey: .effectiveUntil)
        condition = try container.decodeIfPresent(EntertainmentUnlockCondition.self, forKey: .condition)
            ?? EntertainmentUnlockCondition(metric: .anyStudied, requiredValue: 1)
        targets = Self.normalizedTargets(try container.decodeIfPresent([EntertainmentTargetBinding].self, forKey: .targets))
        repeatWeekdays = Self.normalizedWeekdays(try container.decodeIfPresent([Int].self, forKey: .repeatWeekdays))
        fallback = try container.decodeIfPresent(EntertainmentFallbackMode.self, forKey: .fallback) ?? .none
        rewardMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .rewardMinutes) ?? 0)
        ruleVersion = max(1, try container.decodeIfPresent(Int.self, forKey: .ruleVersion) ?? 1)
        revisionID = try container.decodeIfPresent(UUID.self, forKey: .revisionID) ?? id
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? StudyTimestamp.unspecified
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

/// 规则版本快照：历史奖励的"当时规则"，不随规则编辑而改写。
struct EntertainmentRuleSnapshot: Codable, Hashable, Sendable {
    var ruleID: UUID
    var name: String
    var condition: EntertainmentUnlockCondition
    /// 发放时绑定的具体实例（`nil` = 通用条件）。保留它是为了审计
    /// "当时的奖励依据了哪一条任务/复习实例"，历史记录不随规则编辑而改写。
    var targets: [EntertainmentTargetBinding]?
    var fallback: EntertainmentFallbackMode
    var rewardMinutes: Int
    var ruleVersion: Int
    var revisionID: UUID

    init(
        ruleID: UUID,
        name: String,
        condition: EntertainmentUnlockCondition,
        targets: [EntertainmentTargetBinding]? = nil,
        fallback: EntertainmentFallbackMode,
        rewardMinutes: Int,
        ruleVersion: Int,
        revisionID: UUID
    ) {
        self.ruleID = ruleID
        self.name = name
        self.condition = condition
        self.targets = targets
        self.fallback = fallback
        self.rewardMinutes = max(0, rewardMinutes)
        self.ruleVersion = max(1, ruleVersion)
        self.revisionID = revisionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ruleID = try container.decodeIfPresent(UUID.self, forKey: .ruleID) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        targets = try container.decodeIfPresent([EntertainmentTargetBinding].self, forKey: .targets)
        condition = try container.decodeIfPresent(EntertainmentUnlockCondition.self, forKey: .condition)
            ?? EntertainmentUnlockCondition(metric: .anyStudied, requiredValue: 1)
        fallback = try container.decodeIfPresent(EntertainmentFallbackMode.self, forKey: .fallback) ?? .none
        rewardMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .rewardMinutes) ?? 0)
        ruleVersion = max(1, try container.decodeIfPresent(Int.self, forKey: .ruleVersion) ?? 1)
        revisionID = try container.decodeIfPresent(UUID.self, forKey: .revisionID) ?? ruleID
    }
}

// MARK: - 条件进度（持久化证据）

/// 条件进度：发放奖励时"依据了哪些事件、算到了多少"的证据。
struct RewardConditionProgress: Codable, Hashable, Sendable {
    var ruleID: UUID
    var ruleRevisionID: UUID
    var metric: RewardMetric
    var achievedValue: Double
    var requiredValue: Double
    var detail: String
    /// 依据的完成事件 ID。
    var basisEventIDs: [UUID]
    var isSatisfied: Bool

    init(
        ruleID: UUID,
        ruleRevisionID: UUID,
        metric: RewardMetric,
        achievedValue: Double,
        requiredValue: Double,
        detail: String = "",
        basisEventIDs: [UUID] = [],
        isSatisfied: Bool
    ) {
        self.ruleID = ruleID
        self.ruleRevisionID = ruleRevisionID
        self.metric = metric
        self.achievedValue = achievedValue
        self.requiredValue = requiredValue
        self.detail = detail
        self.basisEventIDs = basisEventIDs
        self.isSatisfied = isSatisfied
    }

    /// 进度比例；需求为 0 时返回 `nil`（不编造 100%）。
    var ratio: Double? {
        guard requiredValue > 0 else { return nil }
        return min(max(achievedValue / requiredValue, 0), 1)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ruleID = try container.decodeIfPresent(UUID.self, forKey: .ruleID) ?? UUID()
        ruleRevisionID = try container.decodeIfPresent(UUID.self, forKey: .ruleRevisionID) ?? UUID()
        let rawMetric = try container.decodeIfPresent(String.self, forKey: .metric)
            ?? RewardMetric.standardCompletedItemCount.rawValue
        metric = RewardMetric(rawValue: rawMetric) ?? .standardCompletedItemCount
        achievedValue = try container.decodeIfPresent(Double.self, forKey: .achievedValue) ?? 0
        requiredValue = try container.decodeIfPresent(Double.self, forKey: .requiredValue) ?? 0
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        basisEventIDs = try container.decodeIfPresent([UUID].self, forKey: .basisEventIDs) ?? []
        isSatisfied = try container.decodeIfPresent(Bool.self, forKey: .isSatisfied) ?? false
    }
}

// MARK: - 奖励发放

enum RewardGrantState: String, Codable, CaseIterable, Sendable {
    case pending
    case claimed
    case started
    case finished
    case expired
    case revoked

    var label: String {
        switch self {
        case .pending: return "待领取"
        case .claimed: return "已领取"
        case .started: return "已开始"
        case .finished: return "已结束"
        case .expired: return "已过期"
        case .revoked: return "已撤销"
        }
    }
}

struct RewardRevocation: Codable, Hashable, Sendable {
    var revokedAt: Date
    var reason: String

    init(revokedAt: Date, reason: String) {
        self.revokedAt = revokedAt
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt) ?? StudyTimestamp.unspecified
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// 奖励发放记录。
struct RewardGrant: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// 唯一发放键：同一学习日 + 同一规则版本只发一次。
    var grantKey: String
    var dayKey: StudyDayKey
    var ruleID: UUID
    var ruleRevisionID: UUID
    var ruleVersion: Int
    /// 发放当时的规则快照。
    var ruleSnapshot: EntertainmentRuleSnapshot
    /// 依据的完成事件 ID。
    var basisEventIDs: [UUID]
    var conditionProgress: RewardConditionProgress
    var grantedMinutes: Int
    var state: RewardGrantState
    var grantedAt: Date
    var claimedAt: Date?
    var startedAt: Date?
    var endedAt: Date?
    var usedMinutes: Int
    var revocation: RewardRevocation?

    init(
        id: UUID,
        grantKey: String,
        dayKey: StudyDayKey,
        ruleSnapshot: EntertainmentRuleSnapshot,
        basisEventIDs: [UUID] = [],
        conditionProgress: RewardConditionProgress,
        grantedMinutes: Int,
        state: RewardGrantState = .pending,
        grantedAt: Date,
        claimedAt: Date? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        usedMinutes: Int = 0,
        revocation: RewardRevocation? = nil
    ) {
        self.id = id
        self.grantKey = grantKey
        self.dayKey = dayKey
        self.ruleID = ruleSnapshot.ruleID
        self.ruleRevisionID = ruleSnapshot.revisionID
        self.ruleVersion = ruleSnapshot.ruleVersion
        self.ruleSnapshot = ruleSnapshot
        self.basisEventIDs = basisEventIDs
        self.conditionProgress = conditionProgress
        self.grantedMinutes = max(0, grantedMinutes)
        self.state = state
        self.grantedAt = grantedAt
        self.claimedAt = claimedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.usedMinutes = max(0, usedMinutes)
        self.revocation = revocation
    }

    var isRevoked: Bool { revocation != nil }

    /// 待领取，或领取后尚未开始、尚未消费的奖励。
    /// 只有这类奖励会因资格变化而撤销或跨日过期。
    var isUnstartedAndUnused: Bool {
        (state == .pending || state == .claimed)
            && startedAt == nil
            && usedMinutes == 0
    }

    /// 是否可领取。
    var isClaimable: Bool { state == .pending && !isRevoked }

    var remainingMinutes: Int { max(0, grantedMinutes - usedMinutes) }

    func claimed(at date: Date) -> RewardGrant? {
        guard isClaimable else { return nil }
        var copy = self
        copy.state = .claimed
        copy.claimedAt = date
        return copy
    }

    func started(at date: Date) -> RewardGrant? {
        guard !isRevoked, state == .claimed || state == .pending else { return nil }
        var copy = self
        copy.state = .started
        copy.startedAt = date
        if copy.claimedAt == nil { copy.claimedAt = date }
        return copy
    }

    func finished(at date: Date, usedMinutes: Int) -> RewardGrant? {
        guard !isRevoked, state == .started || state == .claimed else { return nil }
        var copy = self
        copy.state = .finished
        copy.endedAt = date
        copy.usedMinutes = min(max(0, usedMinutes), grantedMinutes)
        return copy
    }

    func revoked(at date: Date, reason: String) -> RewardGrant? {
        guard !isRevoked else { return nil }
        var copy = self
        copy.state = .revoked
        copy.revocation = RewardRevocation(revokedAt: date, reason: reason)
        return copy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        grantKey = try container.decodeIfPresent(String.self, forKey: .grantKey) ?? id.uuidString
        dayKey = try container.decodeIfPresent(StudyDayKey.self, forKey: .dayKey)
            ?? StudyDayKey(date: StudyTimestamp.unspecified, timeZone: TimeZone.current)
        ruleID = try container.decodeIfPresent(UUID.self, forKey: .ruleID) ?? UUID()
        ruleRevisionID = try container.decodeIfPresent(UUID.self, forKey: .ruleRevisionID) ?? ruleID
        ruleVersion = max(1, try container.decodeIfPresent(Int.self, forKey: .ruleVersion) ?? 1)
        ruleSnapshot = try container.decodeIfPresent(EntertainmentRuleSnapshot.self, forKey: .ruleSnapshot)
            ?? EntertainmentRuleSnapshot(
                ruleID: ruleID,
                name: "",
                condition: EntertainmentUnlockCondition(metric: .anyStudied, requiredValue: 1),
                fallback: .none,
                rewardMinutes: 0,
                ruleVersion: ruleVersion,
                revisionID: ruleRevisionID
            )
        basisEventIDs = try container.decodeIfPresent([UUID].self, forKey: .basisEventIDs) ?? []
        conditionProgress = try container.decodeIfPresent(RewardConditionProgress.self, forKey: .conditionProgress)
            ?? RewardConditionProgress(
                ruleID: ruleID,
                ruleRevisionID: ruleRevisionID,
                metric: ruleSnapshot.condition.metric,
                achievedValue: 0,
                requiredValue: ruleSnapshot.condition.requiredValue,
                isSatisfied: false
            )
        grantedMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .grantedMinutes) ?? 0)
        let rawState = try container.decodeIfPresent(String.self, forKey: .state) ?? RewardGrantState.pending.rawValue
        state = RewardGrantState(rawValue: rawState) ?? .pending
        grantedAt = try container.decodeIfPresent(Date.self, forKey: .grantedAt) ?? StudyTimestamp.unspecified
        claimedAt = try container.decodeIfPresent(Date.self, forKey: .claimedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        usedMinutes = max(0, try container.decodeIfPresent(Int.self, forKey: .usedMinutes) ?? 0)
        revocation = try container.decodeIfPresent(RewardRevocation.self, forKey: .revocation)
    }
}

extension RewardGrant {
    /// 唯一发放键构造规则：学习日 + 规则版本（revision）。
    ///
    /// 编辑规则会产生新的 `revisionID`，于是新版本可以再发一次；
    /// 而历史记录仍然指向旧 `revisionID`，不会被改写。
    enum Key {
        static func make(ruleRevisionID: UUID, dayKey: StudyDayKey) -> String {
            "reward|revision:\(ruleRevisionID.uuidString)|day:\(dayKey.localDateString)@\(dayKey.timeZoneIdentifier)"
        }
    }

    static func make(
        ruleSnapshot: EntertainmentRuleSnapshot,
        dayKey: StudyDayKey,
        basisEventIDs: [UUID],
        conditionProgress: RewardConditionProgress,
        grantedMinutes: Int,
        grantedAt: Date
    ) -> RewardGrant {
        let key = Key.make(ruleRevisionID: ruleSnapshot.revisionID, dayKey: dayKey)
        return RewardGrant(
            id: StudyStableKey.uuid(from: key),
            grantKey: key,
            dayKey: dayKey,
            ruleSnapshot: ruleSnapshot,
            basisEventIDs: basisEventIDs,
            conditionProgress: conditionProgress,
            grantedMinutes: grantedMinutes,
            state: .pending,
            grantedAt: grantedAt
        )
    }
}

// MARK: - StoreSnapshot 娱乐访问器

extension StoreSnapshot {
    func rewardGrant(grantKey: String) -> RewardGrant? {
        rewardGrants.first { $0.grantKey == grantKey }
    }

    func rewardGrant(id: UUID) -> RewardGrant? {
        rewardGrants.first { $0.id == id }
    }

    func hasRewardGrant(grantKey: String) -> Bool {
        rewardGrants.contains { $0.grantKey == grantKey }
    }

    /// 插入奖励发放（纯值操作）。
    ///
    /// 返回 `nil` 表示"重复发放，已忽略"。
    func insertingRewardGrant(_ grant: RewardGrant) -> StoreSnapshot? {
        guard !rewardGrants.contains(where: { $0.id == grant.id || $0.grantKey == grant.grantKey }) else {
            return nil
        }
        var copy = self
        copy.rewardGrants.append(grant)
        copy.rewardGrants.sort {
            if $0.dayKey != $1.dayKey { return $0.dayKey < $1.dayKey }
            return $0.grantedAt < $1.grantedAt
        }
        return copy
    }

    func entitlementRules(on dayKey: StudyDayKey) -> [EntertainmentRule] {
        entertainmentRules.filter { $0.isEffective(on: dayKey) }
    }

    func rewardGrants(on dayKey: StudyDayKey) -> [RewardGrant] {
        rewardGrants.filter { $0.dayKey == dayKey }
    }

    func pendingRewardGrants(on dayKey: StudyDayKey) -> [RewardGrant] {
        rewardGrants(on: dayKey).filter { $0.isClaimable }
    }

    /// 统一更新单条奖励记录；`transform` 返回 `nil` 表示状态不合法（重复领取等），
    /// 此时快照原样返回，不产生任何写入。
    private func updatingRewardGrant(
        id: UUID,
        transform: (RewardGrant) -> RewardGrant?
    ) -> StoreSnapshot? {
        guard let index = rewardGrants.firstIndex(where: { $0.id == id }) else { return nil }
        guard let updated = transform(rewardGrants[index]) else { return nil }
        var copy = self
        copy.rewardGrants[index] = updated
        return copy
    }

    /// 领取奖励。已领取过则返回 `nil`（重复领取不重复记录）。
    func claimingRewardGrant(id: UUID, at date: Date) -> StoreSnapshot? {
        updatingRewardGrant(id: id) { $0.claimed(at: date) }
    }

    func startingRewardGrant(id: UUID, at date: Date) -> StoreSnapshot? {
        updatingRewardGrant(id: id) { $0.started(at: date) }
    }

    func finishingRewardGrant(id: UUID, at date: Date, usedMinutes: Int) -> StoreSnapshot? {
        updatingRewardGrant(id: id) { $0.finished(at: date, usedMinutes: usedMinutes) }
    }

    func revokingRewardGrant(id: UUID, at date: Date, reason: String) -> StoreSnapshot? {
        updatingRewardGrant(id: id) { $0.revoked(at: date, reason: reason) }
    }
}
