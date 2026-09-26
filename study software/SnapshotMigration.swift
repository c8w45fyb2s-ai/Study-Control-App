import Foundation

// MARK: - Schema 迁移、隐私备份规则与工厂数据（模块 A）
//
// 迁移是**显式步骤列表**，不是"把版本号改成 5"：
// - 每一步声明 from → to、做了什么、以及"没有做什么"（例如不推算学习时长）。
// - 版本跨度没有对应步骤时返回明确错误，绝不静默通过。
// - 迁移只处理内存中的值类型，不写文件；写盘由 `SnapshotFileStore` 负责，
//   且只有全部步骤成功之后才会发生。

// MARK: - 错误

enum SnapshotMigrationError: LocalizedError {
    /// 磁盘上的版本比当前 App 支持的更新。
    case unsupportedVersionFound(found: Int, supported: Int)
    /// 没有从 `from` 到 `to` 的迁移路径。
    case noMigrationPath(from: Int, to: Int)
    case stepFailed(step: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersionFound(let found, let supported):
            return "数据版本 \(found) 高于当前 App 支持的版本 \(supported)，已停止加载以避免降级覆盖。请升级 App。"
        case .noMigrationPath(let from, let to):
            return "没有从数据版本 \(from) 到 \(to) 的迁移路径，已停止加载以避免覆盖原文件。"
        case .stepFailed(let step, let reason):
            return "迁移步骤「\(step)」失败：\(reason)。原文件未被修改。"
        }
    }
}

// MARK: - 迁移步骤

/// 一个显式迁移步骤。
struct MigrationStep {
    /// 步骤名（写入迁移报告与诊断记录）。
    let name: String
    /// 起始版本（含）。
    let from: Int
    /// 目标版本。
    let to: Int
    /// 该步骤做了什么 / 刻意没做什么。
    let notes: [String]
    let apply: (inout StoreSnapshot) -> Void
}

/// 迁移报告：让 G 能记录"这次加载到底改了哪些结构"。
struct MigrationReport: Hashable {
    var fromVersion: Int
    var toVersion: Int
    var appliedSteps: [String]
    var notes: [String]
    /// 是否产生了虚构记录（永远应为 `false`）。
    var didFabricateRecords: Bool

    var isNoOp: Bool { appliedSteps.isEmpty }
}

/// 迁移器。
enum SnapshotMigrator {
    /// 全部迁移步骤，按 `to` 升序。
    static var steps: [MigrationStep] {
        [legacyNormalizeStep, planningLayerStep, manualStudyTasksStep, manualTaskDueDateStep,
         activeRecallStep, documentEvidenceStep, durationCalibrationStep]
    }

    /// 新容器保持为空；旧任务与错题不冒充应用内作答。
    static var activeRecallStep: MigrationStep {
        MigrationStep(
            name: "active-recall-v7-to-v8",
            from: StudySchema.manualTaskDueDateVersion,
            to: StudySchema.activeRecallVersion,
            notes: ["增加卡片、独立作答与错题状态；旧记录保留，不推算作答、耗时或页码。"]
        ) { snapshot in
            snapshot.schemaVersion = StudySchema.activeRecallVersion
        }
    }

    static var documentEvidenceStep: MigrationStep {
        MigrationStep(name: "document-evidence-v8-to-v9", from: StudySchema.activeRecallVersion,
                      to: StudySchema.documentEvidenceVersion,
                      notes: ["增加逐页文本、分块与来源定位；旧资料不推测页码、OCR 或附件。"])
        { snapshot in snapshot.schemaVersion = StudySchema.documentEvidenceVersion }
    }

    static var durationCalibrationStep: MigrationStep {
        MigrationStep(name: "duration-calibration-v9-to-v10", from: StudySchema.documentEvidenceVersion,
                      to: StudySchema.durationCalibrationVersion,
                      notes: ["计划项可保存历史耗时解释和校准截点；旧计划保持原预计分钟，不补造耗时或解释。"])
        { snapshot in snapshot.schemaVersion = StudySchema.durationCalibrationVersion }
    }

    // MARK: 步骤 1：旧版本归一化（1...3 → 4）

