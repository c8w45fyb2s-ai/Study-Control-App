import Foundation

// MARK: - 候选任务构建（模块 C：今日任务自动规划）
//
// 职责：把真实数据整理成"可以进入排程的候选任务"，并在进入排程前完成：
//   1. 收集：到期复习、逾期复习、考试相关复习、课程回顾、次日预习、用户手动任务；
//   2. 每条候选必须带稳定来源、预计耗时与可执行内容（内容只能来自真实数据）；
//   3. 同一任务不因"既属于错题、又是考试重点"这类多路径重复入选；
//   4. 当天已完成的当前复习实例不再进入今日清单；
//   5. 没有资料时只允许使用明确的通用任务模板（不编造章节、题号、知识点）；
//   6. 没有候选就返回空集合 —— 绝不为凑预算造任务。
//
// 纯计算：不读时钟、不读写文件、不发通知、不改全局状态。
// 所有时间判断都通过外部传入的 `PlanningContext` 与 `StudyDayKey` 完成。

// MARK: - 通用任务模板

/// 通用任务模板：**没有真实资料时唯一允许使用的内容描述**。
///
/// 模板只描述"做什么类型的事"，不包含章节号、题号、知识点名称。
enum GenericTaskTemplate: String, Codable, CaseIterable, Sendable {
    case dueReview
    case courseRecall
    case lessonPreview
    case consolidation

    var title: String {
        switch self {
        case .dueReview: return "复习到期内容"
        case .courseRecall: return "回顾今天的课程内容"
        case .lessonPreview: return "预习下一节课"
        case .consolidation: return "巩固练习"
        }
    }

    /// 通用模板的量纲：只记"1 个任务"，不声称具体节数或题量。
    var scope: StudyScope { .tasks(1) }

    static func template(for kind: DailyPlanItemSourceKind) -> GenericTaskTemplate {
        switch kind {
        case .reviewTask: return .dueReview
        case .courseReview: return .courseRecall
        case .preview: return .lessonPreview
        case .manual: return .consolidation
        }
    }
}

// MARK: - 科目匹配（考试临近判定）

/// 科目名称匹配。
///
/// `KnowledgePoint.subject`、`SubjectRef.displayName`、`ExamGoal.subjects`
/// 都是自由文本，没有稳定的科目 ID 可用，因此这里是**显式的文本启发式**，
/// 用于把复习任务与考试目标关联起来；匹配不到就不升级优先级，
/// 绝不编造"这就是考试重点"的结论。
enum StudySubjectMatcher {
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        return cleaned.isEmpty ? nil : cleaned
    }

    static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalized(lhs), let rhs = normalized(rhs) else { return false }
        if lhs == rhs { return true }
        // 仅在两边都足够长时做包含匹配，避免"数学"命中"高等数学"以外的噪声。
        guard lhs.count >= 2, rhs.count >= 2 else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }
}

// MARK: - 候选信号

/// 候选任务的排程信号：只包含"真实数据里读到的信息"，不含推测内容。
struct TaskSignals: Hashable, Sendable {
    /// 稳定身份键（同一任务在多条路径下必须相同）。
    var identityKey: String
    /// 关联到的错题 / 知识点；用于"同一任务不重复入选"。
    var linkedMistakeID: UUID?
    var linkedKnowledgePointID: UUID?
    /// 任务到期日期（与安排日期无关）。
    var dueDate: Date?
    /// 逾期天数（到期日在今天之前；0 表示今天到期，负数表示还没到期）。
    var overdueDays: Int
    /// 距离到期的天数（今天到期 = 0；`nil` 表示没有到期日）。
    var dueWithinDays: Int?
    /// 用户/系统给出的优先级。
    var priority: Int?
    /// 掌握度 0...1（来自知识点）。
    var mastery: Double?
    var subjectName: String?
    /// SM-2 状态，用于估计遗忘风险。
    var reviewIntervalDays: Int?
    var repetitionCount: Int?
    var lastQuality: Int?
    /// 最近的、科目匹配的考试。
    var nearestExamName: String?
    var examDaysRemaining: Int?
    var matchesExamSubject: Bool
    /// 课程负担等级（B 模块旁表）。
    var courseBurdenLevel: CourseBurdenLevel?
    /// 是否存在真实资料（课程资料 / 真实复习任务 / 真实课程实例）。
    var hasRealMaterial: Bool
    /// 课程是否真的有资料（文档 / 知识点）。没有资料时只能排通用回顾任务。
    var hasCourseMaterials: Bool
    var isManual: Bool
    /// 用户已在既有计划中固定这条任务。
    var isPinned: Bool
}

