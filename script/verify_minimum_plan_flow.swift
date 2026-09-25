import Foundation

// D 模块（最低任务 / 内容拆分 / 学习会话）的独立行为测试。
//
// 这个文件刻意放在源码目标目录（`study software/`）之外：
// Xcode 使用 PBXFileSystemSynchronizedRootGroup，目录内的任何 .swift 都会被编进正式 App，
// 因此测试入口只能通过 swiftc 单独编译。
//
// 运行方式（在工程根目录 `软件本体/study software` 下）：
//
//   make verify-minimum-plan
//
// 覆盖的验收标准（全部是业务行为断言，不是"返回了非空值"）：
//  1. 剩余 12 分钟时不返回 15 分钟的整题任务（不假装减量）
//  2. 剩余 0 分钟时不假定完成，返回休息建议
//  3. 完成 1/5 道题不会把整组题标记完成（部分完成 ≠ 整体完成）
//  4. 暂停期间不累计时间
//  5. 双击完成只产生一个完成事件
//  6. 重启后不丢失已保存进度，也不虚增时长
//  7. 保底完成与标准完成在数据上可区分
//  8. 减量真正减少学习内容（范围变了，不只是分钟数）
//  9. 已完成内容不因模式切换消失；已完成的进度可以满足新的保底范围
// 10. 缺少结构化内容的任务不编造子题
// 11. 同一时刻只允许一个有效会话
// 12. 中断（切后台/崩溃）不无条件算作学习，需用户确认
// 13. 重复减量调用不重复执行（不产生新版本）
// 14. 睡眠保护时段不安排任务