    /// 旧版本快照归一化。
    ///
    /// 只做"清理与合并既有事实"，不新增任何业务记录：
    /// - 把旧的 `chatContextSummary` 合并进结构化记忆（幂等）；
    /// - 每日完成总数按日期去重，保留较大值；
    /// - 修正重复 ID 的复习任务（保留首个）。
    static var legacyNormalizeStep: MigrationStep {
        MigrationStep(
            name: "legacy-normalize-v1-to-v4",
            from: 1,
            to: StudySchema.legacyBaselineVersion,
            notes: [
                "旧版本快照归一化：合并旧长期摘要、按日期去重每日完成总数。",
                "刻意不生成任何计划任务、学习会话、完成事件或奖励记录。"
            ]
        ) { snapshot in
            snapshot.chatMemorySummary = snapshot.chatMemorySummary.mergedWithLegacySummary(snapshot.chatContextSummary)

            var seenDays = Set<String>()
            var dedupedDays: [DailyActivityRecord] = []
            for record in snapshot.dailyActivityRecords.sorted(by: { $0.dateString < $1.dateString }) {
                if seenDays.contains(record.dateString) {
                    if let index = dedupedDays.firstIndex(where: { $0.dateString == record.dateString }),
                       record.completedTaskCount > dedupedDays[index].completedTaskCount {
                        dedupedDays[index] = record
                    }
                    continue
                }
                seenDays.insert(record.dateString)
                dedupedDays.append(record)
            }
            snapshot.dailyActivityRecords = dedupedDays

            var seenTaskIDs = Set<UUID>()
            snapshot.reviewTasks = snapshot.reviewTasks.filter { seenTaskIDs.insert($0.id).inserted }

            // 完成事件 / 会话 / 奖励在旧版本不存在，保持为空。
            snapshot.completionEvents = []
            snapshot.studySessions = []
            snapshot.rewardGrants = []
            snapshot.schemaVersion = StudySchema.legacyBaselineVersion
        }
    }

    // MARK: 步骤 2：引入统一计划层（4 → 5）