// MARK: - 信号索引

/// 只读信号索引：把快照里的真实数据整理成按 ID 查询的映射。
///
/// 手工去重而不是 `Dictionary(uniqueKeysWithValues:)`：解码来的数据可能含重复
/// ID，那种情况下必须降级而不是崩溃（与 A 模块的旁表读取口径一致）。
struct TaskSignalIndex {
    var reviewTasksByID: [UUID: ReviewTask]
    var knowledgePointsByID: [UUID: KnowledgePoint]
    var mistakesByID: [UUID: Mistake]
    var courseBurdenByCourseID: [UUID: CourseBurdenLevel]
    /// 课程是否有真实资料（文档/知识点）。缺失视为"没有资料"。
    var courseHasMaterials: [UUID: Bool]
    /// 课程 → 科目名称（用于与考试目标匹配）。
    var courseSubjectNames: [UUID: String]
    var examGoals: [ExamGoal]

    init(
        reviewTasks: [ReviewTask] = [],
        knowledgePoints: [KnowledgePoint] = [],
        mistakes: [Mistake] = [],
        examGoals: [ExamGoal] = [],
        courseBurdenByCourseID: [UUID: CourseBurdenLevel] = [:],
        courseHasMaterials: [UUID: Bool] = [:],
        courseSubjectNames: [UUID: String] = [:]
    ) {
        var reviewMap: [UUID: ReviewTask] = [:]
        for task in reviewTasks where reviewMap[task.id] == nil { reviewMap[task.id] = task }
        var knowledgeMap: [UUID: KnowledgePoint] = [:]
        for point in knowledgePoints where knowledgeMap[point.id] == nil { knowledgeMap[point.id] = point }
        var mistakeMap: [UUID: Mistake] = [:]
        for mistake in mistakes where mistakeMap[mistake.id] == nil { mistakeMap[mistake.id] = mistake }

        self.reviewTasksByID = reviewMap
        self.knowledgePointsByID = knowledgeMap
        self.mistakesByID = mistakeMap
        self.courseBurdenByCourseID = courseBurdenByCourseID
        self.courseHasMaterials = courseHasMaterials
        self.courseSubjectNames = courseSubjectNames
        self.examGoals = examGoals
    }

    /// 从快照构建索引。只读：不修改传入的快照。
    init(
        snapshot: StoreSnapshot,
        courseHasMaterials: [UUID: Bool] = [:]
    ) {
        var subjectNames: [UUID: String] = [:]
        for course in snapshot.scheduleCourses where subjectNames[course.id] == nil {
            subjectNames[course.id] = course.subject.linkedKnowledgeSubject ?? course.subject.displayName
        }
        self.init(
            reviewTasks: snapshot.reviewTasks,
            knowledgePoints: snapshot.knowledgePoints,
            mistakes: snapshot.mistakes,
            examGoals: snapshot.examGoals,
            courseBurdenByCourseID: snapshot.courseBurdenMap,
            courseHasMaterials: courseHasMaterials,
            courseSubjectNames: subjectNames
        )
    }

    static let empty = TaskSignalIndex()

    // MARK: 考试

    /// 与给定科目匹配的最近考试（只看未归档且尚未结束的考试）。
    func nearestExam(matching subjectName: String?, dayKey: StudyDayKey, context: PlanningContext) -> (goal: ExamGoal, daysRemaining: Int)? {
        guard StudySubjectMatcher.normalized(subjectName) != nil else { return nil }
        guard let dayStart = dayKey.startOfDay(calendar: context.calendar) else { return nil }
        return examGoals
            .filter { !$0.isArchived }
            .compactMap { goal -> (ExamGoal, Int)? in
                guard goal.subjects.contains(where: { StudySubjectMatcher.matches($0, subjectName) }) else { return nil }
                let examStart = context.calendar.startOfDay(for: goal.examDate)
                let days = context.calendar.dateComponents([.day], from: dayStart, to: examStart).day ?? 0
                guard days >= 0 else { return nil }
                return (goal, days)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.id.uuidString < rhs.0.id.uuidString
            }
            .first
    }

    // MARK: 信号

