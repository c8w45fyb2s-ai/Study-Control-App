import Foundation

// E 模块（娱乐解锁与奖励计时）的独立行为测试。
//
// 这个文件刻意放在源码目标目录（`study software/`）之外：
// Xcode 使用 PBXFileSystemSynchronizedRootGroup，目录内的任何 .swift 都会被编进正式 App，
// 因此测试入口只能通过 swiftc 单独编译。
//
// 运行方式（在工程根目录 `软件本体/study software` 下）：
//
//   make verify-entertainment
//
// 等价命令（不依赖 Makefile；路径必须加引号，源码目录名里有空格）：
//
//   swiftc -parse-as-library "study software/Models.swift" "study software/AIPlanIntent.swift" \
//     "study software/ScheduleResolver.swift" "study software/AvailabilityCalculator.swift" \
//     "study software/StudyPlanningModels.swift" "study software/ScheduleModels.swift" \
//     "study software/StudySessionModels.swift" "study software/EntertainmentModels.swift" \
//     "study software/PlanningContracts.swift" "study software/RewardEvaluator.swift" \
//     "study software/EntertainmentSessionEngine.swift" "script/verify_entertainment_flow.swift" \
//     -o ".build-e/verify_entertainment_flow" && ./.build-e/verify_entertainment_flow
//
// 覆盖的验收标准（全部是业务行为断言，不是"返回值非空"）：
//  1. 条件进度与真实完成事件一致（标准/保底/已学习/时长/比例）
//  2. 答题正确与否不影响资格：评分低但确实完成，仍然计入
//  3. 当前学习日不累计前一天的学习量
//  4. 指定任务 / 知识点绑定必须落在同一天，昨天完成不会解锁今天
//  5. 删除任务不等于完成任务：绑定失效时提示需要调整，且不自动解锁
//  6. 无任务、无学习记录的空计划不能解锁（含"完成比例"口径）
//  7. 撤销的完成事件不计入
//  8. 同一事件不会重复累计（id 与幂等键双重去重）
//  9. 旧版本"每日完成总数"不可判定，不推算资格
// 10. 保底奖励单独设置：标准达标发标准档，未达标只发保底档
// 11. "不断减量到零"拿不到奖励（无学习信号时任何保底都不发放）
// 12. 同一规则、同一学习日、同一档位只发放一次（含启停切换与无实质编辑）
// 13. 规则编辑保留版本，历史奖励不随之改写
// 14. 每周重复日期生效判定
// 15. 计时完全由持久化时间戳推导：切后台/重启后剩余时长一致
// 16. 一次只允许一个娱乐计时；跨天奖励拒绝开始（默认当天使用）
// 17. 到时返回"通知需求"而不是自己发通知；无通知权限不影响页面内计时
// 18. 减量预览返回奖励影响说明（供 D 展示）
// 19. 规则与奖励经 JSON 往返后资格一致（重启后一致）

@main
struct EntertainmentVerifyHarness {

    // MARK: - 断言基础设施

    static var checkCount = 0
    static var failureCount = 0

    static func check(_ condition: Bool, _ message: String) {
        checkCount += 1
        if condition {
            print("  ✅ \(message)")
        } else {
            failureCount += 1
            print("  ❌ \(message)")
        }
    }