    /// 引入统一计划层：补齐 schema 5 的容器与偏好默认值，并做结构去重。
    ///
    /// 关键约束（对应需求 8）：
    /// 旧版本只有"每日完成总数"，它**不能**被推算成学习时长、任务明细或娱乐资格，
    /// 因此本步骤刻意不创建任何 `CompletionEvent` / `StudySession` / `RewardGrant`，
    /// 也不填 `DailyStudySummary.recordedMinutes`。
    static var planningLayerStep: MigrationStep {
        MigrationStep(
            name: "planning-layer-v4-to-v5",
            from: StudySchema.legacyBaselineVersion,
            to: StudySchema.planningLayerVersion,
            notes: [
                "引入统一数据层：课表、可用时间偏好、每日计划、学习会话、完成事件、娱乐规则与奖励发放。",
                "每日完成总数原样保留；不从它推算学习时长、任务明细或娱乐资格。",
                "作息默认为「未配置」，默认学习窗口只作为计算假设出现，不写成用户已确认的设置。"
            ]
        ) { snapshot in
            snapshot.schemaVersion = StudySchema.planningLayerVersion

            // 规划时区：优先已配置值 → 学期时区 → 系统时区。
            if snapshot.planningPreferences.planningTimeZoneIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snapshot.planningPreferences.planningTimeZoneIdentifier =
                    snapshot.scheduleSemester?.timeZoneIdentifier ?? TimeZone.current.identifier
            }

            // 修复缺失幂等键的完成事件（补成其 id），保证重复检测始终有效。
            snapshot.completionEvents = snapshot.completionEvents.map { event in
                guard event.idempotencyKey.isEmpty else { return event }
                var fixed = event
                fixed.idempotencyKey = event.sessionID.map { CompletionEvent.Key.session($0) } ?? event.id.uuidString
                return fixed
            }

            snapshot.normalizePlanningLayer()
        }
    }

    /// 引入独立的持久化手动学习任务（5 → 6）。旧快照没有该集合，迁移时保持为空。
    static var manualStudyTasksStep: MigrationStep {
        MigrationStep(
            name: "manual-study-tasks-v5-to-v6",
            from: StudySchema.planningLayerVersion,
            to: StudySchema.manualStudyTasksVersion,
            notes: [
                "新增用户手动学习任务容器；旧数据不推导或生成手动任务。"
            ]
        ) { snapshot in
            snapshot.schemaVersion = StudySchema.manualStudyTasksVersion
            snapshot.normalizePlanningLayer()
        }
    }

    /// 手动任务到期日与输入范围（6 → 7）。旧安排日通过 `ManualStudyTask` 解码
    /// 映射为同一学习日的零点；不会从预计分钟推算实际学习时长。
    static var manualTaskDueDateStep: MigrationStep {
        MigrationStep(
            name: "manual-task-due-date-v6-to-v7",
            from: StudySchema.manualStudyTasksVersion,
            to: StudySchema.manualTaskDueDateVersion,
            notes: [
                "手动任务新增可选到期日；旧安排日迁为对应学习日的到期日。",
                "预计分钟保持为规划数据，不生成完成记录或实际学习时长。"
            ]
        ) { snapshot in
            snapshot.manualStudyTasks = snapshot.manualStudyTasks.map { task in
                ManualStudyTask(
                    id: task.id,
                    title: task.title,
                    note: task.note,
                    dueDate: task.dueDate,
                    estimatedMinutes: task.estimatedMinutes,
                    createdAt: task.createdAt
                )
            }
            for planIndex in snapshot.dailyPlans.indices {
                for itemIndex in snapshot.dailyPlans[planIndex].items.indices {
                    let item = snapshot.dailyPlans[planIndex].items[itemIndex]
                    if item.source.manualTaskID != nil && item.status == .pending {
                        snapshot.dailyPlans[planIndex].items[itemIndex].isPinned = false
                    }
                }
            }
            snapshot.schemaVersion = StudySchema.manualTaskDueDateVersion
            snapshot.normalizePlanningLayer()
        }
    }

    /// 迁移路径：把 `version` 逐级提升到 `target`。
    ///
    /// 找不到匹配步骤时返回 `nil`（调用方据此抛出明确错误），
    /// 不允许"直接跳到最新版本号"。
    static func path(from version: Int, to target: Int) -> [MigrationStep]? {
        guard version <= target else { return nil }
        var result: [MigrationStep] = []
        var current = version
        while current < target {
            guard let step = steps.first(where: { $0.from <= current && current < $0.to }) else { return nil }
            result.append(step)
            current = step.to
        }
        return result
    }

    /// 执行迁移（纯内存操作）。
    @discardableResult
    static func migrate(_ snapshot: inout StoreSnapshot) throws -> MigrationReport {
        let fromVersion = max(0, snapshot.schemaVersion)
        guard fromVersion <= StudySchema.currentVersion else {
            throw SnapshotMigrationError.unsupportedVersionFound(found: fromVersion, supported: StudySchema.currentVersion)
        }
        guard fromVersion >= StudySchema.minimumReadableVersion else {
            throw SnapshotMigrationError.noMigrationPath(from: fromVersion, to: StudySchema.currentVersion)
        }
        guard let steps = path(from: fromVersion, to: StudySchema.currentVersion) else {
            throw SnapshotMigrationError.noMigrationPath(from: fromVersion, to: StudySchema.currentVersion)
        }

        let beforeEventCount = snapshot.completionEvents.count
        var applied: [String] = []
        var notes: [String] = []
        for step in steps {
            step.apply(&snapshot)
            applied.append(step.name)
            notes.append(contentsOf: step.notes)
        }
        snapshot.schemaVersion = StudySchema.currentVersion

        let report = MigrationReport(
            fromVersion: fromVersion,
            toVersion: StudySchema.currentVersion,
            appliedSteps: applied,
            notes: notes,
            didFabricateRecords: snapshot.completionEvents.count > beforeEventCount
        )
        return report
    }

    /// 判断某个版本能否被当前 App 加载。
    static func canLoad(version: Int) -> Bool {
        version >= StudySchema.minimumReadableVersion && version <= StudySchema.currentVersion
    }
}

// MARK: - 计划层结构归一化