    func signals(
        for candidate: PlanCandidate,
        dayKey: StudyDayKey,
        context: PlanningContext,
        existingActivePlan: DailyStudyPlan?
    ) -> TaskSignals {
        let source = candidate.source
        let reviewTask = source.reviewTaskID.flatMap { reviewTasksByID[$0] }
        let knowledgePointID = source.knowledgePointID ?? reviewTask?.knowledgePointID
        let knowledgePoint = knowledgePointID.flatMap { knowledgePointsByID[$0] }
        let mistakeID = reviewTask?.mistakeID
        let identityKey = TaskIdentity.key(for: candidate, reviewTask: reviewTask)

        // 到期 / 逾期
        let dayStart = dayKey.startOfDay(calendar: context.calendar)
        var overdueDays = 0
        var dueWithinDays: Int?
        if let dueDate = candidate.dueDate ?? reviewTask?.dueDate, let dayStart {
            let dueStart = context.calendar.startOfDay(for: dueDate)
            let days = context.calendar.dateComponents([.day], from: dayStart, to: dueStart).day ?? 0
            if days < 0 {
                overdueDays = -days
            } else {
                dueWithinDays = days
            }
        }

        // 科目
        let subjectName: String?
        switch source.kind {
        case .reviewTask:
            subjectName = knowledgePoint?.subject
        case .courseReview, .preview:
            subjectName = source.courseID.flatMap { courseSubjectNames[$0] }
        case .manual:
            subjectName = knowledgePoint?.subject
        }

        // 考试临近
        let exam = nearestExam(matching: subjectName, dayKey: dayKey, context: context)

        // 资料 / 固定
        let hasRealMaterial: Bool
        switch source.kind {
        case .reviewTask:
            hasRealMaterial = reviewTask != nil
                || knowledgePoint != nil
                || mistakeID != nil
                || !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .courseReview, .preview:
            let courseID = source.courseID
            let explicitlyKnown = courseID.flatMap { courseHasMaterials[$0] } ?? false
            // 课程实例本身就是真实事件，因此"有课"即允许生成通用回顾任务；
            // 但只有存在真实资料时才允许声明具体章节范围（由 builder 处理量纲）。
            hasRealMaterial = explicitlyKnown || source.occurrenceID != nil || courseID != nil
        case .manual:
            let note = (source.manualNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            hasRealMaterial = !note.isEmpty || !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let hasCourseMaterials: Bool
        switch source.kind {
        case .courseReview, .preview:
            hasCourseMaterials = source.courseID.flatMap { courseHasMaterials[$0] } ?? false
        case .reviewTask, .manual:
            hasCourseMaterials = false
        }

        let existingItem = existingActivePlan?.items.first { $0.source == source }

        return TaskSignals(
            identityKey: identityKey,
            linkedMistakeID: mistakeID,
            linkedKnowledgePointID: knowledgePointID,
            dueDate: candidate.dueDate ?? reviewTask?.dueDate,
            overdueDays: overdueDays,
            dueWithinDays: dueWithinDays,
            priority: reviewTask?.priority,
            mastery: knowledgePoint?.mastery,
            subjectName: subjectName,
            reviewIntervalDays: reviewTask?.intervalDays,
            repetitionCount: reviewTask?.repetitionCount,
            lastQuality: reviewTask?.lastQuality,
            nearestExamName: exam?.goal.name,
            examDaysRemaining: exam?.daysRemaining,
            matchesExamSubject: exam != nil,
            courseBurdenLevel: source.courseID.flatMap { courseBurdenByCourseID[$0] },
            hasRealMaterial: hasRealMaterial,
            hasCourseMaterials: hasCourseMaterials,
            isManual: source.kind == .manual,
            isPinned: existingItem?.isPinned ?? candidate.isPinned
        )
    }
}

// MARK: - 稳定身份

/// 任务身份：同一条任务在多次生成、多条路径下必须得到同一把键。
enum TaskIdentity {
    static func key(for candidate: PlanCandidate, reviewTask: ReviewTask?) -> String {
        let source = candidate.source
        switch source.kind {
        case .reviewTask:
            if let id = source.reviewTaskID { return "review|\(id.uuidString)" }
            let point = source.knowledgePointID?.uuidString ?? "-"
            return "review|kp:\(point)|title:\(normalizedTitleText(candidate.title))"
        case .courseReview:
            return "course-review|\(source.courseID?.uuidString ?? "-")|\(source.occurrenceID?.uuidString ?? "-")"
        case .preview:
            return "preview|\(source.courseID?.uuidString ?? "-")|\(source.occurrenceID?.uuidString ?? "-")"
        case .manual:
            if let manualTaskID = source.manualTaskID {
                return "manual-task|\(manualTaskID.uuidString)"
            }
            return "manual|\(normalizedTitleText(candidate.title))|\(source.manualNote ?? "")"
        }
    }

    static func itemKey(dayKey: StudyDayKey, identityKey: String) -> String {
        "plan-item|\(dayKey.localDateString)@\(dayKey.timeZoneIdentifier)|\(identityKey)"
    }

    private static func normalizedTitleText(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - 排除说明

enum TaskCandidateExclusionReason: String, Codable, CaseIterable, Sendable {
    /// 同一任务已通过另一条路径入选（错题 / 考试重点 / 同一知识点）。
    case duplicateOfSameObject
    /// 当天已经完成过这个复习实例。
    case completedToday
    /// 引用的复习任务 / 课程已经不存在（来源断裂）。
    case missingSourceData
    /// 没有标题也没有可执行范围 —— 不允许编造内容。
    case emptyContent

    var label: String {
        switch self {
        case .duplicateOfSameObject: return "与已入选任务指向同一对象"
        case .completedToday: return "今天已完成"
        case .missingSourceData: return "来源数据缺失"
        case .emptyContent: return "没有可执行内容"
        }
    }
}

struct TaskCandidateExclusion: Identifiable, Hashable, Sendable {
    var id: UUID
    var identityKey: String
    var title: String
    var source: DailyPlanItemSource
    var reason: TaskCandidateExclusionReason
    var detail: String
}

// MARK: - 候选

/// 进入排程的候选任务。
struct TaskCandidate: Identifiable, Hashable {
    /// 由身份键派生的稳定 ID（重复生成不会产生"新任务"）。
    var id: UUID
    var identityKey: String
    var candidate: PlanCandidate
    var signals: TaskSignals
    /// 已按"不编造内容"规则规范化的标题。
    var title: String
    /// 规范化后的计划范围（没有资料时不声称具体节数）。
    var plannedScope: StudyScope
    var minimumScope: StudyScope?
    /// 原始预计耗时（最终耗时由 `TaskDurationEstimator` 结合偏好计算）。
    var estimatedMinutes: Int
    /// 这条候选是否已经存在于当前生效计划里。
    var isAlreadyInActivePlan: Bool
    var existingItemID: UUID?
}

/// 候选构建结果。
struct TaskCandidateSet {
    var candidates: [TaskCandidate]
    var exclusions: [TaskCandidateExclusion]

    static let empty = TaskCandidateSet(candidates: [], exclusions: [])
}

/// 候选构建输入。
struct TaskCandidateInput {
    var dayKey: StudyDayKey
    var context: PlanningContext
    /// 真实候选（复习任务 / 课程回顾 / 预习 / 手动任务），由 G 从快照翻译而来。
    var rawCandidates: [PlanCandidate]
    var existingPlans: [DailyStudyPlan]
    var completions: [CompletionEvent]
    var signalIndex: TaskSignalIndex

    init(
        dayKey: StudyDayKey,
        context: PlanningContext,
        rawCandidates: [PlanCandidate],
        existingPlans: [DailyStudyPlan] = [],
        completions: [CompletionEvent] = [],
        signalIndex: TaskSignalIndex = .empty
    ) {
        self.dayKey = dayKey
        self.context = context
        self.rawCandidates = rawCandidates
        self.existingPlans = existingPlans
        self.completions = completions
        self.signalIndex = signalIndex
    }

    var activePlan: DailyStudyPlan? {
        existingPlans.first { $0.dayKey == dayKey && $0.isActive }
    }
}

// MARK: - Builder

enum TaskCandidateBuilder {

    /// 构建候选集合：去重 → 排除已完成 / 无来源 / 空内容 → 规范化标题与范围。
    ///
    /// 输出顺序只取决于输入内容本身（按身份键升序），与传入顺序无关，
    /// 因此"相同输入重复生成"得到完全一致的结果。
    static func build(_ input: TaskCandidateInput) -> TaskCandidateSet {
        let activePlan = input.activePlan
        var exclusions: [TaskCandidateExclusion] = []
        var prepared: [TaskCandidate] = []

        // 只有在索引里确实有复习任务数据时才做"引用是否断裂"的判定。
        // 否则（索引未接入）会把正常候选误判成来源缺失，静默丢掉真实任务。
        let validatesReviewTasks = !input.signalIndex.reviewTasksByID.isEmpty

        for raw in input.rawCandidates {
            let signals = input.signalIndex.signals(
                for: raw,
                dayKey: input.dayKey,
                context: input.context,
                existingActivePlan: activePlan
            )
            let identityKey = signals.identityKey
            let title = normalizedTitle(for: raw, signals: signals)

            // 来源断裂：引用了不存在的复习任务。
            if validatesReviewTasks,
               raw.source.kind == .reviewTask,
               let reviewTaskID = raw.source.reviewTaskID,
               input.signalIndex.reviewTasksByID[reviewTaskID] == nil {
                exclusions.append(exclusion(
                    identityKey: identityKey,
                    title: title,
                    source: raw.source,
                    reason: .missingSourceData,
                    detail: "找不到关联的复习任务，已跳过（不编造内容）。"
                ))
                continue
            }

            // 课程回顾 / 预习必须有真实课程或课程实例关联。
            if raw.source.kind.requiresRealCourse,
               raw.source.courseID == nil,
               raw.source.occurrenceID == nil {
                exclusions.append(exclusion(
                    identityKey: identityKey,
                    title: title,
                    source: raw.source,
                    reason: .missingSourceData,
                    detail: "缺少课程实例关联，已跳过。"
                ))
                continue
            }

            let scope = normalizedScope(for: raw, signals: signals)
            if title.isEmpty || scope.isZero {
                exclusions.append(exclusion(
                    identityKey: identityKey,
                    title: title,
                    source: raw.source,
                    reason: .emptyContent,
                    detail: "标题与范围都为空，已跳过（不为凑预算造任务）。"
                ))
                continue
            }

            // 规则 4：已完成的当前复习实例不再进入今日清单。
            if isCompletedToday(
                raw: raw,
                signals: signals,
                reviewTask: raw.source.reviewTaskID.flatMap { input.signalIndex.reviewTasksByID[$0] },
                dayKey: input.dayKey,
                existingPlans: input.existingPlans,
                completions: input.completions
            ) {
                exclusions.append(exclusion(
                    identityKey: identityKey,
                    title: title,
                    source: raw.source,
                    reason: .completedToday,
                    detail: "今天已经完成过这个复习实例，不再重复排入。"
                ))
                continue
            }

            let existingItem = activePlan?.items.first { $0.source == raw.source }
            prepared.append(
                TaskCandidate(
                    id: StudyStableKey.uuid(from: identityKey),
                    identityKey: identityKey,
                    candidate: raw,
                    signals: signals,
                    title: title,
                    plannedScope: scope,
                    minimumScope: raw.minimumScope,
                    estimatedMinutes: max(0, raw.estimatedMinutes),
                    isAlreadyInActivePlan: existingItem != nil,
                    existingItemID: existingItem?.id
                )
            )
        }

        // 规则 3：同一对象只保留一条。排序键保证"保留哪一条"与输入顺序无关。
        let ordered = prepared.sorted { lhs, rhs in
            if sortRank(lhs) != sortRank(rhs) { return sortRank(lhs) < sortRank(rhs) }
            return lhs.identityKey < rhs.identityKey
        }

        var seenIdentity: Set<String> = []
        var seenMistake: Set<UUID> = []
        var seenKnowledge: Set<UUID> = []
        var kept: [TaskCandidate] = []

        for candidate in ordered {
            if seenIdentity.contains(candidate.identityKey) {
                exclusions.append(exclusion(
                    identityKey: candidate.identityKey,
                    title: candidate.title,
                    source: candidate.candidate.source,
                    reason: .duplicateOfSameObject,
                    detail: "同一任务重复出现，只保留一条。"
                ))
                continue
            }

            // 只有"复习任务"之间才按错题 / 知识点合并；
            // 用户手动任务和课程任务各自独立，不会被复习任务吞掉。
            if candidate.candidate.source.kind == .reviewTask {
                if let mistakeID = candidate.signals.linkedMistakeID, seenMistake.contains(mistakeID) {
                    exclusions.append(exclusion(
                        identityKey: candidate.identityKey,
                        title: candidate.title,
                        source: candidate.candidate.source,
                        reason: .duplicateOfSameObject,
                        detail: "与已入选任务指向同一道错题，只保留一条。"
                    ))
                    continue
                }
                if let pointID = candidate.signals.linkedKnowledgePointID, seenKnowledge.contains(pointID) {
                    exclusions.append(exclusion(
                        identityKey: candidate.identityKey,
                        title: candidate.title,
                        source: candidate.candidate.source,
                        reason: .duplicateOfSameObject,
                        detail: "与已入选任务指向同一知识点（例如同时属于错题与考试重点），只保留一条。"
                    ))
                    continue
                }
                if let mistakeID = candidate.signals.linkedMistakeID { seenMistake.insert(mistakeID) }
                if let pointID = candidate.signals.linkedKnowledgePointID { seenKnowledge.insert(pointID) }
            }

            seenIdentity.insert(candidate.identityKey)
            kept.append(candidate)
        }

        return TaskCandidateSet(
            candidates: kept.sorted { $0.identityKey < $1.identityKey },
            exclusions: exclusions.sorted { lhs, rhs in
                if lhs.identityKey != rhs.identityKey { return lhs.identityKey < rhs.identityKey }
                return lhs.reason.rawValue < rhs.reason.rawValue
            }
        )
    }

    // MARK: 内容规范化

    /// 标题只能来自真实数据；确实没有标题时退化为明确的通用模板。
    static func normalizedTitle(for candidate: PlanCandidate, signals: TaskSignals) -> String {
        let trimmed = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        if candidate.source.kind == .manual {
            let note = (candidate.source.manualNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { return note }
        }
        return GenericTaskTemplate.template(for: candidate.source.kind).title
    }

    /// 没有真实资料时，不允许声称"1 节"这类具体范围。
    static func normalizedScope(for candidate: PlanCandidate, signals: TaskSignals) -> StudyScope {
        let template = GenericTaskTemplate.template(for: candidate.source.kind)
        guard candidate.plannedScope.isPositive else { return template.scope }
        if candidate.source.kind.requiresRealCourse,
           signals.hasCourseMaterials == false,
           candidate.plannedScope.unit == .sections {
            return template.scope
        }
        return candidate.plannedScope
    }

    // MARK: 已完成判定

    /// 当前候选是否已经完成（唯一权威来源是完成事件；计划项状态只作补充）。
    static func isCompletedToday(
        raw: PlanCandidate,
        signals: TaskSignals,
        reviewTask: ReviewTask?,
        dayKey: StudyDayKey,
        existingPlans: [DailyStudyPlan],
        completions: [CompletionEvent]
    ) -> Bool {
        // 持久化手动任务是一次性任务：任意学习日存在有效完成事件后都不再重复排入。
        // 撤销完成事件不参与判定，因此任务会重新回到候选池。
        if let manualTaskID = raw.source.manualTaskID,
           completions.contains(where: { !$0.isRevoked && $0.source?.manualTaskID == manualTaskID }) {
            return true
        }

        // 1) 复习任务本身已经被标记完成。
        if let reviewTask, reviewTask.status == .done {
            return true
        }

        // 2) 既有计划项已完成（同来源）。
        if existingPlans
            .filter({ $0.dayKey == dayKey })
            .flatMap(\.items)
            .contains(where: { $0.source == raw.source && $0.status == .completed }) {
            return true
        }

        // 3) 完成事件（权威来源）。
        let sameDay = completions.filter { $0.dayKey == dayKey && !$0.isRevoked }
        for event in sameDay {
            if let reviewTaskID = raw.source.reviewTaskID,
               event.source?.reviewTaskID == reviewTaskID {
                return true
            }
            if let occurrenceID = raw.source.occurrenceID,
               event.source?.occurrenceID == occurrenceID {
                return true
            }
            if raw.source.kind.requiresRealCourse,
               let courseID = raw.source.courseID,
               event.source?.kind == raw.source.kind,
               event.source?.courseID == courseID {
                return true
            }
            if raw.source.kind == .reviewTask,
               let pointID = signals.linkedKnowledgePointID,
               event.source?.kind == .reviewTask,
               event.source?.knowledgePointID == pointID {
                return true
            }
        }
        return false
    }

    // MARK: 内部

    private static func sortRank(_ candidate: TaskCandidate) -> (Int, Int, Double, Int) {
        let priority = candidate.signals.priority ?? 0
        let overdue = candidate.signals.overdueDays
        let mastery = candidate.signals.mastery ?? 1
        let minutes = candidate.estimatedMinutes
        // 优先级高、逾期久、掌握度低、耗时短的候选先保留。
        return (-priority, -overdue, mastery, minutes)
    }

    private static func exclusion(
        identityKey: String,
        title: String,
        source: DailyPlanItemSource,
        reason: TaskCandidateExclusionReason,
        detail: String
    ) -> TaskCandidateExclusion {
        TaskCandidateExclusion(
            id: StudyStableKey.uuid(from: "exclusion|\(reason.rawValue)|\(identityKey)"),
            identityKey: identityKey,
            title: title,
            source: source,
            reason: reason,
            detail: detail
        )
    }
}