    static func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual == expected {
            check(true, message)
        } else {
            check(false, "\(message)（实际 \(actual)，期望 \(expected)）")
        }
    }

    static func section(_ title: String) {
        print("\n▶︎ \(title)")
    }

    // MARK: - 时间工具（固定注入，不读系统时钟）

    static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(identifier: "UTC")!

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    static func context(now: Date) -> PlanningContext {
        PlanningContext(now: now, timeZone: timeZone)
    }

    // MARK: - 固定装置

    struct Fixture {
        var now: Date
        var context: PlanningContext
        var dayKey: StudyDayKey
        var yesterdayKey: StudyDayKey
        var reviewTaskID: UUID
        var knowledgePointID: UUID
        var plan: DailyStudyPlan
        /// 计划范围 2 项、保底 1 项。
        var standardItem: DailyPlanItem
        var manualItem: DailyPlanItem
    }

    static func makeFixture() -> Fixture {
        let now = date(2026, 3, 2, 20, 0)
        let context = context(now: now)
        let dayKey = context.todayKey
        let planID = UUID()
        let reviewTaskID = UUID()
        let knowledgePointID = UUID()

        let standardItem = DailyPlanItem(
            planID: planID,
            source: .reviewTask(reviewTaskID, knowledgePointID: knowledgePointID),
            title: "复习任务 A",
            plannedScope: .tasks(2),
            minimumScope: .tasks(1),
            estimatedMinutes: 30,
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        let manualItem = DailyPlanItem(
            planID: planID,
            source: .manual(note: "自测"),
            title: "手动任务 B",
            plannedScope: .tasks(2),
            minimumScope: .tasks(1),
            estimatedMinutes: 20,
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        let plan = DailyStudyPlan(
            id: planID,
            dayKey: dayKey,
            budget: DailyPlanBudget(capacityMinutes: 120),
            items: [standardItem, manualItem],
            createdAt: now,
            updatedAt: now
        )

        return Fixture(
            now: now,
            context: context,
            dayKey: dayKey,
            yesterdayKey: dayKey.advanced(byDays: -1),
            reviewTaskID: reviewTaskID,
            knowledgePointID: knowledgePointID,
            plan: plan,
            standardItem: standardItem,
            manualItem: manualItem
        )
    }

    /// 用真实契约构造完成事件（与会话/手动完成走同一条路径）。
    static func makeEvent(
        item: DailyPlanItem?,
        source: DailyPlanItemSource?,
        dayKey: StudyDayKey,
        planned: StudyScope?,
        minimum: StudyScope? = nil,
        completed: StudyScope,
        minutes: Int,
        at when: Date,
        assessment: StudyAssessment? = nil,
        note: String = ""
    ) -> CompletionEvent {
        CompletionEvent.make(
            sessionID: nil,
            planID: item?.planID,
            planItemID: item?.id,
            dayKey: dayKey,
            source: source ?? item?.source,
            plannedScope: planned,
            minimumScope: minimum,
            completedScope: completed,
            actualMinutes: minutes,
            completedAt: when,
            assessment: assessment,
            note: note,
            createdAt: when
        )
    }

    /// 完整达标（标准档）。
    static func standardEvent(_ fixture: Fixture) -> CompletionEvent {
        makeEvent(
            item: fixture.standardItem,
            source: nil,
            dayKey: fixture.dayKey,
            planned: fixture.standardItem.plannedScope,
            minimum: fixture.standardItem.minimumScope,
            completed: .tasks(2),
            minutes: 30,
            at: fixture.now
        )
    }

    /// 只到保底档。
    static func minimumEvent(_ fixture: Fixture) -> CompletionEvent {
        makeEvent(
            item: fixture.manualItem,
            source: nil,
            dayKey: fixture.dayKey,
            planned: fixture.manualItem.plannedScope,
            minimum: fixture.manualItem.minimumScope,
            completed: .tasks(1),
            minutes: 10,
            at: fixture.now.addingTimeInterval(-600)
        )
    }

    static func evaluate(
        rules: [EntertainmentRule],
        plan: DailyStudyPlan?,
        events: [CompletionEvent],
        grants: [RewardGrant] = [],
        dayKey: StudyDayKey,
        context: PlanningContext
    ) -> RewardEvaluation {
        var snapshot = StoreSnapshot()
        snapshot.completionEvents = events
        if let plan { snapshot.dailyPlans = [plan] }
        return EntertainmentRewardEvaluator().evaluate(
            rules: rules,
            plan: plan,
            completions: events,
            grants: grants,
            summary: snapshot.dailySummary(for: dayKey),
            context: context
        )
    }

    static func rule(
        _ name: String,
        condition: EntertainmentUnlockCondition,
        targets: [EntertainmentTargetBinding]? = nil,
        repeatWeekdays: [Int]? = nil,
        fallback: EntertainmentFallbackMode = .none,
        rewardMinutes: Int = 30,
        enabled: Bool = true,
        at now: Date
    ) -> EntertainmentRule {
        EntertainmentRule(
            name: name,
            condition: condition,
            targets: targets,
            repeatWeekdays: repeatWeekdays,
            fallback: fallback,
            rewardMinutes: rewardMinutes,
            isEnabled: enabled,
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - 主流程

    static func main() {
        print("E 模块（娱乐解锁与奖励计时）行为验证")

        progressMatchesEvents()
        assessmentDoesNotMatter()
        dayScopeIsRespected()
        targetBindingRequiresSameDay()
        deletedTaskCannotUnlock()
        emptyPlanCannotUnlock()
        revokedEventDoesNotCount()
        duplicateEventCountsOnce()
        legacyAggregateIsUndecidable()
        fallbackTiers()
        reductionToZeroNeverPays()
        oneGrantPerRuleDayTier()
        ruleEditingKeepsHistory()
        weeklyRepeat()
        timerDerivesFromTimestamps()
        singleActiveTimer()
        notificationIsOnlyAnIntent()
        reductionImpactExplanation()
        jsonRoundTripKeepsEligibility()

        print("\n— 共 \(checkCount) 项断言，失败 \(failureCount) 项 —")
        if failureCount > 0 {
            print("E 模块验证失败")
            exit(1)
        }
        print("E 模块验证通过")
    }

    // MARK: 1. 条件进度与完成事件一致

    static func progressMatchesEvents() {
        section("1. 条件进度与真实完成事件一致")
        let fixture = makeFixture()
        let events = [standardEvent(fixture), minimumEvent(fixture)]

        let rules = [
            rule("标准 2 项", condition: .standardItems(2), at: fixture.now),
            rule("保底及以上 2 项", condition: .minimumItems(2), at: fixture.now),
            rule("时长 40 分钟", condition: .minutes(40), at: fixture.now),
            rule("比例 100%", condition: EntertainmentUnlockCondition(metric: .standardCompletionRatio, requiredValue: 1), at: fixture.now)
        ]
        let evaluation = evaluate(
            rules: rules,
            plan: fixture.plan,
            events: events,
            dayKey: fixture.dayKey,
            context: fixture.context
        )

        let standardProgress = evaluation.progress.first { $0.ruleID == rules[0].id }
        checkEqual(standardProgress?.achievedValue, 1, "标准完成数只统计 standard 档")
        checkEqual(standardProgress?.isSatisfied, false, "标准 2 项未达成")

        let minimumProgress = evaluation.progress.first { $0.ruleID == rules[1].id }
        checkEqual(minimumProgress?.achievedValue, 2, "保底口径包含保底完成与标准完成")
        checkEqual(minimumProgress?.isSatisfied, true, "保底及以上 2 项已达成")

        let minutesProgress = evaluation.progress.first { $0.ruleID == rules[2].id }
        checkEqual(minutesProgress?.achievedValue, 40, "记录时长为事件时长之和（30+10）")

        let ratioProgress = evaluation.progress.first { $0.ruleID == rules[3].id }
        checkEqual(ratioProgress?.achievedValue, 0.5, "完成比例为 1/2 项")
        checkEqual(ratioProgress?.isSatisfied, false, "比例 100% 未达成")

        checkEqual(evaluation.pendingGrants.count, 2, "只有达标的两条规则产生待发放奖励（保底 2 项、时长 40 分钟）")
        checkEqual(
            Set(evaluation.pendingGrants.map(\.ruleSnapshot.name)),
            Set(["保底及以上 2 项", "时长 40 分钟"]),
            "发放的正是达标的那两条规则"
        )
        checkEqual(
            evaluation.pendingGrants.first { $0.ruleSnapshot.name == "保底及以上 2 项" }?.basisEventIDs.count,
            2,
            "发放依据记录了 2 条完成事件"
        )
        checkEqual(
            evaluation.pendingGrants.contains { $0.ruleSnapshot.name == "标准 2 项" },
            false,
            "未达标的规则不发放"
        )
    }

    // MARK: 2. 答题正确与否不影响

    static func assessmentDoesNotMatter() {
        section("2. 评分低但确实完成，仍然按规则计入")
        let fixture = makeFixture()
        let poorAssessment = StudyAssessment(totalQuestions: 5, correctQuestions: 0, selfRating: 1)
        let event = makeEvent(
            item: fixture.standardItem,
            source: nil,
            dayKey: fixture.dayKey,
            planned: fixture.standardItem.plannedScope,
            minimum: fixture.standardItem.minimumScope,
            completed: .tasks(2),
            minutes: 25,
            at: fixture.now,
            assessment: poorAssessment
        )

        let rules = [rule("学习 20 分钟", condition: .minutes(20), at: fixture.now)]
        let evaluation = evaluate(
            rules: rules,
            plan: fixture.plan,
            events: [event],
            dayKey: fixture.dayKey,
            context: fixture.context
        )

        checkEqual(event.assessment?.correctQuestions, 0, "事件确实是低正确率")
        checkEqual(evaluation.progress.first?.isSatisfied, true, "低正确率不影响资格")
        checkEqual(evaluation.pendingGrants.count, 1, "低正确率仍然发放奖励")
    }

    // MARK: 3. 学习日边界

    static func dayScopeIsRespected() {
        section("3. 当前学习日不累计前一天的学习量")
        let fixture = makeFixture()
        let yesterdayEvent = makeEvent(
            item: nil,
            source: .reviewTask(fixture.reviewTaskID, knowledgePointID: fixture.knowledgePointID),
            dayKey: fixture.yesterdayKey,
            planned: .tasks(2),
            completed: .tasks(2),
            minutes: 60,
            at: fixture.now.addingTimeInterval(-86_400)
        )

        let rules = [
            rule("昨天不算：时长 30 分钟", condition: .minutes(30), at: fixture.now),
            rule("昨天不算：标准 1 项", condition: .standardItems(1), at: fixture.now)
        ]
        let evaluation = evaluate(
            rules: rules,
            plan: fixture.plan,
            events: [yesterdayEvent],
            dayKey: fixture.dayKey,
            context: fixture.context
        )

        checkEqual(evaluation.progress.count, 2, "生效规则都有进度")
        checkEqual(evaluation.progress.allSatisfy { !$0.isSatisfied }, true, "前一天的事件不满足今天的条件")
        checkEqual(evaluation.pendingGrants.count, 0, "前一天的学习不会发放今天的奖励")
    }

    // MARK: 4. 指定实例绑定

    static func targetBindingRequiresSameDay() {
        section("4. 指定任务 / 知识点绑定必须落在同一天")
        let fixture = makeFixture()

        let itemBoundRule = rule(
            "完成指定计划任务",
            condition: .anyStudied,
            targets: [EntertainmentTargetBinding(kind: .planItem, id: fixture.standardItem.id, dayKey: fixture.dayKey, displayName: fixture.standardItem.title)],
            at: fixture.now
        )
        let pointBoundRule = rule(
            "完成指定知识点",
            condition: .anyStudied,
            targets: [EntertainmentTargetBinding(kind: .knowledgePoint, id: fixture.knowledgePointID, dayKey: nil, displayName: "知识点 X")],
            at: fixture.now
        )

        // 只有昨天的记录（同一个复习任务 / 同一个知识点）。
        let yesterdayEvent = makeEvent(
            item: nil,
            source: .reviewTask(fixture.reviewTaskID, knowledgePointID: fixture.knowledgePointID),
            dayKey: fixture.yesterdayKey,
            planned: .tasks(2),
            completed: .tasks(2),
            minutes: 40,
            at: fixture.now.addingTimeInterval(-86_400)
        )
        let yesterday = evaluate(
            rules: [itemBoundRule, pointBoundRule],
            plan: fixture.plan,
            events: [yesterdayEvent],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(yesterday.progress.allSatisfy { !$0.isSatisfied }, true, "昨天完成同一个知识点不会解锁今天")
        checkEqual(yesterday.pendingGrants.count, 0, "绑定条件未达成时不发放奖励")
        check(
            yesterday.explanation.contains { $0.contains("其他学习日") || $0.contains("还没有完成") },
            "给出未达成原因，而不是静默通过"
        )

        // 今天完成同一条计划任务。
        let today = evaluate(
            rules: [itemBoundRule, pointBoundRule],
            plan: fixture.plan,
            events: [standardEvent(fixture)],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(today.progress.allSatisfy(\.isSatisfied), true, "今天完成指定实例后两条绑定规则都达标")
        checkEqual(today.pendingGrants.count, 2, "两条规则各发放一次")

        // 绑定自带的学习日若不是今天，直接不适用。
        let otherDayRule = rule(
            "绑定昨天实例",
            condition: .anyStudied,
            targets: [EntertainmentTargetBinding(kind: .planItem, id: fixture.standardItem.id, dayKey: fixture.yesterdayKey, displayName: "昨天的任务")],
            at: fixture.now
        )
        let otherDay = evaluate(
            rules: [otherDayRule],
            plan: fixture.plan,
            events: [standardEvent(fixture)],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(otherDay.pendingGrants.count, 0, "绑定属于其他学习日时今天不适用")
        check(otherDay.explanation.contains { $0.contains("其他学习日") }, "说明绑定属于其他学习日")
    }

    // MARK: 5. 删除任务

    static func deletedTaskCannotUnlock() {
        section("5. 删除任务不等于完成任务")
        let fixture = makeFixture()
        let boundRule = rule(
            "完成指定计划任务",
            condition: .anyStudied,
            targets: [EntertainmentTargetBinding(kind: .planItem, id: fixture.standardItem.id, dayKey: fixture.dayKey, displayName: fixture.standardItem.title)],
            at: fixture.now
        )

        // 计划被重排：绑定的任务不在了，但用户完成了剩下的任务。
        let remainingItem = fixture.manualItem
        let regeneratedPlan = DailyStudyPlan(
            dayKey: fixture.dayKey,
            version: 2,
            budget: DailyPlanBudget(capacityMinutes: 60),
            items: [remainingItem],
            createdAt: fixture.now,
            updatedAt: fixture.now
        )
        let otherEvent = makeEvent(
            item: remainingItem,
            source: nil,
            dayKey: fixture.dayKey,
            planned: remainingItem.plannedScope,
            minimum: remainingItem.minimumScope,
            completed: .tasks(2),
            minutes: 20,
            at: fixture.now
        )
        let deleted = evaluate(
            rules: [boundRule],
            plan: regeneratedPlan,
            events: [otherEvent],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(deleted.pendingGrants.count, 0, "绑定任务被删除后不自动解锁")
        check(
            deleted.explanation.contains { $0.contains("需要调整") },
            "提示规则需要调整"
        )
        checkEqual(deleted.progress.first?.isSatisfied, false, "进度如实显示未达成")

        // 复习实例被删除（计划里已没有引用它的任务）。
        let reviewBoundRule = rule(
            "完成指定复习实例",
            condition: .anyStudied,
            targets: [EntertainmentTargetBinding(kind: .reviewTask, id: fixture.reviewTaskID, dayKey: nil, displayName: "复习任务 A")],
            at: fixture.now
        )
        let orphanPlan = DailyStudyPlan(
            dayKey: fixture.dayKey,
            version: 3,
            budget: DailyPlanBudget(capacityMinutes: 60),
            items: [remainingItem],
            createdAt: fixture.now,
            updatedAt: fixture.now
        )
        let orphan = evaluate(
            rules: [reviewBoundRule],
            plan: orphanPlan,
            events: [otherEvent],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(orphan.pendingGrants.count, 0, "复习实例已不在计划中时不自动解锁")
        check(orphan.explanation.contains { $0.contains("可能已被删除") }, "提示可能已删除，需要用户确认")
    }

    // MARK: 6. 空计划

    static func emptyPlanCannotUnlock() {
        section("6. 无任务、无学习记录的空计划不能解锁")
        let fixture = makeFixture()
        let rules = [
            rule("全部完成比例", condition: EntertainmentUnlockCondition(metric: .standardCompletionRatio, requiredValue: 1), at: fixture.now),
            rule("标准 1 项", condition: .standardItems(1), at: fixture.now),
            rule("当天有学习", condition: .anyStudied, at: fixture.now),
            rule("时长 10 分钟", condition: .minutes(10), fallback: .unlockRegardless, at: fixture.now),
            rule("保底固定时长", condition: .minimumItems(1), fallback: .fixedMinimumReward(minutes: 15), rewardMinutes: 30, at: fixture.now)
        ]

        let emptyPlan = DailyStudyPlan(
            dayKey: fixture.dayKey,
            budget: DailyPlanBudget(capacityMinutes: 0),
            items: [],
            createdAt: fixture.now,
            updatedAt: fixture.now
        )
        let evaluation = evaluate(
            rules: rules,
            plan: emptyPlan,
            events: [],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(evaluation.progress.allSatisfy { !$0.isSatisfied }, true, "空计划下所有条件都不满足")
        checkEqual(evaluation.pendingGrants.count, 0, "空计划不发放任何奖励")
        checkEqual(evaluation.progress.first?.achievedValue, 0, "空计划完成比例为 0，而不是 100%")

        // 没有计划对象时同样不解锁。
        let noPlan = evaluate(
            rules: rules,
            plan: nil,
            events: [],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(noPlan.pendingGrants.count, 0, "没有计划对象时同样不发放奖励")

        // 绑定计划的规则在空计划下要给出明确说明。
        let boundRule = rule(
            "完成指定计划任务",
            condition: .anyStudied,
            targets: [EntertainmentTargetBinding(kind: .planItem, id: fixture.standardItem.id, dayKey: fixture.dayKey, displayName: fixture.standardItem.title)],
            at: fixture.now
        )
        let boundEmpty = evaluate(
            rules: [boundRule],
            plan: emptyPlan,
            events: [],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        check(
            boundEmpty.explanation.contains { $0.contains("今天没有任何计划任务") },
            "空计划时说明没有计划任务"
        )
    }

    // MARK: 7. 撤销事件

    static func revokedEventDoesNotCount() {
        section("7. 撤销的完成事件不计入")
        let fixture = makeFixture()
        let revoked = standardEvent(fixture).revoked(at: fixture.now, reason: "误操作")
        let rules = [rule("标准 1 项", condition: .standardItems(1), at: fixture.now)]

        let evaluation = evaluate(
            rules: rules,
            plan: fixture.plan,
            events: [revoked],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(evaluation.progress.first?.achievedValue, 0, "撤销事件不进入进度")
        checkEqual(evaluation.pendingGrants.count, 0, "撤销后不发放奖励")
    }

    // MARK: 8. 重复事件

    static func duplicateEventCountsOnce() {
        section("8. 同一事件不会重复累计")
        let fixture = makeFixture()
        let event = standardEvent(fixture)
        let rules = [rule("标准 2 项", condition: .standardItems(2), at: fixture.now)]

        let duplicated = evaluate(
            rules: rules,
            plan: fixture.plan,
            events: [event, event],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(duplicated.progress.first?.achievedValue, 1, "同一个事件传入两次仍只算 1 次")
        checkEqual(duplicated.pendingGrants.count, 0, "重复事件不会把条件凑够")

        // 不同 id、相同幂等键（防御性去重）。
        var twin = event
        twin.id = UUID()
        let twinEvaluation = evaluate(
            rules: rules,
            plan: fixture.plan,
            events: [event, twin],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(twinEvaluation.progress.first?.achievedValue, 1, "相同幂等键的事件只算 1 次")

        // 同一条计划项在同一天只有一条稳定记录（幂等键 = 计划项 + 学习日）。
        let partial = makeEvent(
            item: fixture.standardItem,
            source: nil,
            dayKey: fixture.dayKey,
            planned: fixture.standardItem.plannedScope,
            minimum: fixture.standardItem.minimumScope,
            completed: .tasks(1),
            minutes: 10,
            at: fixture.now.addingTimeInterval(-120)
        )
        checkEqual(partial.idempotencyKey, event.idempotencyKey, "同一条计划项在同一天共用同一个幂等键")
        checkEqual(partial.tier, .minimum, "部分完成单独记为保底档，不当作整体完成")
        let partialEvaluation = evaluate(
            rules: rules,
            plan: fixture.plan,
            events: [partial],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(partialEvaluation.progress.first?.achievedValue, 0, "只到保底的记录不计入标准完成数")
        checkEqual(partialEvaluation.progress.first?.isSatisfied, false, "只到保底时不满足标准 2 项")
    }

    // MARK: 9. 旧聚合数据

    static func legacyAggregateIsUndecidable() {
        section("9. 旧版本每日完成总数不可判定")
        let fixture = makeFixture()
        var snapshot = StoreSnapshot()
        snapshot.dailyActivityRecords = [DailyActivityRecord(date: fixture.now, completedTaskCount: 3)]

        let rules = [rule("标准 1 项", condition: .standardItems(1), at: fixture.now)]
        let evaluation = EntertainmentRewardEvaluator().evaluate(
            rules: rules,
            plan: nil,
            completions: [],
            grants: [],
            summary: snapshot.dailySummary(for: fixture.dayKey),
            context: fixture.context
        )

        checkEqual(evaluation.progress.count, 0, "不可判定时不编造进度")
        checkEqual(evaluation.eligibleRuleRevisionIDs.count, 0, "旧数据不产生资格")
        checkEqual(evaluation.pendingGrants.count, 0, "旧数据不补发奖励")
        checkEqual(evaluation.undecidableRuleRevisionIDs, [rules[0].revisionID], "明确标记为不可判定")
        check(
            evaluation.explanation.contains { $0.contains("无法判定娱乐资格") },
            "给出不可判定的说明"
        )
    }

    // MARK: 10. 保底档位

    static func fallbackTiers() {
        section("10. 保底奖励单独设置，且不默认发标准奖励")
        let fixture = makeFixture()
        let minimumOnly = [minimumEvent(fixture)]

        let standardRule = rule("标准 2 项", condition: .standardItems(2), fallback: .none, rewardMinutes: 30, at: fixture.now)
        let fixedRule = rule("保底固定 10 分钟", condition: .standardItems(2), fallback: .fixedMinimumReward(minutes: 10), rewardMinutes: 30, at: fixture.now)
        let scaledRule = rule("按比例 50%", condition: .standardItems(2), fallback: .scaledReward(ratio: 0.5), rewardMinutes: 30, at: fixture.now)
        let suspendRule = rule("当天不发放", condition: .standardItems(2), fallback: .suspend, rewardMinutes: 30, at: fixture.now)

        let notSatisfied = evaluate(
            rules: [standardRule, fixedRule, scaledRule, suspendRule],
            plan: fixture.plan,
            events: minimumOnly,
            dayKey: fixture.dayKey,
            context: fixture.context
        )

        checkEqual(notSatisfied.pendingGrants.count, 2, "只有开启保底的两条规则发放")
        checkEqual(
            notSatisfied.pendingGrants.first { $0.ruleSnapshot.name == "保底固定 10 分钟" }?.grantedMinutes,
            10,
            "保底固定时长发放 10 分钟，而不是标准 30 分钟"
        )
        checkEqual(
            notSatisfied.pendingGrants.first { $0.ruleSnapshot.name == "按比例 50%" }?.grantedMinutes,
            15,
            "按比例保底发放 30×50% = 15 分钟"
        )
        checkEqual(
            notSatisfied.pendingGrants.contains { $0.ruleSnapshot.name == "标准 2 项" },
            false,
            "未开启保底的规则不发奖励"
        )
        checkEqual(
            notSatisfied.pendingGrants.contains { $0.ruleSnapshot.name == "当天不发放" },
            false,
            "suspend 保底方式当天不发奖励"
        )

        // 标准达标时走标准档位，而不是保底档位。
        let satisfiedRule = rule("标准 1 项达标", condition: .standardItems(1), fallback: .fixedMinimumReward(minutes: 10), rewardMinutes: 30, at: fixture.now)
        let satisfied = evaluate(
            rules: [satisfiedRule],
            plan: fixture.plan,
            events: [standardEvent(fixture)],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(satisfied.pendingGrants.first?.grantedMinutes, 30, "标准达标发放完整时长")

        // 保底发放要如实说明档位差异。
        check(
            notSatisfied.explanation.contains { $0.contains("保底") && $0.contains("标准档位为 30 分钟") },
            "保底发放时说明与标准档位的差异"
        )
    }

    // MARK: 11. 减量到零

    static func reductionToZeroNeverPays() {
        section("11. 不断减量到零拿不到奖励")
        let fixture = makeFixture()

        // 模拟 10 次减量：计划任务被压缩到 0 范围、用户没有任何学习记录。
        let zeroItem = DailyPlanItem(
            planID: UUID(),
            source: .manual(note: "被减到零"),
            title: "手动任务 B",
            plannedScope: .tasks(0),
            minimumScope: .tasks(0),
            estimatedMinutes: 0,
            scheduledDayKey: fixture.dayKey,
            createdAt: fixture.now,
            updatedAt: fixture.now
        )
        let reducedPlan = DailyStudyPlan(
            dayKey: fixture.dayKey,
            version: 9,
            mode: .minimum,
            budget: DailyPlanBudget(capacityMinutes: 0),
            items: [zeroItem],
            createdAt: fixture.now,
            updatedAt: fixture.now
        )
        let zeroEvent = makeEvent(
            item: zeroItem,
            source: nil,
            dayKey: fixture.dayKey,
            planned: .tasks(0),
            minimum: .tasks(0),
            completed: .tasks(0),
            minutes: 0,
            at: fixture.now
        )

        let rules = [
            rule("已学习 1 项", condition: EntertainmentUnlockCondition(metric: .studiedItemCount, requiredValue: 1), fallback: .scaledReward(ratio: 0.9), rewardMinutes: 60, at: fixture.now),
            rule("始终解锁", condition: .standardItems(1), fallback: .unlockRegardless, rewardMinutes: 60, at: fixture.now),
            rule("保底固定", condition: .minimumItems(1), fallback: .fixedMinimumReward(minutes: 30), rewardMinutes: 60, at: fixture.now)
        ]

        for round in 1...10 {
            let evaluation = evaluate(
                rules: rules,
                plan: reducedPlan,
                events: [zeroEvent],
                dayKey: fixture.dayKey,
                context: fixture.context
            )
            checkEqual(evaluation.pendingGrants.count, 0, "第 \(round) 次减量到零仍然不发奖励")
            checkEqual(evaluation.eligibleRuleRevisionIDs.count, 0, "第 \(round) 次减量到零不产生资格")
        }

        let last = evaluate(
            rules: rules,
            plan: reducedPlan,
            events: [zeroEvent],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(last.progress.first?.achievedValue, 0, "0 范围的完成记录不算已学习")
        check(
            last.explanation.contains { $0.contains("没有有效学习记录") },
            "说明保底不发放的原因是没有学习记录"
        )
    }

    // MARK: 12. 幂等发放

    static func oneGrantPerRuleDayTier() {
        section("12. 同一规则、同一学习日、同一档位只发放一次")
        let fixture = makeFixture()
        let base = rule("标准 1 项", condition: .standardItems(1), rewardMinutes: 30, at: fixture.now)
        let events = [standardEvent(fixture)]

        let first = evaluate(rules: [base], plan: fixture.plan, events: events, dayKey: fixture.dayKey, context: fixture.context)
        checkEqual(first.pendingGrants.count, 1, "达标后发放一次")

        let second = evaluate(
            rules: [base],
            plan: fixture.plan,
            events: events,
            grants: first.pendingGrants,
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(second.pendingGrants.count, 0, "页面刷新不会重复新增奖励")
        checkEqual(second.eligibleRuleRevisionIDs.count, 1, "资格仍然为真，只是不再新增记录")

        // 启停切换：版本号变化，但发放语义相同 → 不重复发放。
        let disabled = base.revised(isEnabled: false, at: fixture.now)
        let reEnabled = disabled.revised(isEnabled: true, at: fixture.now)
        check(reEnabled.revisionID != base.revisionID, "启停切换确实产生了新版本 ID")
        let afterToggle = evaluate(
            rules: [reEnabled],
            plan: fixture.plan,
            events: events,
            grants: first.pendingGrants,
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(afterToggle.pendingGrants.count, 0, "关掉再打开不会多领一次")

        // 只改展示文案：同样不重复发放。
        let relabeled = base.revised(
            condition: EntertainmentUnlockCondition(metric: .standardCompletedItemCount, requiredValue: 1, label: "换个说法"),
            at: fixture.now
        )
        let afterRelabel = evaluate(
            rules: [relabeled],
            plan: fixture.plan,
            events: events,
            grants: first.pendingGrants,
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(afterRelabel.pendingGrants.count, 0, "只改展示文案不会重复发放")

        // 真正改变档位也不会让同一学习日的既有学习记录再次产生收益。
        let edited = base.revised(rewardMinutes: 45, at: fixture.now)
        let afterEdit = evaluate(
            rules: [edited],
            plan: fixture.plan,
            events: events,
            grants: first.pendingGrants,
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(afterEdit.pendingGrants.count, 0, "实质性编辑不会对同一学习日重复发奖")
        checkEqual(first.pendingGrants.first?.grantedMinutes, 30, "旧记录仍然是 30 分钟")

        // 发放键由学习日 + 规则版本构成。
        let key = RewardGrant.Key.make(ruleRevisionID: base.revisionID, dayKey: fixture.dayKey)
        checkEqual(first.pendingGrants.first?.grantKey, key, "发放键 = 学习日 + 规则版本")
        checkEqual(
            first.pendingGrants.first?.grantKey.contains(fixture.dayKey.localDateString),
            true,
            "发放键包含学习日，跨日不会撞键"
        )
    }

    // MARK: 13. 规则版本与历史

    static func ruleEditingKeepsHistory() {
        section("13. 规则编辑保留版本，历史奖励不被改写")
        let fixture = makeFixture()
        let original = rule("晚间游戏", condition: .standardItems(1), fallback: .fixedMinimumReward(minutes: 10), rewardMinutes: 30, at: fixture.now)
        let evaluation = evaluate(rules: [original], plan: fixture.plan, events: [standardEvent(fixture)], dayKey: fixture.dayKey, context: fixture.context)
        guard let grant = evaluation.pendingGrants.first else {
            check(false, "前置条件：应当先发放一条奖励")
            return
        }

        let edited = original.revised(name: "晚间游戏（改名）", fallback: EntertainmentFallbackMode.none, rewardMinutes: 60, at: fixture.now.addingTimeInterval(60))
        checkEqual(edited.ruleVersion, original.ruleVersion + 1, "编辑后版本号 +1")
        check(edited.revisionID != original.revisionID, "编辑后版本身份变化")

        // 历史奖励保留当时的规则快照。
        checkEqual(grant.ruleSnapshot.name, "晚间游戏", "历史奖励保留当时的规则名称")
        checkEqual(grant.ruleSnapshot.rewardMinutes, 30, "历史奖励保留当时的奖励时长")
        checkEqual(grant.ruleSnapshot.ruleVersion, original.ruleVersion, "历史奖励保留当时的版本号")
        checkEqual(grant.ruleSnapshot.revisionID, original.revisionID, "历史奖励保留当时的版本身份")
        checkEqual(grant.ruleSnapshot.fallback, .fixedMinimumReward(minutes: 10), "历史奖励保留当时的保底方式")

        // 规则被归档/停用后，既有奖励仍然可读、可领取。
        let archived = edited.revised(isEnabled: false, at: fixture.now)
        checkEqual(archived.isUsable, false, "停用后规则不再生效")
        checkEqual(grant.isClaimable, true, "既有奖励不因规则停用而失效")
        let afterArchive = evaluate(
            rules: [archived],
            plan: fixture.plan,
            events: [standardEvent(fixture)],
            grants: [grant],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(afterArchive.progress.count, 0, "停用的规则不再出现在进度里")
        checkEqual(afterArchive.pendingGrants.count, 0, "停用的规则不发新奖励")
    }

    // MARK: 14. 每周重复

    static func weeklyRepeat() {
        section("14. 每周重复日期")
        let fixture = makeFixture()
        guard let start = fixture.dayKey.startOfDay(calendar: fixture.context.calendar) else {
            check(false, "前置条件：学习日应能换算成零点")
            return
        }
        let todayWeekday = fixture.context.calendar.component(.weekday, from: start)
        let otherWeekday = todayWeekday == 1 ? 3 : 1

        let onToday = rule("今天生效", condition: .standardItems(1), repeatWeekdays: [todayWeekday], at: fixture.now)
        let onOtherDay = rule("其他星期生效", condition: .standardItems(1), repeatWeekdays: [otherWeekday], at: fixture.now)

        checkEqual(onToday.isEffective(on: fixture.dayKey, calendar: fixture.context.calendar), true, "命中今天的星期时生效")
        checkEqual(onOtherDay.isEffective(on: fixture.dayKey, calendar: fixture.context.calendar), false, "不命中今天的星期时不生效")
        checkEqual(onOtherDay.occursEveryDay, false, "设置了每周重复就不是每天")
        check(onOtherDay.repeatText.contains("周"), "重复规则有可读文案：\(onOtherDay.repeatText)")

        let evaluation = evaluate(
            rules: [onToday, onOtherDay],
            plan: fixture.plan,
            events: [standardEvent(fixture)],
            dayKey: fixture.dayKey,
            context: fixture.context
        )
        checkEqual(evaluation.progress.count, 1, "只评估今天生效的规则")
        checkEqual(evaluation.pendingGrants.count, 1, "只有今天生效的规则会发放")
        checkEqual(evaluation.pendingGrants.first?.ruleSnapshot.name, "今天生效", "发放给命中的那条规则")

        // 生效区间同样受支持。
        let expired = rule("已结束的规则", condition: .standardItems(1), at: fixture.now)
        let expiredRule = EntertainmentRule(
            name: expired.name,
            effectiveFrom: fixture.yesterdayKey.advanced(byDays: -10),
            effectiveUntil: fixture.yesterdayKey,
            condition: expired.condition,
            rewardMinutes: expired.rewardMinutes,
            createdAt: fixture.now,
            updatedAt: fixture.now
        )
        checkEqual(expiredRule.isEffective(on: fixture.dayKey), false, "超出生效区间后不再生效")
        checkEqual(expiredRule.isEffective(on: fixture.yesterdayKey), true, "生效区间内生效")
    }

    // MARK: 15. 计时推导

    static func timerDerivesFromTimestamps() {
        section("15. 计时完全由持久化时间戳推导")
        let fixture = makeFixture()
        let granted = RewardGrant.make(
            ruleSnapshot: rule("晚间游戏", condition: .standardItems(1), rewardMinutes: 30, at: fixture.now).snapshotValue,
            dayKey: fixture.dayKey,
            basisEventIDs: [standardEvent(fixture).id],
            conditionProgress: RewardConditionProgress(
                ruleID: UUID(),
                ruleRevisionID: UUID(),
                metric: .standardCompletedItemCount,
                achievedValue: 1,
                requiredValue: 1,
                isSatisfied: true
            ),
            grantedMinutes: 30,
            grantedAt: fixture.now
        )
        guard let started = granted.started(at: fixture.now) else {
            check(false, "前置条件：待领取奖励应当可以开始")
            return
        }

        let t0 = fixture.now
        checkEqual(EntertainmentSessionEngine.remainingSeconds(for: started, at: t0), 1_800, "刚开始时剩余 30 分钟")
        checkEqual(EntertainmentSessionEngine.remainingSeconds(for: started, at: t0.addingTimeInterval(600)), 1_200, "10 分钟后剩余 20 分钟")
        checkEqual(EntertainmentSessionEngine.endsAt(for: started), t0.addingTimeInterval(1_800), "结束时刻 = 开始时刻 + 时长")

        // "切后台 / 杀进程后重启"：只用持久化字段重算，没有任何内存计时器。
        let encoded = try? JSONEncoder().encode(started)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(RewardGrant.self, from: $0) }
        check(decoded != nil, "奖励记录可以持久化往返")
        checkEqual(
            EntertainmentSessionEngine.remainingSeconds(for: decoded ?? started, at: t0.addingTimeInterval(900)),
            900,
            "重启后按保存的时间重算剩余时长"
        )

        let mid = EntertainmentSessionEngine.snapshot(for: started, at: t0.addingTimeInterval(300), context: fixture.context, runningGrantID: started.id)
        checkEqual(mid.state, .running, "运行中状态")
        checkEqual(mid.remainingMinutesCeiling, 25, "剩余分钟数向上取整显示")

        let finish = EntertainmentSessionEngine.step(.finish, grant: started, at: t0.addingTimeInterval(300), context: fixture.context, runningGrantID: started.id)
        checkEqual(finish.intents.contains(.requestFinish(grantID: started.id, usedMinutes: 5)), true, "结束计时按已用 5 分钟记账")
        let cancelled = finish.intents.contains {
            if case .cancelEndNotification(let grantID, let title) = $0 {
                return grantID == started.id && title == EntertainmentSessionEngine.endNotificationTitle(ruleName: "晚间游戏")
            }
            return false
        }
        checkEqual(cancelled, true, "结束时按同一标题取消到时提醒")

        let timeUp = EntertainmentSessionEngine.step(.refresh, grant: started, at: t0.addingTimeInterval(1_800), context: fixture.context, runningGrantID: started.id)
        checkEqual(timeUp.intents.contains(.requestFinish(grantID: started.id, usedMinutes: 30)), true, "到点后自动结算整段时长")
        checkEqual(timeUp.snapshot.remainingSeconds, 0, "到点后剩余为 0")

        // 已结束的奖励不可再开始。
        guard let finished = started.finished(at: t0.addingTimeInterval(300), usedMinutes: 5) else {
            check(false, "前置条件：开始中的奖励应当可以结束")
            return
        }
        let restart = EntertainmentSessionEngine.step(.start, grant: finished, at: t0.addingTimeInterval(400), context: fixture.context, runningGrantID: nil)
        checkEqual(restart.intents.count, 0, "已结束的奖励不能重新开始")
        check(restart.rejection != nil, "重新开始会被明确拒绝")
        checkEqual(EntertainmentSessionEngine.snapshot(for: finished, at: t0.addingTimeInterval(400), context: fixture.context, runningGrantID: nil).state, .finished, "已结束状态保持")
    }

    // MARK: 16. 单计时与当天使用

    static func singleActiveTimer() {
        section("16. 一次仅一个计时；跨天奖励拒绝开始")
        let fixture = makeFixture()
        let ruleSnapshot = rule("晚间游戏", condition: .standardItems(1), rewardMinutes: 30, at: fixture.now).snapshotValue
        let progress = RewardConditionProgress(
            ruleID: ruleSnapshot.ruleID,
            ruleRevisionID: ruleSnapshot.revisionID,
            metric: .standardCompletedItemCount,
            achievedValue: 1,
            requiredValue: 1,
            isSatisfied: true
        )
        let todayGrant = RewardGrant.make(
            ruleSnapshot: ruleSnapshot,
            dayKey: fixture.dayKey,
            basisEventIDs: [],
            conditionProgress: progress,
            grantedMinutes: 30,
            grantedAt: fixture.now
        )
        let yesterdayGrant = RewardGrant.make(
            ruleSnapshot: ruleSnapshot,
            dayKey: fixture.yesterdayKey,
            basisEventIDs: [],
            conditionProgress: progress,
            grantedMinutes: 30,
            grantedAt: fixture.now.addingTimeInterval(-86_400)
        )

        guard let runningA = todayGrant.started(at: fixture.now),
              let runningB = yesterdayGrant.started(at: fixture.now.addingTimeInterval(-86_400)) else {
            check(false, "前置条件：奖励应当可以开始")
            return
        }

        checkEqual(EntertainmentSessionEngine.runningGrant(in: [runningA, runningB])?.id, runningA.id, "能识别正在计时的奖励")

        let blocked = EntertainmentSessionEngine.step(
            .start,
            grant: todayGrant,
            at: fixture.now,
            context: fixture.context,
            runningGrantID: runningB.id
        )
        checkEqual(blocked.intents.count, 0, "已有计时在运行时不能再开一个")
        checkEqual(blocked.rejection?.contains("只能运行一个") ?? false, true, "拒绝原因说明只能有一个计时")

        let sameGrant = EntertainmentSessionEngine.step(
            .start,
            grant: todayGrant,
            at: fixture.now,
            context: fixture.context,
            runningGrantID: todayGrant.id
        )
        checkEqual(sameGrant.intents.count, 0, "同一条奖励已在计时时不重复开始")
        checkEqual(sameGrant.statusText.contains("已经在计时中"), true, "如实提示已经在计时中")

        // 昨天领取、从未开始的奖励：默认当天使用，今天拒绝开始。
        let stale = EntertainmentSessionEngine.step(
            .start,
            grant: yesterdayGrant,
            at: fixture.now,
            context: fixture.context,
            runningGrantID: nil
        )
        checkEqual(stale.intents.count, 0, "跨天奖励拒绝开始，不会无限累积")
        checkEqual(stale.snapshot.state, .unavailable, "跨天奖励标记为已失效")
        checkEqual(
            EntertainmentSessionEngine.staleGrantIDs(in: [todayGrant, yesterdayGrant], before: fixture.dayKey),
            [yesterdayGrant.id],
            "能列出需要过期的历史奖励"
        )

        // 开始时给出"到时提醒需求"，并带上正确的到点时间。
        let start = EntertainmentSessionEngine.step(
            .start,
            grant: todayGrant,
            at: fixture.now,
            context: fixture.context,
            runningGrantID: nil
        )
        checkEqual(start.intents.contains(.requestStart(grantID: todayGrant.id)), true, "开始计时需要 G 落盘")
        let scheduled = start.intents.compactMap { intent -> Date? in
            if case .scheduleEndNotification(_, let fireDate, _) = intent { return fireDate }
            return nil
        }
        checkEqual(scheduled.first, fixture.now.addingTimeInterval(1_800), "到时提醒的时间 = 剩余时长之后")

        // 跨天且在计时中：刷新时自动结算，不会永远挂着。
        let crossDay = EntertainmentSessionEngine.step(
            .refresh,
            grant: runningB,
            at: fixture.now,
            context: fixture.context,
            runningGrantID: runningB.id
        )
        checkEqual(crossDay.intents.contains(.requestFinish(grantID: runningB.id, usedMinutes: 30)), true, "跨天的计时会被结算")
    }

    // MARK: 17. 通知只是意图

    static func notificationIsOnlyAnIntent() {
        section("17. 到时只返回通知需求；无通知权限不影响页面内计时")
        let fixture = makeFixture()
        let ruleSnapshot = rule("晚间游戏", condition: .standardItems(1), rewardMinutes: 20, at: fixture.now).snapshotValue
        let grant = RewardGrant.make(
            ruleSnapshot: ruleSnapshot,
            dayKey: fixture.dayKey,
            basisEventIDs: [],
            conditionProgress: RewardConditionProgress(
                ruleID: ruleSnapshot.ruleID,
                ruleRevisionID: ruleSnapshot.revisionID,
                metric: .standardCompletedItemCount,
                achievedValue: 1,
                requiredValue: 1,
                isSatisfied: true
            ),
            grantedMinutes: 20,
            grantedAt: fixture.now
        )
        guard let started = grant.started(at: fixture.now) else {
            check(false, "前置条件：奖励应当可以开始")
            return
        }
        let transition = EntertainmentSessionEngine.step(.start, grant: grant, at: fixture.now, context: fixture.context, runningGrantID: nil)
        checkEqual(transition.intents.filter(\.isNotificationIntent).count, 1, "开始计时只产生 1 条通知意图")
        checkEqual(
            transition.intents.contains { if case .scheduleEndNotification = $0 { return true } else { return false } },
            true,
            "通知意图是 scheduleEndNotification（由 G 真正发送）"
        )
        checkEqual(transition.intents.contains { if case .requestStart = $0 { return true } else { return false } }, true, "落盘意图交给 G")

        // 页面内计时不依赖通知：即使没有任何通知意图，剩余时长照样可算。
        let snapshot = EntertainmentSessionEngine.snapshot(
            for: started,
            at: fixture.now.addingTimeInterval(300),
            context: fixture.context,
            runningGrantID: started.id
        )
        checkEqual(snapshot.remainingSeconds, 900, "没有通知权限时页面内计时仍然正确")
        checkEqual(snapshot.state, .running, "没有通知权限时状态仍然正确")
    }

    // MARK: 18. 减量影响说明

    static func reductionImpactExplanation() {
        section("18. 减量预览返回奖励影响说明")
        let fixture = makeFixture()
        let trimmedItem = DailyPlanItem(
            id: fixture.manualItem.id,
            planID: fixture.plan.id,
            source: fixture.manualItem.source,
            title: fixture.manualItem.title,
            plannedScope: fixture.manualItem.plannedScope,
            minimumScope: fixture.manualItem.minimumScope,
            estimatedMinutes: 10,
            scheduledDayKey: fixture.dayKey,
            createdAt: fixture.now,
            updatedAt: fixture.now
        )
        let minimumPlan = DailyStudyPlan(
            id: fixture.plan.id,
            dayKey: fixture.dayKey,
            version: 2,
            mode: .minimum,
            budget: DailyPlanBudget(capacityMinutes: 20),
            items: [trimmedItem],
            createdAt: fixture.now,
            updatedAt: fixture.now
        )

        let fixedRule = rule("保底固定 10 分钟", condition: .standardItems(2), fallback: .fixedMinimumReward(minutes: 10), rewardMinutes: 30, at: fixture.now)
        let strictRule = rule("严格标准", condition: .standardItems(2), fallback: .none, rewardMinutes: 30, at: fixture.now)
        let minuteRule = rule("固定时长 60 分钟", condition: .minutes(60), fallback: .scaledReward(ratio: 0.5), rewardMinutes: 30, at: fixture.now)
        let boundRule = rule(
            "指定任务",
            condition: .anyStudied,
            targets: [EntertainmentTargetBinding(kind: .planItem, id: fixture.standardItem.id, dayKey: fixture.dayKey, displayName: fixture.standardItem.title)],
            at: fixture.now
        )

        let impacts = EntertainmentRewardImpactAdvisor.impacts(
            rules: [fixedRule, strictRule, minuteRule, boundRule],
            plan: fixture.plan,
            minimumPlan: minimumPlan,
            completions: [],
            summary: StoreSnapshot().dailySummary(for: fixture.dayKey),
            context: fixture.context
        )

        checkEqual(impacts.count, 4, "每条生效规则都给出一条影响说明")
        let fixed = impacts.first { $0.ruleID == fixedRule.id }
        checkEqual(fixed?.standardMinutes, 30, "标准档位为 30 分钟")
        checkEqual(fixed?.reducedMinutes, 10, "减量后按保底发放 10 分钟")
        checkEqual(fixed?.losesEntitlement, false, "减量后仍然有奖励")
        check(fixed?.lines.first?.contains("降为 10 分钟") ?? false, "说明明确写出降为多少分钟：\(fixed?.lines.first ?? "")")

        let strict = impacts.first { $0.ruleID == strictRule.id }
        checkEqual(strict?.reducedMinutes, 0, "没有保底时减量后拿不到奖励")
        checkEqual(strict?.losesEntitlement, true, "明确标记失去奖励")
        check(strict?.lines.first?.contains("拿不到奖励") ?? false, "说明写清拿不到奖励")

        let minute = impacts.first { $0.ruleID == minuteRule.id }
        checkEqual(minute?.conditionIsReductionProof, true, "固定时长条件不受减量影响")
        check(minute?.lines.first?.contains("不受自动减量影响") ?? false, "固定时长条件给出对应说明")

        let bound = impacts.first { $0.ruleID == boundRule.id }
        checkEqual(bound?.conditionIsReductionProof, true, "指定任务条件不受减量影响")

        // 空保底计划：明确说明没有可执行的保底任务。
        let emptyImpacts = EntertainmentRewardImpactAdvisor.impacts(
            rules: [fixedRule],
            plan: fixture.plan,
            minimumPlan: nil,
            completions: [],
            summary: StoreSnapshot().dailySummary(for: fixture.dayKey),
            context: fixture.context
        )
        check(emptyImpacts.first?.lines.first?.contains("没有可执行的保底任务") ?? false, "没有保底任务时说明清楚")
    }

    // MARK: 19. 重启后资格一致

    static func jsonRoundTripKeepsEligibility() {
        section("19. 规则与奖励经 JSON 往返后资格一致（重启一致）")
        let fixture = makeFixture()
        let targets = [EntertainmentTargetBinding(kind: .planItem, id: fixture.standardItem.id, dayKey: fixture.dayKey, displayName: fixture.standardItem.title)]
        let stored = rule(
            "完成指定计划任务",
            condition: .anyStudied,
            targets: targets,
            repeatWeekdays: [2, 4, 6],
            fallback: .fixedMinimumReward(minutes: 10),
            rewardMinutes: 45,
            at: fixture.now
        )
        let event = standardEvent(fixture)

        var snapshot = StoreSnapshot()
        snapshot.entertainmentRules = [stored]
        snapshot.completionEvents = [event]
        snapshot.dailyPlans = [fixture.plan]

        let before = EntertainmentRewardEvaluator().evaluate(
            rules: snapshot.entitlementRules(on: fixture.dayKey),
            plan: fixture.plan,
            completions: snapshot.completionEvents,
            grants: [],
            summary: snapshot.dailySummary(for: fixture.dayKey),
            context: fixture.context
        )
        guard let grant = before.pendingGrants.first else {
            check(false, "前置条件：应当先发放一条奖励")
            return
        }
        snapshot.rewardGrants = [grant]

        guard let data = try? JSONEncoder().encode(snapshot),
              let restored = try? JSONDecoder().decode(StoreSnapshot.self, from: data) else {
            check(false, "快照应当可以 JSON 往返")
            return
        }

        let restoredRule = restored.entertainmentRules.first
        checkEqual(restoredRule?.targets?.count, 1, "重启后目标绑定仍然存在")
        checkEqual(restoredRule?.repeatWeekdays, [2, 4, 6], "重启后每周重复仍然存在")
        checkEqual(restoredRule?.boundTargets.first?.id, fixture.standardItem.id, "重启后绑定指向同一条任务")
        checkEqual(restoredRule?.fallback, .fixedMinimumReward(minutes: 10), "重启后保底方式不变")

        let restoredGrant = restored.rewardGrants.first
        checkEqual(restoredGrant?.ruleSnapshot.targets?.count, 1, "历史奖励保留当时的绑定")
        checkEqual(restoredGrant?.grantedMinutes, 45, "历史奖励时长不变")
        checkEqual(restoredGrant?.grantKey, RewardGrant.Key.make(ruleRevisionID: stored.revisionID, dayKey: fixture.dayKey), "发放键在重启后一致")

        let after = EntertainmentRewardEvaluator().evaluate(
            rules: restored.entitlementRules(on: fixture.dayKey),
            plan: restored.activePlan(for: fixture.dayKey),
            completions: restored.completionEvents,
            grants: restored.rewardGrants,
            summary: restored.dailySummary(for: fixture.dayKey),
            context: fixture.context
        )
        checkEqual(after.eligibleRuleRevisionIDs, before.eligibleRuleRevisionIDs, "重启后资格一致")
        checkEqual(after.pendingGrants.count, 0, "重启后不会重复补发已经存在的奖励")
        checkEqual(after.progress.first?.achievedValue, before.progress.first?.achievedValue, "重启后进度一致")

        // 旧数据（没有 targets / repeatWeekdays 字段）仍然可以加载。
        let legacyJSON = """
        {"name":"旧规则","condition":{"metric":"standardCompletedItemCount","requiredValue":1},"rewardMinutes":20,"ruleVersion":1,"createdAt":0,"updatedAt":0}
        """
        let legacyRule = try? JSONDecoder().decode(EntertainmentRule.self, from: Data(legacyJSON.utf8))
        checkEqual(legacyRule?.boundTargets.count, 0, "旧规则没有绑定时按通用条件处理")
        checkEqual(legacyRule?.occursEveryDay, true, "旧规则默认每天生效")
        checkEqual(legacyRule?.targets, nil, "旧规则缺失字段解码为 nil")
    }
}

// MARK: - 便捷访问器（只读，供测试使用）

private extension StoreSnapshot {
    func activePlan(for dayKey: StudyDayKey) -> DailyStudyPlan? {
        dailyPlans.first { $0.dayKey == dayKey && $0.isActive }
    }
}