extension StoreSnapshot {
    /// 计划层结构去重与修复（幂等）。只整理结构，不新增业务记录。
    mutating func normalizePlanningLayer() {
        // 计划：按 id 去重；同一学习日只保留一个 active（版本号最大的胜出）。
        var seenPlanIDs = Set<UUID>()
        var plans = dailyPlans.filter { seenPlanIDs.insert($0.id).inserted }
        var activePlanByDay: [StudyDayKey: UUID] = [:]
        // 按版本号从高到低遍历：第一个遇到的版本占住 active，其余同日的 active 降级为 superseded。
        for plan in plans.sorted(by: { $0.version > $1.version }) where plan.isActive {
            guard activePlanByDay[plan.dayKey] == nil else {
                if let index = plans.firstIndex(where: { $0.id == plan.id }) {
                    plans[index].status = .superseded
                }
                continue
            }
            activePlanByDay[plan.dayKey] = plan.id
        }
        // 计划项：把孤儿项（planID 不存在）的 planID 指回其计划，不删除数据。
        plans = plans.map { plan in
            var copy = plan
            copy.items = plan.items.map { item in
                var fixed = item
                if fixed.planID != plan.id { fixed.planID = plan.id }
                return fixed
            }
            return copy
        }
        dailyPlans = plans.sorted {
            if $0.dayKey != $1.dayKey { return $0.dayKey < $1.dayKey }
            return $0.version < $1.version
        }

        // 会话：按 id 去重。
        var seenSessionIDs = Set<UUID>()
        studySessions = studySessions.filter { seenSessionIDs.insert($0.id).inserted }

        // 完成事件：按 id 与幂等键双重去重。
        var seenEventIDs = Set<UUID>()
        var seenEventKeys = Set<String>()
        completionEvents = completionEvents
            .filter { seenEventIDs.insert($0.id).inserted && seenEventKeys.insert($0.idempotencyKey).inserted }
            .sorted { $0.completedAt < $1.completedAt }

        // 娱乐规则：同一 id 只保留版本最高的一份；revisionID 去重。
        var latestRuleByID: [UUID: EntertainmentRule] = [:]
        for rule in entertainmentRules {
            if let existing = latestRuleByID[rule.id] {
                if rule.ruleVersion > existing.ruleVersion { latestRuleByID[rule.id] = rule }
            } else {
                latestRuleByID[rule.id] = rule
            }
        }
        var seenRevisions = Set<UUID>()
        entertainmentRules = latestRuleByID.values
            .filter { seenRevisions.insert($0.revisionID).inserted }
            .sorted { $0.createdAt < $1.createdAt }

        // 奖励发放：按 id 与唯一发放键双重去重。
        var seenGrantIDs = Set<UUID>()
        var seenGrantKeys = Set<String>()
        rewardGrants = rewardGrants
            .filter { seenGrantIDs.insert($0.id).inserted && seenGrantKeys.insert($0.grantKey).inserted }
            .sorted {
                if $0.dayKey != $1.dayKey { return $0.dayKey < $1.dayKey }
                return $0.grantedAt < $1.grantedAt
            }

        // 课程负担旁表：同一课程只保留一条。
        var seenBurdenCourseIDs = Set<UUID>()
        courseBurdenLevels = courseBurdenLevels.filter { seenBurdenCourseIDs.insert($0.courseID).inserted }

        // 课表：课程/例外/节次按 id 去重。
        var seenCourseIDs = Set<UUID>()
        scheduleCourses = scheduleCourses.filter { seenCourseIDs.insert($0.id).inserted }
        var seenExceptionIDs = Set<UUID>()
        scheduleExceptions = scheduleExceptions.filter { seenExceptionIDs.insert($0.id).inserted }
        var seenTemplateIDs = Set<UUID>()
        schedulePeriodTemplates = schedulePeriodTemplates.filter { seenTemplateIDs.insert($0.id).inserted }

        // 手动任务按 id 去重；无到期日的立即任务排在有期限任务前。
        var seenManualTaskIDs = Set<UUID>()
        manualStudyTasks = manualStudyTasks.map { task in
            ManualStudyTask(
                id: task.id,
                title: task.title,
                note: task.note,
                dueDate: task.dueDate,
                estimatedMinutes: task.estimatedMinutes,
                createdAt: task.createdAt
            )
        }
        manualStudyTasks = manualStudyTasks
            .filter { seenManualTaskIDs.insert($0.id).inserted }
            .sorted(by: ManualStudyTask.precedesInCandidateOrder)
    }
}

// MARK: - 隐私备份规则

/// 隐私备份脱敏说明。
struct PrivacyRedactionSummary: Hashable {
    var clearedDocumentContents: Int = 0
    var clearedDiagnosticEvents: Int = 0
    var clearedCourseLocations: Int = 0
    var clearedCourseNotes: Int = 0
    var clearedExceptionNotes: Int = 0
    var clearedStudyNotes: Int = 0
    var clearedManualSourceNotes: Int = 0
    var clearedManualTaskTitles: Int = 0
    var keptFieldNotes: [String] = []

    var totalClearedFields: Int {
        clearedDocumentContents + clearedDiagnosticEvents + clearedCourseLocations
            + clearedCourseNotes + clearedExceptionNotes + clearedStudyNotes + clearedManualSourceNotes
            + clearedManualTaskTitles
    }
}