@main
struct MinimumPlanVerifyHarness {
    // MARK: - 断言基础设施

    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
            print("PASS \(message)")
        } else {
            failed += 1
            print("FAIL \(message)")
        }
    }

    static func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        check(actual == expected, "\(message)（实际 \(actual)，期望 \(expected)）")
    }

    // MARK: - 时间工具

    static let timeZoneIdentifier = "Asia/Shanghai"

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    static func context(now: Date) -> PlanningContext {
        PlanningContext(now: now, timeZoneIdentifier: timeZoneIdentifier)
    }

    /// 固定的"今天"：2026-03-02 周一 20:00。
    static var referenceNow: Date { date(2026, 3, 2, 20, 0) }

    static var referenceDayKey: StudyDayKey {
        StudyDayKey(date: referenceNow, timeZone: TimeZone(identifier: timeZoneIdentifier)!)
    }

    // MARK: - 夹具

    /// 构造一条计划项。
    static func item(
        title: String,
        scope: StudyScope,
        minutes: Int,
        minimum: StudyScope? = nil,
        isSplittable: Bool = false,
        isPinned: Bool = false,
        source: DailyPlanItemSource = .manual(note: "测试"),
        planID: UUID,
        dueDate: Date? = nil,
        status: DailyPlanItemStatus = .pending
    ) -> DailyPlanItem {
        DailyPlanItem(
            planID: planID,
            source: source,
            title: title,
            plannedScope: scope,
            minimumScope: minimum,
            estimatedMinutes: minutes,
            scheduledDayKey: referenceDayKey,
            dueDate: dueDate,
            status: status,
            isPinned: isPinned,
            isSplittable: isSplittable,
            createdAt: referenceNow,
            updatedAt: referenceNow
        )
    }

    static func plan(items: [DailyPlanItem], capacity: Int = 60, mode: DailyPlanMode = .standard) -> DailyStudyPlan {
        let planID = items.first?.planID ?? UUID()
        return DailyStudyPlan(
            id: planID,
            dayKey: referenceDayKey,
            mode: mode,
            budget: DailyPlanBudget(
                capacityMinutes: capacity,
                dailyCapMinutes: nil,
                plannedMinutes: items.reduce(0) { $0 + $1.estimatedMinutes }
            ),
            items: items,
            createdAt: referenceNow,
            updatedAt: referenceNow
        )
    }

    static func itemContext(for item: DailyPlanItem) -> PlanItemSessionContext? {
        PlanItemSessionContext(item: item)
    }

    /// 状态机的便捷包装：从 nil 开始依次应用事件。
    static func apply(
        _ engine: StudySessionEngineImpl,
        events: [StudySessionEvent],
        to session: StudySession?,
        item: PlanItemSessionContext?,
        context: PlanningContext
    ) -> (session: StudySession?, completions: [CompletionEvent], rejections: [StudySessionRejection]) {
        var current = session
        var completions: [CompletionEvent] = []
        var rejections: [StudySessionRejection] = []
        for event in events {
            let transition = engine.apply(event, to: current, item: item, context: context)
            if let next = transition.session { current = next }
            if let completion = transition.completionEvent { completions.append(completion) }
            if let rejection = transition.rejection { rejections.append(rejection) }
        }
        return (current, completions, rejections)
    }

    // MARK: - 1. 范围压缩：真的减少内容

    static func testScopeReducerTrimsContent() {
        print("\n--- 范围压缩 ---")
        let planID = UUID()
        let fiveQuestions = item(
            title: "一组 5 道题",
            scope: .questions(5),
            minutes: 20,
            minimum: .questions(2),
            isSplittable: true,
            planID: planID
        )

        // 12 分钟 → 只能做 2～3 道题（按比例 12/20 = 0.6 → 3 道）。
        let outcome = TaskScopeReducer.reduce(
            item: fiveQuestions,
            to: nil,
            availableMinutes: 12,
            configuration: .default
        )
        check(outcome.isTrimmed, "整组题在时间不足时应缩小范围，而不是原样返回")
        checkEqual(outcome.scope.amount, 3, "12/20 的比例应保留 3 道题")
        checkEqual(outcome.scope.unit, .questions, "范围内涵不变，仍然以题为单位")
        check(outcome.estimatedMinutes < fiveQuestions.estimatedMinutes, "预计分钟必须跟着内容量一起下降")
        check(outcome.estimatedMinutes <= 12, "压缩后的分钟数不得超过预算（实际 \(outcome.estimatedMinutes)）")
        check(!outcome.remainingSummary.isEmpty, "必须说明剩余了哪些内容")
        check(outcome.reason.contains("缩到"), "必须给出可读的减量原因")

        // 保底下限：再少也不能少于 minimumScope。
        let tight = TaskScopeReducer.reduce(item: fiveQuestions, to: nil, availableMinutes: 1, configuration: .default)
        checkEqual(tight.scope.amount, 2, "压缩不得低于任务自己的保底范围（2 道题）")

        // 不可拆分（unit == .tasks，例如一次复习）→ 不得靠改分钟假装减量。
        let atomic = item(
            title: "复习任务：一次完整复习",
            scope: .tasks(1),
            minutes: 15,
            isSplittable: false,
            planID: planID
        )
        let refused = TaskScopeReducer.reduce(item: atomic, to: nil, availableMinutes: 12, configuration: .default)
        if case .cannotReduce = refused.reduction {
            check(true, "整题任务在时间不足时判定为不可安全压缩")
        } else {
            check(false, "整题任务不应被压缩（实际 \(refused.reduction)）")
        }
        checkEqual(refused.estimatedMinutes, 15, "不可压缩任务的分钟数不得被篡改")
    }

    // MARK: - 2. 减量分配：剩余 12 分钟不返回 15 分钟任务

    static func testMinimumPlanAllocation() {
        print("\n--- 保底/轻量分配 ---")
        let policy = StudyMinimumPlanPolicy()
        let context = context(now: referenceNow)
        let planID = UUID()

        // 例 A：一条 15 分钟的整题任务 + 只剩 12 分钟。
        let atomicItem = item(
            title: "复习任务：线性代数",
            scope: .tasks(1),
            minutes: 15,
            source: .reviewTask(UUID()),
            planID: planID
        )
        let atomicPlan = plan(items: [atomicItem], capacity: 15)
        let a = policy.reduce(plan: atomicPlan, remainingMinutes: 12, splittableItemIDs: [], context: context)
        check(a.isRestSuggestion, "放不下 15 分钟整题任务时应给出休息建议，而不是硬塞")
        check(!a.changes.contains { $0.kind == .trimmed }, "不可拆分任务不得被伪造成缩小范围")
        checkEqual(a.plan.plannedMinutesFromItems, 15, "休息建议不改动计划本体（只是不安排新的动作）")
        check(!a.plan.items.contains { $0.status == .completed }, "休息建议不得把任何任务标记为完成")
        check(a.explanation.blockedReasons.contains { $0.contains("放不下") || $0.contains("休息") },
              "必须说明为什么今天不做")

        // 例 B：一组 5 道题（可拆分）+ 只剩 12 分钟 → 缩到能放下的题数。
        let groupItem = item(
            title: "一组 5 道题",
            scope: .questions(5),
            minutes: 20,
            minimum: .questions(2),
            isSplittable: true,
            source: .reviewTask(UUID()),
            planID: planID
        )
        let groupPlan = plan(items: [groupItem], capacity: 20)
        let b = policy.reduce(plan: groupPlan, remainingMinutes: 12, splittableItemIDs: [groupItem.id], context: context)
        let keptScope = b.plan.items.first?.plannedScope
        check(keptScope != nil, "可拆分任务应保留下来")
        checkEqual(keptScope?.amount, 3, "12 分钟预算下保留 3 道题")
        checkEqual(b.plan.mode, .minimum, "剩余时间低于阈值时进入保底档")
        checkEqual(b.plan.plannedMinutesFromItems, 12, "保底方案总时长不得超过预算")
        check(b.changes.contains { $0.kind == .trimmed && $0.reason.contains("保留") }, "变更明细必须写清保留了什么")

        // 例 C：剩余 0 分钟 → 休息建议，不假定完成。
        let c = policy.reduce(plan: groupPlan, remainingMinutes: 0, splittableItemIDs: [groupItem.id], context: context)
        check(c.isRestSuggestion, "剩余 0 分钟必须返回休息建议")
        checkEqual(c.plan.id, groupPlan.id, "休息建议不改计划身份")
        checkEqual(c.plan.items.count, groupPlan.items.count, "休息建议不删除任务")
        checkEqual(c.plan.items.first?.plannedScope.amount, 5, "休息建议不改任务范围")
        check(c.plan.items.allSatisfy { $0.status != .completed }, "剩余 0 分钟不得假定任何任务完成")

        // 例 D：两条任务共 25 分钟 + 剩 22 分钟 → 轻量档保留多条动作，总时长不超预算。
        let light1 = item(
            title: "复习任务 A",
            scope: .questions(10),
            minutes: 10,
            minimum: .questions(4),
            isSplittable: true,
            source: .reviewTask(UUID()),
            planID: planID
        )
        let light2 = item(
            title: "复习任务 B",
            scope: .questions(15),
            minutes: 15,
            minimum: .questions(6),
            isSplittable: true,
            source: .reviewTask(UUID()),
            planID: planID
        )
        let lightPlan = plan(items: [light1, light2], capacity: 25)
        let d = policy.reduce(plan: lightPlan, remainingMinutes: 22, splittableItemIDs: [light1.id, light2.id], context: context)
        checkEqual(d.plan.mode, .reduced, "多条任务压缩后应为轻量档")
        check(d.plan.items.count >= 2, "轻量档应保留多个核心动作（实际 \(d.plan.items.count)）")
        check(d.plan.plannedMinutesFromItems <= 22, "轻量方案总时长不得超过预算")
        check(d.changes.contains { $0.kind == .trimmed }, "轻量档必须真的缩小内容范围")
        check(d.changes.allSatisfy { $0.afterMinutes <= $0.beforeMinutes }, "任何一条都不得被放大")
    }

    // MARK: - 3. 已完成内容不消失 + 用旧进度判定保底完成

    static func testCompletedProgressSurvivesReduction() {
        print("\n--- 已完成进度与减量共存 ---")
        let planID = UUID()
        let done = item(
            title: "已完成的复习任务",
            scope: .questions(5),
            minutes: 20,
            minimum: .questions(2),
            isSplittable: true,
            source: .reviewTask(UUID()),
            planID: planID,
            status: .completed
        )
        let remaining = item(
            title: "未完成的复习任务",
            scope: .questions(10),
            minutes: 25,
            minimum: .questions(4),
            isSplittable: true,
            source: .reviewTask(UUID()),
            planID: planID
        )
        let mixedPlan = plan(items: [done, remaining], capacity: 45)

        let policy = StudyMinimumPlanPolicy()
        let context = context(now: referenceNow)
        let proposal = policy.reduce(
            plan: mixedPlan,
            remainingMinutes: 10,
            splittableItemIDs: [remaining.id],
            context: context
        )

        check(proposal.plan.items.contains { $0.id == done.id }, "已完成的任务不得因减量消失")
        checkEqual(proposal.plan.items.first { $0.id == done.id }?.status, .completed, "已完成状态不得被改写")
        check(!proposal.changes.contains { $0.itemID == done.id }, "已完成的任务不进入变更明细")
        let pendingMinutes = proposal.plan.items
            .filter { $0.status == .pending || $0.status == .inProgress }
            .reduce(0) { $0 + $1.estimatedMinutes }
        check(pendingMinutes <= 10, "减量后只安排未完成部分，且不超过剩余时间（实际 \(pendingMinutes) 分钟）")
        checkEqual(proposal.plan.items.first { $0.id == done.id }?.estimatedMinutes, done.estimatedMinutes,
                   "已完成任务的原有时长不被改写")

        // 用户此前已经完成 1/5 道题，随后进入保底档：已完成的部分满足新的保底范围。
        let tier = PlanCompletionTier.resolve(completed: .questions(2), planned: .questions(5), minimum: .questions(2))
        checkEqual(tier, .minimum, "已达保底范围应判定为保底完成")
        let studiedTier = PlanCompletionTier.resolve(completed: .questions(1), planned: .questions(5), minimum: .questions(2))
        checkEqual(studiedTier, .studied, "只完成 1/5 道题不得判定为整体或保底完成")
    }

    // MARK: - 4. 自动减量关闭时不自行减量

    static func testAutoReduceDisabled() {
        print("\n--- 自动减量关闭 ---")
        let planID = UUID()
        let task = item(
            title: "复习任务：概率论",
            scope: .questions(5),
            minutes: 20,
            minimum: .questions(2),
            isSplittable: true,
            source: .reviewTask(UUID()),
            planID: planID
        )
        var disabledPlan = plan(items: [task], capacity: 20)
        disabledPlan.explanation = DailyPlanExplanation(
            blockedReasons: [MinimumPlanPolicyConfiguration.autoReduceDisabledMarker]
        )

        let policy = StudyMinimumPlanPolicy()
        let context = context(now: referenceNow)
        let proposal = policy.reduce(plan: disabledPlan, remainingMinutes: 8, splittableItemIDs: [task.id], context: context)
        checkEqual(proposal.plan.items.first?.plannedScope.amount, 5, "自动减量关闭时不得改动任务范围")
        checkEqual(proposal.plan.plannedMinutesFromItems, 20, "自动减量关闭时不得改动分钟数")
        check(!proposal.changes.contains { $0.kind == .trimmed }, "自动减量关闭时不得产生缩小记录")
        check(proposal.explanation.blockedReasons.contains { $0.contains("手动") }, "必须提示用户手动选择方案")
    }

    // MARK: - 5. 睡眠保护

    static func testProtectedSleep() {
        print("\n--- 睡眠保护 ---")
        let planID = UUID()
        let task = item(
            title: "复习任务：离散数学",
            scope: .questions(5),
            minutes: 20,
            minimum: .questions(2),
            isSplittable: true,
            source: .reviewTask(UUID()),
            planID: planID
        )
        let sleepPlan = plan(items: [task], capacity: 20)
        // 睡眠时段来自**用户配置**（G 注入），算法不再假定固定的 23:00–07:00。
        let policy = StudyMinimumPlanPolicy(
            configuration: MinimumPlanPolicyConfiguration(
                sleepWindows: [
                    DayTimeRange(
                        weekday: .monday,
                        start: TimeOfDay(hour: 23, minute: 0),
                        end: TimeOfDay(hour: 7, minute: 0),
                        endDayOffset: 1
                    )
                ]
            )
        )
        // 2026-03-02 是周一，23:40 已经进入用户配置的保护睡眠。
        let lateContext = context(now: date(2026, 3, 2, 23, 40))
        let proposal = policy.reduce(plan: sleepPlan, remainingMinutes: 30, splittableItemIDs: [task.id], context: lateContext)
        check(proposal.isRestSuggestion, "进入睡眠保护时段应返回休息建议")
        check(proposal.explanation.blockedReasons.contains { $0.contains("睡眠") }, "必须说明是因为睡眠保护")
        checkEqual(proposal.plan.plannedMinutesFromItems, 20, "睡眠保护不改动计划内容")
    }

    // MARK: - 6. 会话状态机

    static func testSessionLifecycle() {
        print("\n--- 会话生命周期 ---")
        let engine = StudySessionEngineImpl()
        let planID = UUID()
        let planItem = item(
            title: "复习任务：特征值",
            scope: .questions(5),
            minutes: 20,
            minimum: .questions(2),
            isSplittable: true,
            source: .reviewTask(UUID()),
            planID: planID
        )
        let itemContext = itemContext(for: planItem)
        let context = context(now: referenceNow)

        let start = date(2026, 3, 2, 20, 0)
        let pause = date(2026, 3, 2, 20, 5)
        let resume = date(2026, 3, 2, 20, 20)
        let finish = date(2026, 3, 2, 20, 25)

        let run = apply(
            engine,
            events: [
                .start(at: start),
                .updateProgress(scope: .questions(1), at: date(2026, 3, 2, 20, 3)),
                .updateProgress(scope: .questions(2), at: date(2026, 3, 2, 20, 4)),
                .pause(at: pause),
                .resume(at: resume),
                .finish(at: finish, scope: nil, assessment: nil, note: "")
            ],
            to: nil,
            item: itemContext,
            context: context
        )

        guard let session = run.session else {
            check(false, "会话应能建立")
            return
        }
        checkEqual(session.state, .finished, "会话应结束")
        checkEqual(session.progress.amount, 3, "进度应累计（1 + 2 = 3 道题）")

        // 有效时长：20:00–20:05（5 分钟）+ 20:20–20:25（5 分钟）= 10 分钟。
        // 暂停的 15 分钟不计入。
        checkEqual(session.effectiveMinutes(asOf: finish, calendar: context.calendar), 10, "暂停期间不得累计时间")
        checkEqual(run.completions.count, 1, "结束应产生且只产生一条完成事件")

        guard let completion = run.completions.first else { return }
        checkEqual(completion.completedScope.amount, 3, "完成事件必须记录实际完成范围（3/5）")
        checkEqual(completion.plannedScope?.amount, 5, "完成事件保留原计划范围")
        checkEqual(completion.isPartialCompletion, true, "3/5 必须判定为部分完成")
        checkEqual(completion.isFullCompletion, false, "3/5 不得判定为整体完成")
        checkEqual(completion.tier, .minimum, "3/5 达到保底范围（2/5）应记为保底完成")
        checkEqual(completion.actualMinutes, 10, "完成事件记录实际有效时长")
    }

    // MARK: - 7. 部分完成与整体完成分开

    static func testPartialVersusFullCompletion() {
        print("\n--- 部分完成 / 整体完成 ---")
        let engine = StudySessionEngineImpl()
        let planID = UUID()
        let planItem = item(
            title: "一组 5 道题",
            scope: .questions(5),
            minutes: 20,
            minimum: .questions(2),
            isSplittable: true,
            source: .reviewTask(UUID()),
            planID: planID
        )
        let itemContext = itemContext(for: planItem)
        let context = context(now: referenceNow)
        let start = date(2026, 3, 2, 20, 0)

        // 只完成 1/5。
        let partial = apply(
            engine,
            events: [
                .start(at: start),
                .finish(at: date(2026, 3, 2, 20, 6), scope: .questions(1), assessment: nil, note: "")
            ],
            to: nil,
            item: itemContext,
            context: context
        )
        checkEqual(partial.completions.first?.tier, .studied, "1/5 只算已学习，不算保底或标准完成")
        checkEqual(partial.completions.first?.isFullCompletion, false, "1/5 不得标记整组题完成")

        // 完整完成 5/5。
        let full = apply(
            engine,
            events: [
                .start(at: start),
                .finish(at: date(2026, 3, 2, 20, 21), scope: .questions(5), assessment: nil, note: "")
            ],
            to: nil,
            item: itemContext,
            context: context
        )
        checkEqual(full.completions.first?.tier, .standard, "5/5 记为标准完成")
        checkEqual(full.completions.first?.isFullCompletion, true, "5/5 才算整体完成")

        // 答错不影响完成范围与时长。
        let withWrongAnswers = apply(
            engine,
            events: [
                .start(at: start),
                .finish(
                    at: date(2026, 3, 2, 20, 21),
                    scope: .questions(5),
                    assessment: StudyAssessment(totalQuestions: 5, correctQuestions: 1, selfRating: 2),
                    note: ""
                )
            ],
            to: nil,
            item: itemContext,
            context: context
        )
        let event = withWrongAnswers.completions.first
        checkEqual(event?.tier, .standard, "答错不影响完成档次")
        checkEqual(event?.completedScope.amount, 5, "答错不影响完成范围")
        checkEqual(event?.assessment?.accuracy, 0.2, "正确率单独记录")
    }

    // MARK: - 8. 幂等：双击完成只产生一个事件

    static func testFinishIdempotency() {
        print("\n--- 完成幂等 ---")
        let engine = StudySessionEngineImpl()
        let planID = UUID()
        let planItem = item(
            title: "复习任务：矩阵",
            scope: .questions(5),
            minutes: 20,
            source: .reviewTask(UUID()),
            planID: planID
        )
        let itemContext = itemContext(for: planItem)
        let context = context(now: referenceNow)
        let start = date(2026, 3, 2, 20, 0)
        let finishAt = date(2026, 3, 2, 20, 10)

        let first = apply(
            engine,
            events: [.start(at: start), .finish(at: finishAt, scope: .questions(5), assessment: nil, note: "")],
            to: nil,
            item: itemContext,
            context: context
        )
        guard let session = first.session, let completion = first.completions.first else {
            check(false, "首次完成应产生会话与完成事件")
            return
        }

        // 第二次点击"完成"：同一会话再次收到 finish。
        let second = engine.apply(.finish(at: finishAt, scope: .questions(5), assessment: nil, note: ""), to: session, item: itemContext, context: context)
        check(second.completionEvent == nil, "重复 finish 不得产生第二条完成事件")
        check(second.rejection != nil, "重复 finish 必须被明确拒绝")

        // 幂等键相同 → 存储层插入同样只能成功一次。
        var snapshot = StoreSnapshot()
        snapshot.studySessions = [session]
        let insertedOnce = snapshot.insertingCompletionEvent(completion)
        check(insertedOnce != nil, "首次插入完成事件应成功")
        let insertedTwice = insertedOnce?.insertingCompletionEvent(completion)
        check(insertedTwice == nil, "同一幂等键重复插入必须被拒绝")

        // 同一会话 + 相同幂等键 → 同一个事件 ID。
        let rebuilt = CompletionEvent.make(
            sessionID: session.id,
            planID: planID,
            planItemID: planItem.id,
            dayKey: planItem.scheduledDayKey,
            source: planItem.source,
            plannedScope: planItem.plannedScope,
            minimumScope: planItem.minimumScope,
            completedScope: .questions(5),
            actualMinutes: 10,
            completedAt: finishAt,
            assessment: nil,
            note: "",
            createdAt: finishAt
        )
        checkEqual(rebuilt.id, completion.id, "同一会话的完成事件 ID 必须稳定")
    }

    // MARK: - 9. 单会话约束与进度累计

    static func testSingleActiveSession() {
        print("\n--- 单会话约束 ---")
        let engine = StudySessionEngineImpl()
        let planID = UUID()
        let planItem = item(title: "复习任务：级数", scope: .questions(5), minutes: 20, source: .reviewTask(UUID()), planID: planID)
        let itemContext = itemContext(for: planItem)
        let context = context(now: referenceNow)
        let start = date(2026, 3, 2, 20, 0)

        guard let session = engine.apply(.start(at: start), to: nil, item: itemContext, context: context).session else {
            check(false, "应能开始会话")
            return
        }
        let duplicate = engine.apply(.start(at: date(2026, 3, 2, 20, 1)), to: session, item: itemContext, context: context)
        check(duplicate.session == nil, "同一计划项不得同时存在两个有效会话")
        check(duplicate.rejection != nil, "重复开始必须被拒绝")

        // 幂等：同一个 start 时间戳重复送达也要被拒绝。
        let sameTimestamp = engine.apply(.start(at: start), to: session, item: itemContext, context: context)
        check(sameTimestamp.session == nil, "相同时间戳的重复 start 必须被拒绝")

        // 非法状态迁移。
        let pauseTwice = apply(
            engine,
            events: [.pause(at: date(2026, 3, 2, 20, 5)), .pause(at: date(2026, 3, 2, 20, 6))],
            to: session,
            item: itemContext,
            context: context
        )
        check(pauseTwice.rejections.count == 1, "连续暂停第二次应被拒绝")

        let resumeWhenRunning = engine.apply(.resume(at: date(2026, 3, 2, 20, 7)), to: session, item: itemContext, context: context)
        check(resumeWhenRunning.rejection != nil, "未暂停时继续必须被拒绝")
    }

    // MARK: - 10. 中断识别：不无条件把离线时间算作学习

    static func testInterruptionDetection() {
        print("\n--- 中断识别 ---")
        let engine = StudySessionEngineImpl(configuration: StudySessionEngineConfiguration(interruptionThresholdSeconds: 120))
        let planID = UUID()
        let planItem = item(title: "复习任务：导数", scope: .questions(5), minutes: 20, source: .reviewTask(UUID()), planID: planID)
        let itemContext = itemContext(for: planItem)
        let baseContext = context(now: referenceNow)
        let start = date(2026, 3, 2, 20, 0)

        guard let session = engine.apply(.start(at: start), to: nil, item: itemContext, context: baseContext).session else {
            check(false, "应能开始会话")
            return
        }

        // 3 小时后重新进入应用：必须被识别为中断，等待用户确认。
        let lateContext = context(now: date(2026, 3, 2, 23, 10))
        let interruption = engine.interruptionCandidate(for: session, context: lateContext)
        check(interruption != nil, "长时间无心跳应识别为中断")
        checkEqual(interruption?.requiresUserConfirmation, true, "中断必须要求用户确认")
        check((interruption?.gapMinutes ?? 0) >= 180, "中断时长应被如实计算（实际 \(interruption?.gapMinutes ?? -1) 分钟）")

        // 刚刚更新过 → 不算中断。
        let freshContext = context(now: date(2026, 3, 2, 20, 1))
        check(engine.interruptionCandidate(for: session, context: freshContext) == nil, "刚更新过不应误报中断")

        // 暂停期间的中断不算"离线学习时间"。
        let paused = apply(engine, events: [.pause(at: date(2026, 3, 2, 20, 2))], to: session, item: itemContext, context: baseContext).session
        if let paused {
            let pausedInterruption = engine.interruptionCandidate(for: paused, context: lateContext)
            checkEqual(pausedInterruption?.wasPaused, true, "暂停中的中断应被标记为已暂停")
            checkEqual(pausedInterruption?.requiresUserConfirmation, false, "暂停中的中断不需要确认是否学习")
        } else {
            check(false, "应能暂停会话")
        }

        // 超过可信上限的会话需要人工确认。
        let longSession = StudySession(
            id: UUID(),
            planID: planID,
            planItemID: planItem.id,
            dayKey: planItem.scheduledDayKey,
            startedAt: date(2026, 3, 2, 0, 0),
            state: .running,
            createdAt: date(2026, 3, 2, 0, 0),
            updatedAt: date(2026, 3, 2, 0, 0)
        )
        let trustingEngine = StudySessionEngineImpl(configuration: StudySessionEngineConfiguration(maximumSessionMinutes: 30))
        check(trustingEngine.exceedsTrustedDuration(longSession, context: baseContext), "超过上限的会话必须标为可疑")
    }

    // MARK: - 11. 重启后恢复进度，不虚增时长

    static func testRestartRestoresProgress() {
        print("\n--- 重启恢复 ---")
        let engine = StudySessionEngineImpl()
        let planID = UUID()
        let planItem = item(title: "复习任务：积分", scope: .questions(5), minutes: 20, source: .reviewTask(UUID()), planID: planID)
        let itemContext = itemContext(for: planItem)
        let baseContext = context(now: referenceNow)
        let start = date(2026, 3, 2, 20, 0)

        // 第一次运行：学 10 分钟，记 2 道题，然后"崩溃"（进程结束，没有 finish）。
        let run = apply(
            engine,
            events: [.start(at: start), .updateProgress(scope: .questions(2), at: date(2026, 3, 2, 20, 10))],
            to: nil,
            item: itemContext,
            context: baseContext
        )
        guard let live = run.session else {
            check(false, "应能建立会话")
            return
        }

        // 模拟重新加载：会话经过 JSON 往返后恢复。
        guard let data = try? JSONEncoder().encode(live),
              let restored = try? JSONDecoder().decode(StudySession.self, from: data) else {
            check(false, "会话必须能持久化并恢复")
            return
        }

        checkEqual(restored.id, live.id, "恢复后会话 ID 不变")
        checkEqual(restored.state, StudySessionState.running, "恢复后保持原状态")
        checkEqual(restored.progress.amount, 2, "恢复后不丢失已保存进度")
        checkEqual(restored.appliedEventKeys.count, live.appliedEventKeys.count, "恢复后保留已应用事件键（防重复）")

        // 崩溃后 3 小时再打开：已保存进度是 2 道题 / 10 分钟，
        // 但界面必须使用"已保存值"，不得把 3 小时离线时间算进时长。
        let reopened = context(now: date(2026, 3, 2, 23, 0))
        checkEqual(restored.restartDisplayMinutes(context: context(now: date(2026, 3, 2, 20, 10))), 10, "恢复后的已保存有效时长为 10 分钟")
        let interruption = engine.interruptionCandidate(for: restored, context: reopened)
        check(interruption != nil, "重开应用必须提示中断确认，而不是直接采信离线时间")

        // 用户确认"没有学习" → 由界面追加暂停区间，把这段排除。
        let excluded = apply(
            engine,
            events: [
                .pause(at: date(2026, 3, 2, 20, 10)),
                .resume(at: date(2026, 3, 2, 23, 0)),
                .finish(at: date(2026, 3, 2, 23, 5), scope: nil, assessment: nil, note: "")
            ],
            to: restored,
            item: PlanItemSessionContext(
                planID: planID,
                planItemID: planItem.id,
                dayKey: planItem.scheduledDayKey,
                source: planItem.source,
                title: planItem.title,
                plannedScope: .questions(5),
                minimumScope: .questions(2)
            ),
            context: reopened
        )
        guard let recovered = excluded.session else {
            check(false, "恢复后的会话应能继续")
            return
        }
        checkEqual(recovered.effectiveMinutes(asOf: date(2026, 3, 2, 23, 5), calendar: reopened.calendar), 15,
                   "排除离线时间后只累计真实学习时长（10 + 5）")

        // 沿用已保存进度：仍然只有 2 道题，不会因为重启虚增。
        checkEqual(recovered.progress.amount, 2, "重启不虚增完成进度")
        checkEqual(excluded.completions.first?.completedScope.amount, 2, "完成事件按已保存进度记录（2/5）")
        checkEqual(excluded.completions.first?.tier, .minimum, "2/5 达到保底范围，记为保底完成")
    }

    // MARK: - 12. 手动修正与来源标记

    static func testManualAdjustmentKeepsSource() {
        print("\n--- 手动修正来源 ---")
        let note = StudySessionEngineImpl.manualAdjustmentNote(minutes: 8, reason: "忘记计时")
        check(note.hasPrefix("manualAdjustment:8min"), "手动修正必须写入结构化来源标记")
        check(note.contains("by:"), "手动修正必须记录修正人")
        check(note.contains("reason:"), "手动修正必须记录原因")

        let gapNote = StudySessionEngineImpl.interruptionDecisionNote(studiedDuringGap: false, gapMinutes: 45)
        check(gapNote.contains("excluded"), "中断确认结果必须留痕")

        let planID = UUID()
        let planItem = item(title: "复习任务：虚词", scope: .questions(5), minutes: 20, source: .reviewTask(UUID()), planID: planID)
        let engine = StudySessionEngineImpl()
        let context = context(now: referenceNow)
        guard var session = engine.apply(.start(at: referenceNow), to: nil, item: itemContext(for: planItem), context: context).session else {
            check(false, "应能建立会话")
            return
        }
        session = session.appending(note: note)
        check(StudySessionEngineImpl.hasManualAdjustment(session), "会话应能识别出手动修正记录")
        check(!StudySessionEngineImpl.hasManualAdjustment(StudySession(dayKey: planItem.scheduledDayKey, startedAt: referenceNow, createdAt: referenceNow, updatedAt: referenceNow)),
              "没有修正记录的会话不应被误判")
    }

    // MARK: - 13. 放弃不产生完成记录

    static func testAbandonProducesNoCompletion() {
        print("\n--- 放弃 ---")
        let engine = StudySessionEngineImpl()
        let planID = UUID()
        let planItem = item(title: "复习任务：语法", scope: .questions(5), minutes: 20, source: .reviewTask(UUID()), planID: planID)
        let itemContext = itemContext(for: planItem)
        let context = context(now: referenceNow)

        let abandoned = apply(
            engine,
            events: [
                .start(at: date(2026, 3, 2, 20, 0)),
                .updateProgress(scope: .questions(2), at: date(2026, 3, 2, 20, 5)),
                .abandon(at: date(2026, 3, 2, 20, 12), reason: "临时有事")
            ],
            to: nil,
            item: itemContext,
            context: context
        )
        checkEqual(abandoned.session?.state, .abandoned, "会话应标记为已放弃")
        checkEqual(abandoned.session?.abandonmentReason, "临时有事", "放弃原因必须保留")
        check(abandoned.completions.isEmpty, "放弃不得生成完成事件")
        checkEqual(abandoned.session?.progress.amount, 2, "放弃后已学进度仍然保留（算作已学习而非完成）")
        checkEqual(abandoned.session?.effectiveMinutes(asOf: date(2026, 3, 2, 20, 12), calendar: context.calendar), 12, "放弃也保留有效时长")
        check(abandoned.session?.endedAt != nil, "放弃必须写入结束时间戳")
    }

    // MARK: - 14. 集成：协调器 + 注册表 + 重复减量

    static func testCoordinatorIntegration() {
        print("\n--- 协调器集成（端到端） ---")
        let engines = StudyEngineRegistry.production()
        check(engines.minimumPolicyFactory != nil && engines.minimumPolicy == nil, "生产注册表只通过当前快照工厂提供最低任务策略")
        check(engines.sessionEngine != nil, "生产注册表必须注册学习会话引擎")
        check(!engines.missingModules.contains("最低任务策略"), "最低任务策略不应再出现在缺失模块里")
        check(!engines.missingModules.contains("学习会话引擎"), "学习会话引擎不应再出现在缺失模块里")

        let coordinator = StudyPlanCoordinator(engines: engines)
        let context = context(now: referenceNow)
        let planID = UUID()
        let taskItem = item(
            title: "一组 5 道题",
            scope: .questions(5),
            minutes: 20,
            minimum: .questions(2),
            isSplittable: true,
            source: .manual(note: "端到端减量与会话验证"),
            planID: planID
        )
        let activePlan = plan(items: [taskItem], capacity: 20)
        var state = StoreSnapshot()
        state.dailyPlans = [activePlan]

        let first = coordinator.coordinate(.applyMinimumPlan(dayKey: referenceDayKey, remainingMinutes: 12, expectedPlanID: nil, expectedVersion: nil), state: state, context: context)
        check(first.didChange, "减量应产生变化")
        let activeAfter = first.snapshot.dailyPlans.first { $0.isActive }
        // 协调层必须**保留策略返回的模式**（标准 / 轻量 / 保底 / 休息），不再统一改写。
        let policyPreview = StudyMinimumPlanPolicy(
            configuration: MinimumPlanPolicyConfiguration.standard(availability: state.availabilityPreferences, isManual: true)
        ).reduce(
            plan: activePlan,
            remainingMinutes: 12,
            splittableItemIDs: [taskItem.id],
            context: context
        )
        checkEqual(activeAfter?.mode, policyPreview.plan.mode, "减量后的模式必须与策略返回的模式一致")
        checkEqual(activeAfter?.items.first?.plannedScope.amount, 3, "端到端减量应真的把 5 道题缩到 3 道")
        checkEqual(activeAfter?.version, 2, "减量应生成新版本")
        checkEqual(first.snapshot.dailyPlans.filter { $0.dayKey == referenceDayKey }.count, 2, "旧版本必须保留（不删除历史）")

        // 重复调用同样的减量：不得再生成新版本。
        let second = coordinator.coordinate(.applyMinimumPlan(dayKey: referenceDayKey, remainingMinutes: 12, expectedPlanID: nil, expectedVersion: nil), state: first.snapshot, context: context)
        check(!second.didChange, "重复减量不得重复执行（实际 didChange=\(second.didChange)）")
        checkEqual(second.snapshot.dailyPlans.count, 2, "重复减量不得产生第三个版本")

        // 通过协调器完成一次学习：只完成 2/5（=减量后的保底范围）→ 保底完成。
        let finishResult = coordinator.coordinate(
            .completeItemDirectly(planItemID: taskItem.id, scope: .questions(2), minutes: 8, assessment: nil, note: ""),
            state: first.snapshot,
            context: context
        )
        checkEqual(finishResult.snapshot.completionEvents.count, 1, "完成应写入一条完成事件")
        checkEqual(finishResult.snapshot.completionEvents.first?.tier, .minimum, "2/5 达到保底范围，记为保底完成")
        checkEqual(finishResult.snapshot.completionEvents.first?.isPartialCompletion, true, "2/3 必须判定为部分完成")
        let updatedItem = finishResult.snapshot.dailyPlans.first { $0.isActive }?.items.first { $0.id == taskItem.id }
        checkEqual(updatedItem?.status, .completed, "达到保底范围后计划项应标记完成")
        checkEqual(updatedItem?.completionTier, .minimum, "计划项的档次缓存应为保底完成")
        checkEqual(updatedItem?.achievedScope?.amount, 2, "计划项记录实际完成范围")

        // 重复完成：不得写入第二条。
        let duplicate = coordinator.coordinate(
            .completeItemDirectly(planItemID: taskItem.id, scope: .questions(2), minutes: 8, assessment: nil, note: ""),
            state: finishResult.snapshot,
            context: context
        )
        checkEqual(duplicate.snapshot.completionEvents.count, 1, "重复完成不得产生第二条事件")
        check(duplicate.rejection != nil, "重复完成必须被明确拒绝")

        // 通过协调器跑一次会话：start → finish。
        // 会话必须挂到真实的计划项上，完成事件才有 plannedScope 可用于判档。
        var sessionState = StoreSnapshot()
        sessionState.dailyPlans = [activePlan]
        sessionState.dailyPlans.append(contentsOf: first.snapshot.dailyPlans.filter { $0.dayKey == referenceDayKey })
        let started = coordinator.coordinate(.startSession(planItemID: taskItem.id), state: sessionState, context: context)
        guard let session = started.snapshot.studySessions.first else {
            check(false, "协调器应能开始会话")
            return
        }
        checkEqual(session.state, .running, "会话应为进行中")
        let finished = coordinator.coordinate(
            .finishSession(sessionID: session.id, scope: .questions(5), assessment: nil, note: ""),
            state: started.snapshot,
            context: context
        )
        checkEqual(finished.snapshot.completionEvents.count, 1, "会话结束应产生一条完成事件")
        checkEqual(finished.snapshot.completionEvents.first?.tier, .standard, "5/5 应记为标准完成")
        checkEqual(finished.snapshot.studySessions.first?.state, .finished, "会话状态应为已结束")

        // 剩余 0 分钟 → 休息状态：不改任何任务内容、不写完成记录，但模式要落到计划上，
        // 这样首页、奖励进度与通知看到的状态与预览一致。
        let rest = coordinator.coordinate(.applyMinimumPlan(dayKey: referenceDayKey, remainingMinutes: 0, expectedPlanID: nil, expectedVersion: nil), state: state, context: context)
        let restPlan = rest.snapshot.dailyPlans.first { $0.isActive }
        checkEqual(restPlan?.mode, .rest, "剩余 0 分钟应进入休息状态")
        checkEqual(restPlan?.items.count, activePlan.items.count, "休息状态不删除任务")
        checkEqual(restPlan?.plannedMinutesFromItems, activePlan.plannedMinutesFromItems, "休息状态不改任务预计时长")
        check(rest.snapshot.completionEvents.isEmpty, "休息状态不得写入任何完成记录")
        let restAgain = coordinator.coordinate(.applyMinimumPlan(dayKey: referenceDayKey, remainingMinutes: 0, expectedPlanID: nil, expectedVersion: nil), state: rest.snapshot, context: context)
        check(!restAgain.didChange, "已经是休息状态时重复应用不再新建版本")
        checkEqual(rest.snapshot.dailyPlans.first?.items.first?.status, .pending, "休息建议不得把任务标记完成")
    }

    // MARK: - 15. 减量撤销的明确来源、单次语义与进度保留

    static func testReductionUndoProvenanceAndSingleUse() {
        print("\n--- 减量撤销版本关系 ---")
        let coordinator = StudyPlanCoordinator(engines: StudyEngineRegistry.production())
        let context = context(now: referenceNow)
        let planID = UUID()
        let originalItems = (0..<3).map { index in
            item(
                title: "恢复测试任务 \(index + 1)",
                scope: .questions(10),
                minutes: 30,
                minimum: .questions(2),
                isSplittable: true,
                source: .manual(note: "恢复测试任务 \(index + 1)"),
                planID: planID
            )
        }
        let standard = plan(items: originalItems, capacity: 90)
        var state = StoreSnapshot()
        state.dailyPlans = [standard]

        let lightResult = coordinator.coordinate(
            .applyMinimumPlan(dayKey: referenceDayKey, remainingMinutes: 50, expectedPlanID: standard.id, expectedVersion: standard.version),
            state: state,
            context: context
        )
        let light = lightResult.snapshot.dailyPlans.first(where: \.isActive)
        checkEqual(light?.mode, .reduced, "标准计划在较宽松的预算下减为轻量")
        checkEqual(light?.reductionUndoTargetPlanID, standard.id, "轻量版本明确指向减量前标准版本")
        checkEqual(light?.isUndoableReduction, true, "轻量版本记录其由减量产生")

        let minimumResult = coordinator.coordinate(
            .applyMinimumPlan(dayKey: referenceDayKey, remainingMinutes: 12, expectedPlanID: light?.id, expectedVersion: light?.version),
            state: lightResult.snapshot,
            context: context
        )
        let minimum = minimumResult.snapshot.dailyPlans.first(where: \.isActive)
        checkEqual(minimum?.mode, .minimum, "轻量计划进一步减为保底")
        checkEqual(minimum?.reductionUndoTargetPlanID, light?.id, "保底版本指向紧邻本次减量前的轻量版本")
        if let minimum,
           let encoded = try? JSONEncoder().encode(minimum),
           let decoded = try? JSONDecoder().decode(DailyStudyPlan.self, from: encoded) {
            checkEqual(decoded.isUndoableReduction, true, "持久化往返保留减量来源标记")
            checkEqual(decoded.reductionUndoTargetPlanID, light?.id, "持久化往返保留明确恢复目标")
            if var legacyObject = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
                legacyObject.removeValue(forKey: "isUndoableReduction")
                legacyObject.removeValue(forKey: "reductionUndoTargetPlanID")
                if let legacyData = try? JSONSerialization.data(withJSONObject: legacyObject),
                   let legacy = try? JSONDecoder().decode(DailyStudyPlan.self, from: legacyData) {
                    checkEqual(legacy.isUndoableReduction, false, "旧计划缺失减量标记时默认不可撤销")
                    checkEqual(legacy.reductionUndoTargetPlanID, nil, "旧计划缺失恢复目标时不猜测目标")
                } else {
                    check(false, "缺少新字段的旧计划仍应可解码")
                }
            } else {
                check(false, "应能读取计划 JSON 以模拟旧版本数据")
            }
        } else {
            check(false, "减量计划应能完成 JSON 持久化往返")
        }

        guard let minimum, let completedItem = minimum.items.first else {
            check(false, "保底版本应有一项任务供后续学习与恢复验证")
            return
        }
        let completion = coordinator.coordinate(
            .completeItemDirectly(
                planItemID: completedItem.id,
                scope: completedItem.plannedScope,
                minutes: completedItem.estimatedMinutes,
                assessment: nil,
                note: "减量后完成"
            ),
            state: minimumResult.snapshot,
            context: context
        )
        checkEqual(completion.snapshot.completionEvents.count, 1, "保底期间产生的完成事件被记录")

        // 模拟保底期间新增的一条固定、进行中任务；撤销必须一并保留。
        let activeIndex = completion.snapshot.dailyPlans.firstIndex(where: \.isActive)!
        var stateWithProtectedTask = completion.snapshot
        let activePlanID = stateWithProtectedTask.dailyPlans[activeIndex].id
        var protectedTask = item(
            title: "减量后固定进行中的新任务",
            scope: .questions(4),
            minutes: 12,
            isSplittable: true,
            isPinned: true,
            source: .manual(note: "减量后新增固定任务"),
            planID: activePlanID,
            status: .inProgress
        )
        protectedTask.achievedScope = .questions(1)
        stateWithProtectedTask.dailyPlans[activeIndex].items.append(protectedTask)

        let undo = coordinator.coordinate(
            .undoMinimumPlan(dayKey: referenceDayKey),
            state: stateWithProtectedTask,
            context: context
        )
        let restoredLight = undo.snapshot.dailyPlans.first(where: \.isActive)
        check(undo.didChange, "第一次撤销应成功")
        checkEqual(restoredLight?.mode, .reduced, "撤销保底回到轻量，而不是继续沿审计链回到标准")
        let expectedRestoredScope = light?.items.first(where: { $0.id == completedItem.id })?.plannedScope.amount
        checkEqual(restoredLight?.items.first(where: { $0.id == completedItem.id })?.plannedScope.amount, expectedRestoredScope, "恢复任务范围为轻量减量前的范围")
        checkEqual(restoredLight?.items.first(where: { $0.id == completedItem.id })?.achievedScope?.amount, completedItem.plannedScope.amount, "减量期间完成范围由有效完成事件重算")
        checkEqual(restoredLight?.items.first(where: { $0.id == completedItem.id })?.completionTier, .minimum, "按恢复后的原范围重新判定完成档位")
        checkEqual(undo.snapshot.completionEvents.count, 1, "撤销不删除减量期间的完成事件")
        let restoredProtected = restoredLight?.items.first(where: { $0.id == protectedTask.id })
        checkEqual(restoredProtected?.status, .inProgress, "撤销保留减量后新增任务的进行中状态")
        checkEqual(restoredProtected?.isPinned, true, "撤销保留减量后新增任务的固定状态")
        checkEqual(restoredProtected?.achievedScope?.amount, 1, "撤销保留进行中任务的已学进度")
        checkEqual(restoredLight?.isUndoableReduction, false, "撤销生成的版本不能再次撤销同一次减量")
        checkEqual(restoredLight?.reductionUndoTargetPlanID, nil, "撤销生成的版本清空恢复目标")
        checkEqual(restoredLight?.supersedesPlanID, minimum.id, "版本前驱仍保留为审计历史")

        let secondUndo = coordinator.coordinate(
            .undoMinimumPlan(dayKey: referenceDayKey),
            state: undo.snapshot,
            context: context
        )
        check(!secondUndo.didChange, "同一次减量撤销后不能再次撤销")
        check(secondUndo.rejection != nil, "重复撤销应给出不可撤销原因")

        guard let restoredLight else {
            check(false, "撤销后应有活动的轻量版本")
            return
        }
        let newReduction = coordinator.coordinate(
            .applyMinimumPlan(dayKey: referenceDayKey, remainingMinutes: 12, expectedPlanID: restoredLight.id, expectedVersion: restoredLight.version),
            state: undo.snapshot,
            context: context
        )
        let newMinimum = newReduction.snapshot.dailyPlans.first(where: \.isActive)
        check(newReduction.didChange, "撤销后发生新减量仍可正常应用")
        checkEqual(newMinimum?.isUndoableReduction, true, "新减量重新获得一次撤销资格")
        checkEqual(newMinimum?.reductionUndoTargetPlanID, restoredLight.id, "新减量恢复目标指向当前轻量版本")
        let secondCycleUndo = coordinator.coordinate(
            .undoMinimumPlan(dayKey: referenceDayKey),
            state: newReduction.snapshot,
            context: context
        )
        check(secondCycleUndo.didChange, "新减量可以单独撤销")
        checkEqual(secondCycleUndo.snapshot.dailyPlans.first(where: \.isActive)?.mode, .reduced, "第二次撤销仍回到这次减量前的轻量版本")

        // 实际普通重规划保留审计前驱，但必须主动清除减量撤销元数据。
        let refreshResult = coordinator.coordinate(
            .regeneratePlan(dayKey: referenceDayKey, force: true),
            state: state,
            context: context
        )
        let refreshedPlan = refreshResult.snapshot.dailyPlans.first(where: \.isActive)
        check(refreshResult.didChange, "强制普通重规划应生成新版本")
        checkEqual(refreshedPlan?.supersedesPlanID, standard.id, "普通重规划保留版本前驱用于审计")
        checkEqual(refreshedPlan?.isUndoableReduction, false, "普通重规划不保留减量撤销标记")
        checkEqual(refreshedPlan?.reductionUndoTargetPlanID, nil, "普通重规划清除减量恢复目标")

        // 普通重规划版本即使有审计前驱且处于非标准模式，也没有撤销资格。
        var oldVersion = standard
        oldVersion.status = .superseded
        var ordinaryReplan = plan(items: originalItems, capacity: 90, mode: .reduced)
        ordinaryReplan.version = 2
        ordinaryReplan.supersedesPlanID = oldVersion.id
        ordinaryReplan.status = .active
        var ordinaryState = StoreSnapshot()
        ordinaryState.dailyPlans = [oldVersion, ordinaryReplan]
        let ordinaryUndo = coordinator.coordinate(
            .undoMinimumPlan(dayKey: referenceDayKey),
            state: ordinaryState,
            context: context
        )
        check(!ordinaryUndo.didChange, "普通重规划不能仅凭前驱关系和计划模式被撤销")

        // 旧字段可能曾有 true 标记，但缺少明确目标时仍不能猜测。
        ordinaryState.dailyPlans[1].isUndoableReduction = true
        let legacyUndo = coordinator.coordinate(
            .undoMinimumPlan(dayKey: referenceDayKey),
            state: ordinaryState,
            context: context
        )
        check(!legacyUndo.didChange, "缺少明确恢复目标的旧数据安全地不可撤销")
    }

    // MARK: - 主入口

    static func main() {
        print("D 模块（最低任务 / 内容拆分 / 学习会话）行为验证")
        print("=================================================")

        testScopeReducerTrimsContent()
        testMinimumPlanAllocation()
        testCompletedProgressSurvivesReduction()
        testAutoReduceDisabled()
        testProtectedSleep()
        testSessionLifecycle()
        testPartialVersusFullCompletion()
        testFinishIdempotency()
        testSingleActiveSession()
        testInterruptionDetection()
        testRestartRestoresProgress()
        testManualAdjustmentKeepsSource()
        testAbandonProducesNoCompletion()
        testCoordinatorIntegration()
        testReductionUndoProvenanceAndSingleUse()

        print("\n=================================================")
        print("通过 \(passed) 项，失败 \(failed) 项")
        if failed > 0 {
            print("存在失败断言，请检查上面的 FAIL 行。")
            exit(1)
        }
        print("全部通过。")
    }
}