/// 隐私备份脱敏规则。
///
/// 覆盖范围：
/// - 既有：导入资料正文、诊断记录；
/// - schema 5/6 新增：课程地点/教师/备注、排课例外备注与替换地点、
///   计划项与学习会话与完成事件的自由文本、手动任务标题与来源说明。
///
/// 刻意保留：学习窗口与睡眠时间（恢复计划必需、且不含身份信息）、
/// 学科/课程名称（隐私备份的意义就是"结构可恢复"）。这些保留项会在
/// `keptFieldNotes` 中显式列出，避免"以为已经脱敏"。
enum SnapshotPrivacyRedactor {
    static let placeholder = "隐私导出已省略。"

    static func redact(_ snapshot: StoreSnapshot) -> (snapshot: StoreSnapshot, summary: PrivacyRedactionSummary) {
        var copy = snapshot
        var summary = PrivacyRedactionSummary()

        summary.clearedDiagnosticEvents = copy.diagnosticEvents.count
        copy.diagnosticEvents = []

        summary.clearedDocumentContents = copy.documents.filter { !$0.content.isEmpty }.count
        copy.documents = copy.documents.map { document in
            var redacted = document
            redacted.content = placeholder
            redacted.pages = document.pages.map { page in
                var item = page
                item.text = page.text.isEmpty ? "" : placeholder
                item.failureReason = nil
                return item
            }
            redacted.chunks = document.chunks.map { chunk in
                var item = chunk
                item.text = placeholder
                item.chapterTitle = chunk.chapterTitle.map { _ in placeholder }
                return item
            }
            redacted.originalPDFFileName = nil
            redacted.backupPDFData = nil
            return redacted
        }
        copy.knowledgePoints = copy.knowledgePoints.map { point in
            var item = point
            if item.sourceReference != nil { item.sourceReference?.excerpt = placeholder }
            return item
        }
        copy.mistakes = copy.mistakes.map { mistake in
            var item = mistake
            if item.sourceReference != nil { item.sourceReference?.excerpt = placeholder }
            return item
        }
        copy.chatMessages = copy.chatMessages.map { message in
            var item = message
            item.citations = message.citations.map { citation in
                var copyCitation = citation
                copyCitation.excerpt = placeholder
                if copyCitation.sourceReference != nil { copyCitation.sourceReference?.excerpt = placeholder }
                return copyCitation
            }
            return item
        }
        copy.studyCards = copy.studyCards.map { card in
            var redacted = card
            redacted.prompt = placeholder
            redacted.answer = placeholder
            redacted.sourceExcerpt = card.sourceExcerpt.map { _ in placeholder }
            if redacted.sourceReference != nil { redacted.sourceReference?.excerpt = placeholder }
            return redacted
        }
        copy.reviewAttempts = copy.reviewAttempts.map { attempt in
            var redacted = attempt
            redacted.answer = attempt.answer.map { _ in placeholder }
            redacted.priorReviewTask?.title = placeholder
            return redacted
        }

        summary.clearedCourseLocations = copy.scheduleCourses.filter { !$0.location.isEmpty }.count
        summary.clearedCourseNotes = copy.scheduleCourses.filter { !$0.note.isEmpty || !$0.teacher.isEmpty }.count
        copy.scheduleCourses = copy.scheduleCourses.map { course in
            var redacted = course
            redacted.location = course.location.isEmpty ? course.location : placeholder
            redacted.teacher = course.teacher.isEmpty ? course.teacher : placeholder
            redacted.note = course.note.isEmpty ? course.note : placeholder
            return redacted
        }

        summary.clearedExceptionNotes = copy.scheduleExceptions.filter {
            !$0.note.isEmpty || !($0.replacementLocation ?? "").isEmpty
        }.count
        copy.scheduleExceptions = copy.scheduleExceptions.map { exception in
            var redacted = exception
            redacted.note = exception.note.isEmpty ? exception.note : placeholder
            redacted.replacementLocation = (exception.replacementLocation ?? "").isEmpty
                ? exception.replacementLocation
                : placeholder
            return redacted
        }

        // 用户创建的任务标题可能包含私人信息。把标题的所有已知副本收集起来，
        // 以便同时清除计划解释里自动生成的预览文本。
        var manualTaskTitles = Set(copy.manualStudyTasks.map(\.title).filter { !$0.isEmpty })
        for plan in copy.dailyPlans {
            manualTaskTitles.formUnion(plan.items
                .filter { $0.source.kind == .manual && !$0.title.isEmpty }
                .map(\.title))
            manualTaskTitles.formUnion(plan.unplaceable
                .filter { $0.source.kind == .manual && !$0.title.isEmpty }
                .map(\.title))
        }
        let orderedManualTitles = manualTaskTitles.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0 < $1
        }
        func redactManualTitles(in value: String) -> String {
            orderedManualTitles.reduce(value) { text, title in
                text.replacingOccurrences(of: title, with: placeholder)
            }
        }

        summary.clearedManualSourceNotes = copy.dailyPlans
            .flatMap(\.items)
            .filter { !($0.source.manualNote ?? "").isEmpty }
            .count
        summary.clearedManualSourceNotes += copy.dailyPlans
            .flatMap(\.unplaceable)
            .filter { !($0.source.manualNote ?? "").isEmpty }
            .count
        copy.dailyPlans = copy.dailyPlans.map { plan in
            var redacted = plan
            redacted.items = plan.items.map { item in
                var copyItem = item
                copyItem.note = item.note.isEmpty ? item.note : placeholder
                if (item.source.manualNote ?? "").isEmpty == false {
                    copyItem.source.manualNote = placeholder
                }
                if item.source.kind == .manual && !item.title.isEmpty {
                    copyItem.title = placeholder
                    summary.clearedManualTaskTitles += 1
                }
                return copyItem
            }
            redacted.unplaceable = plan.unplaceable.map { item in
                var copyItem = item
                if (item.source.manualNote ?? "").isEmpty == false {
                    copyItem.source.manualNote = placeholder
                }
                if item.source.kind == .manual && !item.title.isEmpty {
                    copyItem.title = placeholder
                    summary.clearedManualTaskTitles += 1
                }
                let detail = redactManualTitles(in: item.detail)
                if detail != item.detail {
                    copyItem.detail = detail
                    summary.clearedManualTaskTitles += 1
                }
                return copyItem
            }
            redacted.explanation.lines = plan.explanation.lines.map { line in
                let value = redactManualTitles(in: line)
                if value != line { summary.clearedManualTaskTitles += 1 }
                return value
            }
            redacted.explanation.assumptions = plan.explanation.assumptions.map { line in
                let value = redactManualTitles(in: line)
                if value != line { summary.clearedManualTaskTitles += 1 }
                return value
            }
            redacted.explanation.blockedReasons = plan.explanation.blockedReasons.map { line in
                let value = redactManualTitles(in: line)
                if value != line { summary.clearedManualTaskTitles += 1 }
                return value
            }
            return redacted
        }

        summary.clearedManualSourceNotes += copy.manualStudyTasks.filter { !$0.note.isEmpty }.count
        copy.manualStudyTasks = copy.manualStudyTasks.map { task in
            var redacted = task
            redacted.note = task.note.isEmpty ? task.note : placeholder
            if !task.title.isEmpty {
                redacted.title = placeholder
                summary.clearedManualTaskTitles += 1
            }
            return redacted
        }

        summary.clearedStudyNotes = copy.studySessions.filter { !$0.note.isEmpty }.count
        copy.studySessions = copy.studySessions.map { session in
            var redacted = session
            redacted.note = session.note.isEmpty ? session.note : placeholder
            redacted.abandonmentReason = (session.abandonmentReason ?? "").isEmpty
                ? session.abandonmentReason
                : placeholder
            return redacted
        }

        summary.clearedStudyNotes += copy.completionEvents.filter { !$0.note.isEmpty }.count
        summary.clearedManualSourceNotes += copy.completionEvents
            .filter { !($0.source?.manualNote ?? "").isEmpty }
            .count
        copy.completionEvents = copy.completionEvents.map { event in
            var redacted = event
            redacted.note = event.note.isEmpty ? event.note : placeholder
            if (event.source?.manualNote ?? "").isEmpty == false {
                redacted.source?.manualNote = placeholder
            }
            return redacted
        }

        summary.keptFieldNotes = [
            "保留学习窗口与睡眠时间：恢复计划所必需，且不含身份信息。",
            "保留课程/学科名称与时间：隐私备份仍应可恢复课表结构。",
            "保留完成事件与奖励记录：否则恢复后无法核对学习与奖励一致性。"
        ]

        return (copy, summary)
    }
}
