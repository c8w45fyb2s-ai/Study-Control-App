import Foundation

// G 模块（全局集成、通知与最终验收）的独立行为测试。
//
// 这个文件刻意放在源码目标目录（`study software/`）之外：
// Xcode 使用 PBXFileSystemSynchronizedRootGroup，目录内的任何 .swift 都会被编进正式 App，
// 因此测试入口只能通过 swiftc 单独编译。
//
// 运行方式（在工程根目录 `软件本体/study software` 下）：
//
//   make verify-integration
//
// 覆盖的验收标准（全部是业务行为断言）：
// 1. 保存顺序：意图先落盘成完整快照，重复提交同一完成事件不产生第二条记录
// 2. 部分完成 / 整体完成分开；已学习 / 保底完成 / 标准完成分别记录
// 3. 只有"标准完成"的完整复习才按原 SM-2 规则推进；部分练习不会被当成完整成功
// 4. 跨日归属：同一学习日重复完成只有一条记录；不同学习日各自归档
// 5. 历史奖励绑定当时的规则版本；编辑规则不改写历史；重复评估不重复发放
// 6. 撤销完成保留记录本身，且只撤销未使用的奖励
// 7. 通知意图：先取消再安排、条数受限、避开课程与睡眠、没有时间时只发一条汇总
// 8. AI/引擎重排不会覆盖用户固定、正在进行与已完成的计划项
// 9. 引擎未接入时明确拒绝且**不修改任何数据**（不伪造算法）
// 10. 候选只来自真实数据：没有课表就不产生课程回顾/预习候选
// 11. 学习报告按完成事件分账，旧版本"每日完成总数"不折算时长与达标
// 12. 存储路径可注入：测试完全隔离，不触碰真实 store.json；完整快照可回读
// 13. 时间预算检查会指出排不下的学习日，但不删改任务

@main
struct IntegrationVerifyHarness {
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

    // MARK: - 测试替身（只验证集成语义，不是生产算法）

    /// 确定性的计划引擎替身：按容量逐条放置候选。
    struct StubPlanEngine: DailyPlanEngine {
        func proposePlan(_ request: DailyPlanRequest) -> DailyPlanProposal {
            let planID = UUID()
            var capacity = request.availability?.totalFreeMinutes ?? request.preferences.dailyCapMinutes ?? 120
            var items: [DailyPlanItem] = []
            var unplaceable: [UnplaceablePlanItem] = []

            for candidate in request.candidates {
                guard candidate.estimatedMinutes <= capacity else {
                    unplaceable.append(
                        UnplaceablePlanItem(
                            source: candidate.source,
                            title: candidate.title,
                            plannedScope: candidate.plannedScope,
                            estimatedMinutes: candidate.estimatedMinutes,
                            reason: .insufficientCapacity,
                            detail: "剩余 \(capacity) 分钟"
                        )
                    )
                    continue
                }
                capacity -= candidate.estimatedMinutes
                items.append(
                    DailyPlanItem(
                        planID: planID,
                        source: candidate.source,
                        title: candidate.title,
                        plannedScope: candidate.plannedScope,
                        minimumScope: candidate.minimumScope,
                        estimatedMinutes: candidate.estimatedMinutes,
                        scheduledStart: candidate.preferredStart,
                        scheduledDayKey: request.dayKey,
                        dueDate: candidate.dueDate,
                        isPinned: candidate.isPinned,
                        isSplittable: candidate.isSplittable,
                        note: candidate.note,
                        createdAt: request.context.now,
                        updatedAt: request.context.now
                    )
                )
            }

            let plan = DailyStudyPlan(
                id: planID,
                dayKey: request.dayKey,
                budget: DailyPlanBudget(
                    capacityMinutes: request.availability?.totalFreeMinutes ?? 0,
                    dailyCapMinutes: request.preferences.dailyCapMinutes,
                    plannedMinutes: items.reduce(0) { $0 + $1.estimatedMinutes }
                ),
                items: items,
                unplaceable: unplaceable,
                inputFingerprint: request.inputFingerprint,
                createdAt: request.context.now,
                updatedAt: request.context.now
            )
            return DailyPlanProposal(plan: plan, unplaceable: unplaceable)
        }
    }

    /// 确定性的会话引擎替身。
    struct StubSessionEngine: StudySessionEngine {
        func apply(
            _ event: StudySessionEvent,
            to session: StudySession?,
            item: PlanItemSessionContext?,
            context: PlanningContext
        ) -> StudySessionTransition {
            switch event {
            case .start(let at):
                guard session == nil else {
                    return StudySessionTransition(rejection: .duplicateEvent(ignoredKey: event.idempotencyKey))
                }
                let created = StudySession(
                    planID: item?.planID,
                    planItemID: item?.planItemID,
                    dayKey: item?.dayKey ?? context.todayKey,
                    startedAt: at,
                    createdAt: at,
                    updatedAt: at
                )
                return StudySessionTransition(session: created)

            case .pause(let at):
                guard var current = session, current.state == .running else {
                    return StudySessionTransition(rejection: .notRunning)
                }
                current.state = .paused
                current.pauses.append(StudyPauseInterval(startedAt: at))
                current.updatedAt = at
                return StudySessionTransition(session: current)

            case .resume(let at):
                guard var current = session, current.state == .paused else {
                    return StudySessionTransition(rejection: .notPaused)
                }
                current.state = .running
                if let last = current.pauses.indices.last, current.pauses[last].endedAt == nil {
                    current.pauses[last].endedAt = at
                }
                current.updatedAt = at
                return StudySessionTransition(session: current)

            case .finish(let at, let scope, let assessment, let note):
                guard var current = session, current.state.isActive else {
                    return StudySessionTransition(rejection: .noActiveSession)
                }
                current.state = .finished
                current.endedAt = at
                current.updatedAt = at
                current.note = note
                if let scope { current.progress = scope }
                if let assessment { current.assessment = assessment }

                let completion = CompletionEvent.make(
                    sessionID: current.id,
                    planID: current.planID,
                    planItemID: current.planItemID,
                    dayKey: current.dayKey,
                    source: item?.source,
                    plannedScope: item?.plannedScope,
                    minimumScope: item?.minimumScope,
                    completedScope: current.progress,
                    actualMinutes: current.effectiveMinutes(asOf: at, calendar: context.calendar),
                    completedAt: at,
                    assessment: assessment,
                    note: note,
                    createdAt: at
                )
                return StudySessionTransition(session: current, completionEvent: completion)

            default:
                return StudySessionTransition(session: session)
            }
        }
    }

    /// 确定性的奖励评估替身：按规则条件逐条判定，发放键由契约生成。
    struct StubRewardEvaluator: RewardEvaluator {
        func evaluate(
            rules: [EntertainmentRule],
            plan: DailyStudyPlan?,
            completions: [CompletionEvent],
            grants: [RewardGrant],
            summary: DailyStudySummary,
            context: PlanningContext
        ) -> RewardEvaluation {
            var evaluation = RewardEvaluation()
            guard RewardEligibilityGuard.isDecidable(summary: summary) else {
                evaluation.undecidableRuleRevisionIDs = rules.map(\.revisionID)
                evaluation.explanation.append(RewardEligibilityGuard.undecidableExplanation(for: summary.dayKey))
                return evaluation
            }

            let dayEvents = completions.filter { $0.dayKey == summary.dayKey && !$0.isRevoked }
            for rule in rules {
                let achieved: Double
                switch rule.condition.metric {
                case .standardCompletedItemCount: achieved = Double(summary.standardCompletedItemCount)
                case .minimumCompletedItemCount: achieved = Double(summary.minimumCompletedItemCount)
                case .studiedItemCount: achieved = Double(summary.studiedItemCount + summary.completedItemCount)
                case .recordedMinutes: achieved = Double(summary.recordedMinutes ?? 0)
                case .standardCompletionRatio:
                    let planned = plan?.items.count ?? 0
                    achieved = planned > 0 ? Double(summary.standardCompletedItemCount) / Double(planned) : 0
                case .anyStudied: achieved = dayEvents.isEmpty ? 0 : 1
                }

                let progress = RewardConditionProgress(
                    ruleID: rule.id,
                    ruleRevisionID: rule.revisionID,
                    metric: rule.condition.metric,
                    achievedValue: achieved,
                    requiredValue: rule.condition.requiredValue,
                    basisEventIDs: dayEvents.map(\.id),
                    isSatisfied: achieved >= rule.condition.requiredValue
                )
                evaluation.progress.append(progress)
                guard progress.isSatisfied else { continue }

                evaluation.eligibleRuleRevisionIDs.append(rule.revisionID)
                let grantKey = RewardGrant.Key.make(ruleRevisionID: rule.revisionID, dayKey: summary.dayKey)
                guard !grants.contains(where: {
                    $0.grantKey == grantKey || ($0.dayKey == summary.dayKey && $0.ruleID == rule.id)
                }) else { continue }
                evaluation.pendingGrants.append(
                    RewardGrant.make(
                        ruleSnapshot: rule.snapshotValue,
                        dayKey: summary.dayKey,
                        basisEventIDs: progress.basisEventIDs,
                        conditionProgress: progress,
                        grantedMinutes: rule.rewardMinutes,
                        grantedAt: context.now
                    )
                )
            }
            return evaluation
        }
    }

    static func coordinator(engines: Bool = true) -> StudyPlanCoordinator {
        guard engines else { return StudyPlanCoordinator(engines: .empty) }
        return StudyPlanCoordinator(
            engines: StudyPlanEngines(
                planEngine: StubPlanEngine(),
                minimumPolicy: nil,
                sessionEngine: StubSessionEngine(),
                rewardEvaluator: StubRewardEvaluator()
            )
        )
    }

    // MARK: - 固定装置

    static func makePlan(
        dayKey: StudyDayKey,
        plannedScope: StudyScope,
        minimumScope: StudyScope?,
        now: Date,
        pinned: Bool = false
    ) -> (StoreSnapshot, DailyStudyPlan, DailyPlanItem) {
        var snapshot = StoreSnapshot()
        let planID = UUID()
        let item = DailyPlanItem(
            planID: planID,
            source: .reviewTask(UUID()),
            title: "复习任务：三角函数",
            plannedScope: plannedScope,
            minimumScope: minimumScope,
            estimatedMinutes: 20,
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        let plan = DailyStudyPlan(
            id: planID,
            dayKey: dayKey,
            budget: DailyPlanBudget(capacityMinutes: 120, plannedMinutes: 20),
            items: [item],
            inputFingerprint: "fp",
            createdAt: now,
            updatedAt: now
        )
        snapshot.dailyPlans = [plan]
        return (snapshot, plan, item)
    }

    /// 与协调器使用完全相同的输入指纹（保证测试测的是生产路径）。
    static func fingerprint(for state: StoreSnapshot, dayKey: StudyDayKey, context: PlanningContext) -> String {
        let dayStart = dayKey.startOfDay(calendar: context.calendar) ?? context.now
        let availability = AvailabilityCalculator.availability(
            on: dayStart,
            schedule: state.scheduleForComputation,
            preferences: state.availabilityPreferences,
            now: context.now
        )
        return PlanCandidateBuilder.fingerprint(
            PlanCandidateBuilder.PlanFingerprintInput(
                dayKey: dayKey,
                context: context,
                availability: availability,
                preferences: state.availabilityPreferences,
                engineConfiguration: StudyEngineRegistry.engineConfiguration(for: state),
                candidates: PlanCandidateBuilder.candidates(from: state, dayKey: dayKey, context: context),
                signalIndex: TaskSignalIndex(
                    snapshot: state,
                    courseHasMaterials: StudyEngineRegistry.courseMaterialIndex(in: state)
                ),
                completions: state.completionEvents,
                activePlan: StudyPlanCoordinator.activePlan(in: state, dayKey: dayKey)
            )
        )
    }

    // MARK: - 主流程

    static func main() {
        // 让断言输出立即落盘：崩溃时也能看到最后一条断言。
        setvbuf(stdout, nil, _IONBF, 0)
        let now = date(2026, 9, 23, 10, 0)
        let context = self.context(now: now)
        let dayKey = context.todayKey
        let planCoordinator = self.coordinator()

        // 1. 统一提交：完成事件落进快照，重复提交被拒绝且不新增记录
        let (baseSnapshot, _, item) = makePlan(
            dayKey: dayKey,
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.4),
            now: now
        )

        let first = planCoordinator.coordinate(
            .completeItemDirectly(planItemID: item.id, scope: .tasks(1), minutes: 20, assessment: StudyAssessment(selfRating: 5), note: ""),
            state: baseSnapshot,
            context: context
        )
        check(first.didChange, "完成计划项会产出新的完整快照")
        checkEqual(first.snapshot.completionEvents.count, 1, "完成一次只产生一条完成事件")
        checkEqual(first.snapshot.dailyPlans[0].items[0].status, .completed, "标准完成后计划项状态为已完成")
        checkEqual(first.snapshot.dailyPlans[0].items[0].completionTier, .standard, "完成整个计划范围记为标准完成")
        checkEqual(first.snapshot.dailySummary(for: dayKey).standardCompletedItemCount, 1, "日汇总的标准完成数为 1")
        checkEqual(first.snapshot.dailySummary(for: dayKey).recordedMinutes, 20, "日汇总记录实际学习分钟数")

        let second = planCoordinator.coordinate(
            .completeItemDirectly(planItemID: item.id, scope: .tasks(1), minutes: 20, assessment: StudyAssessment(selfRating: 5), note: ""),
            state: first.snapshot,
            context: context
        )
        checkEqual(second.snapshot.completionEvents.count, 1, "重复完成同一计划项不会产生第二条记录")
        check(!second.didChange, "重复完成不会产生新的写入")
        if case .duplicateCompletion = second.rejection {} else {
            check(false, "重复完成会返回类型化的重复原因")
        }

        // 2. 三档分开：已学习 / 保底完成 / 标准完成
        let partial = planCoordinator.coordinate(
            .completeItemDirectly(planItemID: item.id, scope: .tasks(0.5), minutes: 8, assessment: nil, note: ""),
            state: baseSnapshot,
            context: context
        )
        checkEqual(partial.snapshot.dailySummary(for: dayKey).minimumCompletedItemCount, 1, "完成 50%（≥保底 40%）记为保底完成")
        checkEqual(partial.snapshot.dailySummary(for: dayKey).standardCompletedItemCount, 0, "保底完成不计入标准完成")

        let studiedOnly = planCoordinator.coordinate(
            .completeItemDirectly(planItemID: item.id, scope: .tasks(0.2), minutes: 4, assessment: nil, note: ""),
            state: baseSnapshot,
            context: context
        )
        checkEqual(studiedOnly.snapshot.dailySummary(for: dayKey).studiedItemCount, 1, "完成 20%（未到保底）记为已学习")
        checkEqual(studiedOnly.snapshot.dailySummary(for: dayKey).isEntertainmentEligible, false, "只学习未达标时没有娱乐资格")
        check(studiedOnly.snapshot.completionEvents[0].isPartialCompletion == true, "部分完成被标记为部分完成")

        let ordinaryReview = ReviewTask(title: "普通手动任务", dueDate: now.addingTimeInterval(-3_600))
        let manualTaskID = UUID()
        let manualPlanID = UUID()
        let manualItem = DailyPlanItem(
            planID: manualPlanID,
            source: .manual(manualTaskID: manualTaskID),
            title: "普通手动任务",
            plannedScope: .tasks(1),
            estimatedMinutes: 60,
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        let manualPlan = DailyStudyPlan(
            id: manualPlanID,
            dayKey: dayKey,
            budget: DailyPlanBudget(capacityMinutes: 60, plannedMinutes: 60),
            items: [manualItem],
            inputFingerprint: "manual-task-no-sm2",
            createdAt: now,
            updatedAt: now
        )
        var manualSnapshot = StoreSnapshot()
        manualSnapshot.dailyPlans = [manualPlan]
        manualSnapshot.reviewTasks = [ordinaryReview]
        let manualCompletion = planCoordinator.coordinate(
            .completeItemDirectly(planItemID: manualItem.id, scope: .tasks(1), minutes: 0, assessment: nil, note: ""),
            state: manualSnapshot,
            context: context
        )
        checkEqual(manualCompletion.snapshot.completionEvents.first?.actualMinutes, 0, "无计时完成普通手动任务不会拿预计分钟当实际分钟")
        checkEqual(manualCompletion.snapshot.completionEvents.first?.durationSource, .unrecorded, "无计时的手动任务完成标记为未记录时长")
        checkEqual(manualCompletion.snapshot.dailySummary(for: dayKey).recordedMinutes, 0, "手动任务预计分钟不贡献时长奖励")
        checkEqual(manualCompletion.snapshot.reviewTasks.first?.repetitionCount, ordinaryReview.repetitionCount, "普通手动任务完成不会按同名任务推进 SM-2 次数")
        checkEqual(manualCompletion.snapshot.reviewTasks.first?.intervalDays, ordinaryReview.intervalDays, "普通手动任务完成不会改写复习间隔")
        checkEqual(manualCompletion.snapshot.reviewTasks.first?.dueDate, ordinaryReview.dueDate, "普通手动任务完成不会改写同名复习的到期日")

        // 3. 完整复习才进 SM-2；部分练习不算完整成功复习
        var reviewSnapshot = StoreSnapshot()
        let reviewTask = ReviewTask(
            title: "复习任务：三角函数",
            dueDate: now.addingTimeInterval(-3600),
            easinessFactor: 2.5,
            repetitionCount: 1,
            intervalDays: 1
        )
        reviewSnapshot.reviewTasks = [reviewTask]

        let fullReview = planCoordinator.completeDirect(
            key: StudyCompletionKey.reviewTask(reviewTask.id, dayKey: dayKey),
            dayKey: dayKey,
            source: .reviewTask(reviewTask.id),
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.4),
            completedScope: .tasks(1),
            minutes: 15,
            assessment: StudyAssessment(selfRating: ReviewPlanner.Quality.good.rawValue),
            note: "",
            state: reviewSnapshot,
            context: context,
            successMessage: ""
        )
        let advanced = fullReview.snapshot.reviewTasks[0]
        checkEqual(advanced.repetitionCount, 2, "完整复习按 SM-2 推进重复次数")
        checkEqual(advanced.intervalDays, 6, "第二次成功复习的间隔为 6 天")
        checkEqual(advanced.lastQuality, ReviewPlanner.Quality.good.rawValue, "完整复习会记录评分")
        check(advanced.dueDate > now, "完整复习后到期日推进到未来")

        let partialReview = planCoordinator.completeDirect(
            key: StudyCompletionKey.reviewTask(reviewTask.id, dayKey: dayKey),
            dayKey: dayKey,
            source: .reviewTask(reviewTask.id),
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.4),
            completedScope: .tasks(0.4),
            minutes: 6,
            assessment: StudyAssessment(selfRating: ReviewPlanner.Quality.easy.rawValue),
            note: "",
            state: reviewSnapshot,
            context: context,
            successMessage: ""
        )
        let reset = partialReview.snapshot.reviewTasks[0]
        checkEqual(reset.repetitionCount, 0, "部分练习不会当作完整成功复习（重复次数被重置）")
        checkEqual(reset.intervalDays, 1, "部分练习把间隔重置为 1 天")
        check(reset.lastQuality != ReviewPlanner.Quality.easy.rawValue, "部分练习的评分被封顶，不记满分")

        let studiedReview = planCoordinator.completeDirect(
            key: StudyCompletionKey.reviewTask(reviewTask.id, dayKey: dayKey),
            dayKey: dayKey,
            source: .reviewTask(reviewTask.id),
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.4),
            completedScope: .tasks(0.1),
            minutes: 2,
            assessment: nil,
            note: "",
            state: reviewSnapshot,
            context: context,
            successMessage: ""
        )
        checkEqual(studiedReview.snapshot.reviewTasks[0].dueDate, reviewTask.dueDate, "未达到保底时复习任务保持原到期日")
        checkEqual(studiedReview.snapshot.reviewTasks[0].repetitionCount, reviewTask.repetitionCount, "未达到保底时不改变 SM-2 状态")

        // 4. 跨日归属：同一天只有一条，换一天各自归档
        let tomorrow = context.dayKey(for: date(2026, 9, 24, 10, 0))
        let nextDayContext = self.context(now: date(2026, 9, 24, 10, 0))
        let crossDay = planCoordinator.completeDirect(
            key: StudyCompletionKey.reviewTask(reviewTask.id, dayKey: tomorrow),
            dayKey: tomorrow,
            source: .reviewTask(reviewTask.id),
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.4),
            completedScope: .tasks(1),
            minutes: 15,
            assessment: nil,
            note: "",
            state: fullReview.snapshot,
            context: nextDayContext,
            successMessage: ""
        )
        checkEqual(crossDay.snapshot.completionEvents.count, 2, "不同学习日的完成记录各自归档")
        checkEqual(crossDay.snapshot.dailySummary(for: dayKey).standardCompletedItemCount, 1, "昨天的达标不会因为今天的记录而改变")
        checkEqual(crossDay.snapshot.dailySummary(for: tomorrow).standardCompletedItemCount, 1, "今天独立计一次达标")

        // 5. 奖励：版本绑定、幂等、历史不被改写
        var rewardSnapshot = StoreSnapshot()
        rewardSnapshot.entertainmentRules = [
            EntertainmentRule(
                name: "完成一项奖励",
                condition: .standardItems(1),
                rewardMinutes: 30,
                createdAt: now,
                updatedAt: now
            )
        ]
        rewardSnapshot.completionEvents = crossDay.snapshot.completionEvents.filter { $0.dayKey == dayKey }

        let firstRefresh = planCoordinator.coordinate(.refresh(dayKey: dayKey), state: rewardSnapshot, context: context)
        checkEqual(firstRefresh.snapshot.rewardGrants.count, 1, "达标后发放一条待领取奖励")
        let originalGrant = firstRefresh.snapshot.rewardGrants[0]

        var pendingLostGrant = originalGrant
        pendingLostGrant.id = UUID()
        pendingLostGrant.grantKey = "pending-lost-\(UUID().uuidString)"
        pendingLostGrant.basisEventIDs = []
        var claimedLostGrant = pendingLostGrant
        claimedLostGrant.id = UUID()
        claimedLostGrant.grantKey = "claimed-lost-\(UUID().uuidString)"
        claimedLostGrant.state = .claimed
        claimedLostGrant.claimedAt = now
        var startedLostGrant = pendingLostGrant
        startedLostGrant.id = UUID()
        startedLostGrant.grantKey = "started-lost-\(UUID().uuidString)"
        startedLostGrant.state = .started
        startedLostGrant.claimedAt = now
        startedLostGrant.startedAt = now
        var lostEligibilitySnapshot = StoreSnapshot()
        lostEligibilitySnapshot.entertainmentRules = rewardSnapshot.entertainmentRules
        lostEligibilitySnapshot.rewardGrants = [pendingLostGrant, claimedLostGrant, startedLostGrant]
        let lostEligibility = planCoordinator.coordinate(
            .refresh(dayKey: dayKey),
            state: lostEligibilitySnapshot,
            context: context
        )
        checkEqual(lostEligibility.snapshot.rewardGrant(id: pendingLostGrant.id)?.state, .revoked, "资格失效后立即撤销尚未领取的奖励")
        checkEqual(lostEligibility.snapshot.rewardGrant(id: claimedLostGrant.id)?.state, .revoked, "资格失效后立即撤销已领取但未开始的奖励")
        checkEqual(lostEligibility.snapshot.rewardGrant(id: startedLostGrant.id)?.state, .started, "资格失效不打断已开始的奖励计时")

        let repeatRefresh = planCoordinator.coordinate(.refresh(dayKey: dayKey), state: firstRefresh.snapshot, context: context)
        checkEqual(repeatRefresh.snapshot.rewardGrants.count, 1, "重复刷新不会重复发放奖励")
        check(!repeatRefresh.didChange, "重复刷新没有产生新的写入")

        var editedSnapshot = firstRefresh.snapshot
        editedSnapshot.entertainmentRules[0] = editedSnapshot.entertainmentRules[0].revised(
            name: "完成一项奖励（改）",
            rewardMinutes: 45,
            at: now.addingTimeInterval(600)
        )
        let afterEdit = planCoordinator.coordinate(.refresh(dayKey: dayKey), state: editedSnapshot, context: context)
        checkEqual(afterEdit.snapshot.rewardGrants.count, 1, "规则编辑不会在同一学习日重复产生奖励")
        let preserved = afterEdit.snapshot.rewardGrants.first { $0.id == originalGrant.id }
        check(preserved != nil, "规则编辑后原有奖励记录仍然存在")
        checkEqual(preserved?.state, .revoked, "旧规则版本失效后撤销尚未使用奖励")
        checkEqual(preserved?.revocation?.reason, "发放依据的规则版本已失效，未使用奖励已取消。", "规则版本失效原因写入历史奖励")
        checkEqual(preserved?.ruleSnapshot.name, originalGrant.ruleSnapshot.name, "历史奖励仍绑定当时的规则名称")
        checkEqual(preserved?.grantedMinutes, originalGrant.grantedMinutes, "历史奖励的时长不随规则编辑变化")
        checkEqual(preserved?.ruleVersion, 1, "历史奖励保留当时的规则版本号")
        checkEqual(preserved?.ruleRevisionID, originalGrant.ruleRevisionID, "历史奖励保留当时的规则版本 ID")
        checkEqual(preserved?.claimedAt, nil, "规则编辑不会改动历史奖励的领取状态")

        let stableAfterEdit = planCoordinator.coordinate(.refresh(dayKey: dayKey), state: afterEdit.snapshot, context: context)
        checkEqual(stableAfterEdit.snapshot.rewardGrants.count, 1, "重复刷新与规则编辑都不会重复发奖")

        // 6. 领取与撤销
        let claimed = planCoordinator.coordinate(.claimReward(grantID: originalGrant.id), state: firstRefresh.snapshot, context: context)
        checkEqual(claimed.snapshot.rewardGrants[0].state, .claimed, "领取后奖励状态为已领取")
        let claimAgain = planCoordinator.coordinate(.claimReward(grantID: originalGrant.id), state: claimed.snapshot, context: context)
        checkEqual(claimAgain.snapshot.rewardGrants[0].state, .claimed, "重复领取不会改变状态")
        checkEqual(claimAgain.snapshot.rewardGrants[0].claimedAt, claimed.snapshot.rewardGrants[0].claimedAt, "重复领取不会刷新领取时间")

        let revokedCompletion = planCoordinator.coordinate(
            .revokeCompletion(completionID: firstRefresh.snapshot.completionEvents[0].id, reason: "误点"),
            state: firstRefresh.snapshot,
            context: context
        )
        checkEqual(revokedCompletion.snapshot.completionEvents.count, 1, "撤销完成保留原始记录（不删除历史）")
        check(revokedCompletion.snapshot.completionEvents[0].isRevoked, "撤销写入撤销信息")
        checkEqual(revokedCompletion.snapshot.rewardGrants[0].state, .revoked, "未使用的奖励随依据事件一并撤销")
        checkEqual(revokedCompletion.snapshot.dailySummary(for: dayKey).standardCompletedItemCount, 0, "撤销后达标数回退")

        // 一条依据被撤销时，剩余有效记录仍满足条件，奖励不得被粗暴取消。
        var twoEvidenceSnapshot = StoreSnapshot()
        twoEvidenceSnapshot.entertainmentRules = rewardSnapshot.entertainmentRules
        twoEvidenceSnapshot.completionEvents = [
            crossDay.snapshot.completionEvents.first { $0.dayKey == dayKey }!,
            CompletionEvent.make(
                planItemID: UUID(),
                dayKey: dayKey,
                plannedScope: .tasks(1),
                completedScope: .tasks(1),
                actualMinutes: 12,
                completedAt: now.addingTimeInterval(120),
                createdAt: now.addingTimeInterval(120)
            )
        ]
        let twoEvidenceGrant = planCoordinator.coordinate(.refresh(dayKey: dayKey), state: twoEvidenceSnapshot, context: context)
        let firstEvidenceID = twoEvidenceGrant.snapshot.completionEvents[0].id
        let oneEvidenceLeft = planCoordinator.coordinate(
            .revokeCompletion(completionID: firstEvidenceID, reason: "误点"),
            state: twoEvidenceGrant.snapshot,
            context: context
        )
        checkEqual(oneEvidenceLeft.snapshot.dailySummary(for: dayKey).standardCompletedItemCount, 1, "撤销一条记录后另一条仍满足条件")
        checkEqual(oneEvidenceLeft.snapshot.rewardGrants.first?.state, .pending, "其他有效记录仍达标时保留未使用奖励")

        // 领取/开始前再次检查学习条件，即使先前没有收到状态刷新也不能使用旧资格。
        var revokedBeforeClaim = firstRefresh.snapshot
        if let revoked = revokedBeforeClaim.revokingCompletionEvent(
            id: revokedBeforeClaim.completionEvents[0].id,
            at: now,
            reason: "误点"
        ) {
            revokedBeforeClaim = revoked
        }
        let rejectedClaim = planCoordinator.coordinate(
            .claimReward(grantID: originalGrant.id),
            state: revokedBeforeClaim,
            context: context
        )
        checkEqual(rejectedClaim.snapshot.rewardGrant(id: originalGrant.id)?.state, .revoked, "领取时核验到学习条件失效并撤销未使用奖励")
        checkEqual(rejectedClaim.snapshot.rewardGrant(id: originalGrant.id)?.revocation?.reason, "相关学习记录已撤销，未使用奖励已取消。", "领取拦截保留一次简短原因")
        let rejectedStart = planCoordinator.coordinate(
            .startReward(grantID: originalGrant.id),
            state: revokedBeforeClaim,
            context: context
        )
        checkEqual(rejectedStart.snapshot.rewardGrant(id: originalGrant.id)?.state, .revoked, "开始计时前同样重新核验学习条件")

        // 跨日统一结算只过期尚未开始、未消费的奖励。
        let staleRewardDay = StudyDayKey(date: now.addingTimeInterval(-86_400), timeZone: context.timeZone)
        var staleRewardSnapshot = StoreSnapshot()
        staleRewardSnapshot.entertainmentRules = rewardSnapshot.entertainmentRules
        var expiredGrant = originalGrant
        expiredGrant.id = UUID()
        expiredGrant.grantKey = "stale-claimed-\(UUID().uuidString)"
        expiredGrant.dayKey = staleRewardDay
        expiredGrant.state = .claimed
        expiredGrant.claimedAt = now.addingTimeInterval(-86_400)
        var runningAcrossDay = expiredGrant
        runningAcrossDay.id = UUID()
        runningAcrossDay.grantKey = "stale-running-\(UUID().uuidString)"
        runningAcrossDay.state = .started
        runningAcrossDay.startedAt = now.addingTimeInterval(-300)
        staleRewardSnapshot.rewardGrants = [expiredGrant, runningAcrossDay]
        let staleSettled = planCoordinator.coordinate(.refresh(dayKey: dayKey), state: staleRewardSnapshot, context: context)
        checkEqual(staleSettled.snapshot.rewardGrant(id: expiredGrant.id)?.state, .expired, "超出允许日期的已领取未使用奖励标记过期")
        checkEqual(staleSettled.snapshot.rewardGrant(id: runningAcrossDay.id)?.state, .started, "跨日结算保留已经开始的计时")

        // 7. 通知意图
        let reminders = planCoordinator.reminderChanges(for: first.snapshot.dailyPlans[0], state: first.snapshot, context: context)
        checkEqual(reminders.first?.action, .cancelAll, "通知意图总是先取消旧提醒")
        check(reminders.filter { $0.action == .schedule }.count <= planCoordinator.maximumScheduledReminders + 1, "通知条数受限，不会集中轰炸")

        let duplicateReminderID = UUID().uuidString
        let cancelledReminderID = UUID().uuidString
        let reminderBatch = ReminderBatch.make(from: [
            ReminderChangeRequest(
                action: .schedule,
                fireDate: now.addingTimeInterval(3_600),
                title: "旧标题",
                kind: .planItem,
                businessID: duplicateReminderID
            ),
            ReminderChangeRequest(
                action: .schedule,
                fireDate: now.addingTimeInterval(7_200),
                title: "更新标题",
                kind: .planItem,
                businessID: duplicateReminderID
            ),
            ReminderChangeRequest(
                action: .schedule,
                fireDate: now.addingTimeInterval(3_600),
                title: "将取消",
                kind: .reviewTask,
                businessID: cancelledReminderID
            ),
            ReminderChangeRequest(
                action: .cancel,
                kind: .reviewTask,
                businessID: cancelledReminderID
            ),
            ReminderChangeRequest(action: .schedule, kind: .dailySummary, businessID: "  "),
            ReminderChangeRequest(action: .cancelAll)
        ])
        check(reminderBatch.cancelsAllManaged, "通知批次会识别清理所有托管提醒的意图")
        checkEqual(reminderBatch.scheduledChanges.count, 1, "同批相同标识的通知会去重")
        checkEqual(
            reminderBatch.scheduledChanges[ReminderKind.planItem.identifierPrefix + duplicateReminderID]?.title,
            "更新标题",
            "重复通知保留批次中最后一次安排"
        )
        check(
            reminderBatch.cancelledIdentifiers.contains(ReminderKind.reviewTask.identifierPrefix + cancelledReminderID),
            "同批显式取消会优先于安排"
        )
        check(
            !reminderBatch.scheduledChanges.keys.contains(ReminderKind.reviewTask.identifierPrefix + cancelledReminderID),
            "已取消的通知不会被同批重新安排"
        )
        check(!reminderBatch.scheduledChanges.keys.contains(ReminderKind.dailySummary.identifierPrefix), "空业务标识不会安排通知")

        var plannedSnapshot = StoreSnapshot()
        let plannedItem = DailyPlanItem(
            planID: plannedSnapshot.dailyPlans.first?.id ?? UUID(),
            source: .manual(note: "自习"),
            title: "自习",
            plannedScope: .tasks(1),
            estimatedMinutes: 30,
            scheduledStart: date(2026, 9, 23, 20, 0),
            scheduledEnd: date(2026, 9, 23, 20, 30),
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        let planID = UUID()
        let futureItem = DailyPlanItem(
            planID: planID,
            source: .manual(note: "自习"),
            title: "自习",
            plannedScope: .tasks(1),
            estimatedMinutes: 30,
            scheduledStart: date(2026, 9, 23, 20, 0),
            scheduledEnd: date(2026, 9, 23, 20, 30),
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        plannedSnapshot.dailyPlans = [
            DailyStudyPlan(
                id: planID,
                dayKey: dayKey,
                budget: DailyPlanBudget(capacityMinutes: 120),
                items: [futureItem],
                createdAt: now,
                updatedAt: now
            )
        ]
        let scheduled = planCoordinator.reminderChanges(for: plannedSnapshot.dailyPlans[0], state: plannedSnapshot, context: context)
        let scheduledItem = scheduled.first { $0.action == .schedule && $0.planItemID == futureItem.id }
        check(scheduledItem != nil, "有具体安排时间时会为下一项安排提醒")
        checkEqual(planCoordinator.maximumScheduledReminders, 3, "默认最多安排 3 条近期提醒")

        // 8. 通知时间避开课程与睡眠
        var sleepSnapshot = StoreSnapshot()
        sleepSnapshot.availabilitySettings = AvailabilitySettings(
            weekdayStudyWindows: [],
            weekendStudyWindows: [],
            sleepWindows: [
                DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 22, minute: 0), end: TimeOfDay(hour: 7, minute: 0), endDayOffset: 1)
            ],
            customBlocks: []
        )
        let sleepStart = date(2026, 9, 23, 22, 30)
        let afterSleepCheck = StudyPlanCoordinator.isProtected(sleepStart, state: sleepSnapshot, context: context)
        check(afterSleepCheck, "睡眠时段被识别为受保护时间")
        let outside = StudyPlanCoordinator.isProtected(date(2026, 9, 23, 15, 0), state: sleepSnapshot, context: context)
        check(!outside, "睡眠时段之外不是受保护时间")

        let usable = planCoordinator.nextUsableReminderDate(
            state: sleepSnapshot,
            context: context,
            preferredHour: 22
        )
        check(!StudyPlanCoordinator.isProtected(usable, state: sleepSnapshot, context: context), "生成的提醒时间避开了受保护时段")

        // 9. 受保护计划项不会被重排覆盖
        var protectedSnapshot = StoreSnapshot()
        let protectedPlanID = UUID()
        let pinnedItem = DailyPlanItem(
            planID: protectedPlanID,
            source: .manual(note: "用户固定"),
            title: "固定任务",
            plannedScope: .tasks(1),
            estimatedMinutes: 15,
            scheduledDayKey: dayKey,
            isPinned: true,
            createdAt: now,
            updatedAt: now
        )
        let completedItem = DailyPlanItem(
            planID: protectedPlanID,
            source: .manual(note: "已完成"),
            title: "已完成任务",
            plannedScope: .tasks(1),
            estimatedMinutes: 15,
            scheduledDayKey: dayKey,
            status: .completed,
            createdAt: now,
            updatedAt: now
        )
        let existingPlan = DailyStudyPlan(
            id: protectedPlanID,
            dayKey: dayKey,
            budget: DailyPlanBudget(capacityMinutes: 120),
            items: [pinnedItem, completedItem],
            createdAt: now,
            updatedAt: now
        )
        protectedSnapshot.dailyPlans = [existingPlan]

        let replacementPlanID = UUID()
        let proposedNew = DailyPlanItem(
            planID: replacementPlanID,
            source: .manual(note: "新任务"),
            title: "新任务",
            plannedScope: .tasks(1),
            estimatedMinutes: 10,
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        let merged = StudyPlanCoordinator.preservingProtectedItems(
            proposed: [proposedNew],
            existing: existingPlan,
            planID: replacementPlanID
        )
        check(merged.contains { $0.id == pinnedItem.id }, "AI/引擎重排不会移除用户固定的任务")
        check(merged.contains { $0.id == completedItem.id }, "AI/引擎重排不会移除已完成的任务")
        check(merged.contains { $0.id == proposedNew.id }, "新候选仍然会被加入计划")
        check(merged.allSatisfy { $0.planID == replacementPlanID }, "合并后的计划项都指向新计划")

        // 10. 引擎未接入：明确拒绝且不改数据
        let emptyCoordinator = self.coordinator(engines: false)
        let unavailable = emptyCoordinator.coordinate(.regeneratePlan(dayKey: dayKey, force: true), state: baseSnapshot, context: context)
        check(!unavailable.didChange, "引擎未接入时不会修改任何数据")
        checkEqual(unavailable.snapshot.dailyPlans.count, baseSnapshot.dailyPlans.count, "引擎未接入时计划数量不变")
        if case .missingSourceData = unavailable.rejection {} else {
            check(false, "引擎未接入会返回明确的缺失模块原因")
        }
        check(!emptyCoordinator.engines.missingModules.isEmpty, "未接入的模块会被如实列出")

        // 11. 候选只来自真实数据
        var candidateSnapshot = StoreSnapshot()
        let dueTask = ReviewTask(title: "复习任务：向量", dueDate: now, priority: 4)
        let futureTask = ReviewTask(title: "复习任务：稍后", dueDate: date(2026, 10, 30, 9, 0), priority: 1)
        candidateSnapshot.reviewTasks = [dueTask, futureTask]
        let candidates = PlanCandidateBuilder.candidates(from: candidateSnapshot, dayKey: dayKey, context: context)
        checkEqual(candidates.count, 1, "只把当天到期的复习任务纳入候选")
        checkEqual(candidates[0].title, "复习任务：向量", "候选标题直接来自真实任务标题，不编造内容")
        checkEqual(candidates[0].source.reviewTaskID, dueTask.id, "候选保留真实来源")
        check(candidates[0].dueDate != nil, "候选保留到期日期（与安排日期分开）")
        check(!candidates.contains { $0.source.kind == .courseReview || $0.source.kind == .preview }, "没有课表时不生成课程回顾/预习候选")

        // 12. 计划生成：指纹相同则复用，不再重复执行
        var planSnapshot = StoreSnapshot()
        planSnapshot.reviewTasks = [dueTask]
        planSnapshot.planningPreferences = PlanningPreferences(dailyCapMinutes: 120, planningTimeZoneIdentifier: timeZoneIdentifier)
        let generated = planCoordinator.coordinate(.regeneratePlan(dayKey: dayKey, force: false), state: planSnapshot, context: context)
        check(generated.didChange, "首次生成今日计划会产出新计划")
        let regenerated = planCoordinator.coordinate(.regeneratePlan(dayKey: dayKey, force: false), state: generated.snapshot, context: context)
        check(!regenerated.didChange, "输入指纹不变时不会重复生成计划")
        checkEqual(regenerated.snapshot.dailyPlans.count, generated.snapshot.dailyPlans.count, "重复生成不会新增计划版本")
        let forced = planCoordinator.coordinate(.regeneratePlan(dayKey: dayKey, force: true), state: generated.snapshot, context: context)
        checkEqual(forced.snapshot.dailyPlans.filter { $0.dayKey == dayKey && $0.isActive }.count, 1, "强制重建后同一天仍然只有一个生效计划")
        checkEqual(forced.snapshot.dailyPlans.filter { $0.dayKey == dayKey }.count, 2, "旧版本被保留为历史而不是删除")

        // 13. 学习报告分账
        var reportSnapshot = StoreSnapshot()
        var legacySnapshot = StoreSnapshot()
        legacySnapshot.dailyActivityRecords = [
            DailyActivityRecord(dateString: dayKey.localDateString, completedTaskCount: 3, studiedAt: now)
        ]
        reportSnapshot.dailyActivityRecords = legacySnapshot.dailyActivityRecords
        reportSnapshot.completionEvents = crossDay.snapshot.completionEvents

        // 报告按"从今天往回看"的窗口统计，因此用跨日之后的那天做基准。
        let report = StudyActivityReport.make(from: reportSnapshot, periodDays: 7, now: date(2026, 9, 24, 12, 0))
        checkEqual(report.studyCount, 2, "学习次数按完成事件计数")
        checkEqual(report.recordedMinutes, Optional(30), "已记录分钟数按完成事件累计")
        checkEqual(report.standardCompletedCount, 2, "标准达标单独统计")
        checkEqual(report.minimumCompletedCount, 0, "保底达标单独统计")
        checkEqual(report.legacyAggregateDayCount, 1, "完成事件同日存在的旧汇总仍单独说明")
        checkEqual(report.legacyAggregateTaskCount, 3, "旧汇总项数被单独保留")
        check(report.summaryLines.contains { $0.contains("已记录学习时长") }, "报告明确区分学习时长口径")
        check(report.summaryLines.contains { $0.contains("不推算时长") }, "历史汇总不会被推算成学习时长")

        let legacyOnlyDay = StudyDayKey(year: 2026, month: 9, day: 20, timeZoneIdentifier: timeZoneIdentifier)
        var legacyOnlySnapshot = StoreSnapshot()
        legacyOnlySnapshot.dailyActivityRecords = [
            DailyActivityRecord(dateString: legacyOnlyDay.localDateString, completedTaskCount: 4, studiedAt: now)
        ]
        let legacyReport = StudyActivityReport.make(from: legacyOnlySnapshot, periodDays: 7, now: now)
        checkEqual(legacyReport.studyCount, 0, "旧版本每日总数不被折算成学习次数")
        checkEqual(legacyReport.recordedMinutes, nil, "仅有旧版汇总时长保持未知")
        checkEqual(legacyReport.standardCompletedCount, 0, "旧版本每日总数不被折算成标准达标")
        checkEqual(legacyReport.legacyAggregateDayCount, 1, "旧版本每日总数被单独标注")
        checkEqual(legacyReport.legacyAggregateTaskCount, 4, "旧版汇总保留原始完成项数")
        check(legacyReport.summaryLines.contains { $0.contains("未知（旧版汇总不含时长）") }, "仅有旧数据时明确显示时长未知")
        check(legacyReport.summaryLines.contains { $0.contains("不推算时长") }, "报告明确说明旧数据不推算时长")

        let makeReportEvent: (StudyDayKey, StudyScope, Int, StudyDurationSource, Date) -> CompletionEvent = {
            eventDay, completedScope, minutes, durationSource, completedAt in
            CompletionEvent.make(
                planItemID: UUID(),
                dayKey: eventDay,
                plannedScope: .tasks(1),
                minimumScope: .tasks(0.5),
                completedScope: completedScope,
                actualMinutes: minutes,
                durationSource: durationSource,
                completedAt: completedAt,
                createdAt: completedAt
            )
        }
        let reportDay = self.context(now: now).todayKey
        let timedEvent = makeReportEvent(reportDay, .tasks(1), 20, .timed, now)
        let unrecordedEvent = makeReportEvent(reportDay, .tasks(0.5), 0, .unrecorded, now.addingTimeInterval(60))
        let legacyZeroEvent = makeReportEvent(reportDay, .tasks(0.25), 0, .legacy, now.addingTimeInterval(120))
        let manualZeroEvent = makeReportEvent(reportDay, .tasks(1), 0, .manualEntry, now.addingTimeInterval(180))
        let olderEvent = makeReportEvent(
            reportDay.advanced(byDays: -20),
            .tasks(1),
            5,
            .timed,
            now.addingTimeInterval(-20 * 24 * 60 * 60)
        )
        var sourceSnapshot = StoreSnapshot()
        sourceSnapshot.completionEvents = [timedEvent, unrecordedEvent, legacyZeroEvent, manualZeroEvent, olderEvent]
        let sourceReport = StudyActivityReport.make(from: sourceSnapshot, periodDays: 7, now: now)
        checkEqual(sourceReport.studyCount, 4, "未记录时长的有效完成仍计入学习次数")
        checkEqual(sourceReport.recordedMinutes, Optional(20), "未记录与零分钟来源事件不贡献分钟")
        checkEqual(sourceReport.unrecordedDurationCount, 1, "仅 durationSource 为未记录的事件计入未记录项数")
        checkEqual(sourceReport.standardCompletedCount, 2, "标准完成项数按互斥档位统计")
        checkEqual(sourceReport.minimumCompletedCount, 1, "保底完成项数按互斥档位统计")
        checkEqual(sourceReport.studiedOnlyCount, 1, "部分完成事件单独归入仅学习项数")

        let monthSourceReport = StudyActivityReport.make(from: sourceSnapshot, periodDays: 30, now: now)
        checkEqual(monthSourceReport.studyCount, 5, "月周期包含周周期之外的有效完成事件")
        checkEqual(monthSourceReport.recordedMinutes, Optional(25), "月周期分钟数随周期选择更新")

        if let revokedSnapshot = sourceSnapshot.revokingCompletionEvent(id: timedEvent.id, at: now, reason: "报告撤销验证") {
            let revokedReport = StudyActivityReport.make(from: revokedSnapshot, periodDays: 7, now: now)
            checkEqual(revokedReport.studyCount, 3, "撤销完成后学习次数同步减少")
            checkEqual(revokedReport.recordedMinutes, Optional(0), "撤销完成后已记录分钟数同步减少")
            checkEqual(revokedReport.standardCompletedCount, 1, "撤销完成后标准项数同步减少")
        } else {
            check(false, "应能撤销合成完成事件以验证报告同步")
        }

        let emptyActivityReport = StudyActivityReport.make(from: StoreSnapshot(), periodDays: 7, now: now)
        check(emptyActivityReport.isEmpty, "没有完成事件与历史汇总时报告识别为空")
        checkEqual(emptyActivityReport.recordedMinutes, Optional(0), "空周期显示零分钟并由界面给出空状态")

        // 14. 时间预算检查
        var budgetSnapshot = StoreSnapshot()
        budgetSnapshot.availabilitySettings = AvailabilitySettings(
            weekdayStudyWindows: [
                DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 20, minute: 0))
            ],
            weekendStudyWindows: [],
            sleepWindows: [],
            customBlocks: []
        )
        budgetSnapshot.planningPreferences = PlanningPreferences(planningTimeZoneIdentifier: timeZoneIdentifier)
        budgetSnapshot.reviewTasks = (0..<10).map { index in
            ReviewTask(title: "任务 \(index)", dueDate: date(2026, 9, 23, 20, 0), priority: 5)
        }
        let budget = StudyBudgetChecker.check(state: budgetSnapshot, horizonDays: 3, now: now)
        check(!budget.isWithinBudget, "任务超出可用容量时预算检查会报警")
        check(budget.overflowDays.first?.overflowMinutes ?? 0 > 0, "预算检查给出超出的分钟数")
        checkEqual(budgetSnapshot.reviewTasks.count, 10, "预算检查不会删改任务")

        // 15. 运行时环境与存储隔离
        let isolated = StudyRuntimeEnvironment.resolve(environment: [
            StudyRuntimeEnvironment.storeDirectoryEnvironmentKey: "/tmp/study-companion-integration-test"
        ])
        check(isolated.isIsolatedStore, "显式指定目录时判定为隔离数据路径")
        checkEqual(isolated.storeLocation.directory.path, "/tmp/study-companion-integration-test", "隔离目录按环境变量生效")

        let testMode = StudyRuntimeEnvironment.resolve(environment: [
            StudyRuntimeEnvironment.testModeEnvironmentKey: "1"
        ])
        check(testMode.isTestMode, "测试模式被识别")
        check(!testMode.allowsSystemNotifications, "测试模式下不发送系统通知")
        check(testMode.storeLocation.directory.path.contains("StudyCompanionIsolated"), "测试模式使用独立临时目录")

        let production = StudyRuntimeEnvironment.resolve(environment: [:])
        check(!production.isIsolatedStore, "默认运行不是隔离路径")
        check(production.storeLocation.storeURL.path.hasSuffix("StudyCompanion/store.json"), "默认路径是 Application Support/StudyCompanion/store.json")

        // 16. 完整快照写入与回读（绝不使用真实 store.json）
        let location = SnapshotStoreLocation.isolatedTemporary(prefix: "IntegrationVerify")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        do {
            let fileStore = try SnapshotFileStore(location: location)
            let saved = try fileStore.save(first.snapshot)
            check(saved == nil || true, "保存完整快照不抛错")
            let reloaded = try fileStore.load()
            checkEqual(reloaded?.completionEvents.count, first.snapshot.completionEvents.count, "回读后的完成事件数量一致")
            checkEqual(reloaded?.schemaVersion, StudySchema.currentVersion, "回读后的 schema 版本为当前版本")
            checkEqual(reloaded?.dailyPlans.count, first.snapshot.dailyPlans.count, "回读后的计划数量一致")
            check(try fileStore.loadWithReport() != nil, "带报告的读取可用（供 G 记录迁移）")
        } catch {
            check(false, "隔离目录读写失败：\(error)")
        }

        // 16b. 备份导出 / 导入 / 恢复往返
        let backupLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "IntegrationBackup")
        defer { try? FileManager.default.removeItem(at: backupLocation.directory) }
        do {
            let fileStore = try SnapshotFileStore(location: backupLocation)
            try fileStore.save(first.snapshot)

            let exportURL = backupLocation.directory.appendingPathComponent("StudyCompanionBackup.json")
            try fileStore.exportSnapshot(first.snapshot, to: exportURL)
            check(FileManager.default.fileExists(atPath: exportURL.path), "备份导出会生成文件")

            let imported = try fileStore.importSnapshot(from: exportURL)
            checkEqual(imported.completionEvents.count, first.snapshot.completionEvents.count, "导入备份后完成事件一致")
            checkEqual(imported.dailyPlans.count, first.snapshot.dailyPlans.count, "导入备份后计划一致")
            checkEqual(imported.schemaVersion, StudySchema.currentVersion, "导入备份会被归一化到当前 schema")

            // 再写一次产生备份轮转，然后从备份恢复
            var mutated = imported
            mutated.reviewTasks.append(ReviewTask(title: "备份轮转标记", dueDate: now))
            try fileStore.save(mutated)

            let backups = fileStore.availableBackups()
            check(!backups.isEmpty, "保存后会生成可恢复的备份点")
            let restored = try fileStore.restoreFromBackup(index: backups[0].index)
            checkEqual(restored.reviewTasks.count, imported.reviewTasks.count, "从备份恢复得到的是备份当时的数据")
            checkEqual(restored.completionEvents.count, imported.completionEvents.count, "从备份恢复后完成事件一致")
        } catch {
            check(false, "备份导出/导入/恢复失败：\(error)")
        }

        // 17. 撤销是幂等的
        let revokeAgain = planCoordinator.coordinate(
            .revokeCompletion(completionID: revokedCompletion.snapshot.completionEvents[0].id, reason: "再次撤销"),
            state: revokedCompletion.snapshot,
            context: context
        )
        check(!revokeAgain.didChange, "重复撤销同一条完成记录不会重复写入")

        // 18. 完成学习与答题正确分开
        let answered = planCoordinator.coordinate(
            .completeItemDirectly(
                planItemID: item.id,
                scope: .tasks(1),
                minutes: 25,
                assessment: StudyAssessment(totalQuestions: 10, correctQuestions: 3, selfRating: 2),
                note: ""
            ),
            state: baseSnapshot,
            context: context
        )
        checkEqual(answered.snapshot.completionEvents[0].tier, .standard, "答题正确率不影响完成档次")
        checkEqual(answered.snapshot.completionEvents[0].assessment?.accuracy ?? -1, 0.3, "答题正确率单独记录")
        checkEqual(answered.snapshot.dailySummary(for: dayKey).standardCompletedItemCount, 1, "标准完成与答题正确分开统计")

        // 19. 娱乐资格不被旧版本每日总数推导
        var legacyEligibilitySnapshot = StoreSnapshot()
        legacyEligibilitySnapshot.dailyActivityRecords = [
            DailyActivityRecord(dateString: dayKey.localDateString, completedTaskCount: 5, studiedAt: now)
        ]
        let legacySummary = legacyEligibilitySnapshot.dailySummary(for: dayKey)
        checkEqual(legacySummary.isEntertainmentEligible, nil, "只有旧版本每日总数时不推导娱乐资格")
        check(!RewardEligibilityGuard.isDecidable(summary: legacySummary), "旧版本每日总数被判定为不可决策")

        // 20. 通知：没有具体时间时只发一条汇总
        let emptyPlan = DailyStudyPlan(
            id: UUID(),
            dayKey: dayKey,
            budget: DailyPlanBudget(capacityMinutes: 60),
            items: [
                DailyPlanItem(
                    planID: UUID(),
                    source: .manual(note: "无时间"),
                    title: "无具体时间的任务",
                    plannedScope: .tasks(1),
                    estimatedMinutes: 20,
                    scheduledDayKey: dayKey,
                    createdAt: now,
                    updatedAt: now
                )
            ],
            createdAt: now,
            updatedAt: now
        )
        var summarySnapshot = StoreSnapshot()
        summarySnapshot.dailyPlans = [emptyPlan]
        let summaryReminders = planCoordinator.reminderChanges(for: emptyPlan, state: summarySnapshot, context: context)
        checkEqual(summaryReminders.filter { $0.action == .schedule }.count, 1, "没有具体时间时只发一条汇总提醒")
        checkEqual(summaryReminders.first?.action, .cancelAll, "汇总提醒前仍然先取消旧提醒")

        // 21. 生产注册表：四个引擎全部接入（防止"引擎已交付但没注册"再次发生）
        let productionEngines = StudyEngineRegistry.production()
        check(
            productionEngines.missingModules.isEmpty,
            "生产注册表没有缺失模块（实际缺失：\(productionEngines.missingModules.joined(separator: "、"))）"
        )
        check(
            productionEngines.planEngine(for: StoreSnapshot(), context: context) != nil,
            "注册表能用当前快照构造计划引擎"
        )
        check(productionEngines.minimumPolicyFactory != nil, "生产注册表按当前快照构造最低任务策略")
        check(productionEngines.minimumPolicy == nil, "生产注册表不保留无参数静态策略回退")
        let nilFactoryWithLegacyValue = StudyPlanEngines(
            minimumPolicyFactory: { _, _ in nil },
            minimumPolicy: StudyMinimumPlanPolicy()
        )
        check(
            nilFactoryWithLegacyValue.resolvedMinimumPolicy(for: StoreSnapshot()) == nil,
            "已配置工厂返回 nil 时不会回退到旧静态策略"
        )

        var policyInjectionSnapshot = StoreSnapshot()
        let injectedSleepWindows = [
            DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 23, minute: 30), end: TimeOfDay(hour: 5, minute: 30), endDayOffset: 1)
        ]
        policyInjectionSnapshot.availabilitySettings = AvailabilitySettings(
            weekdayStudyWindows: [],
            weekendStudyWindows: [],
            sleepWindows: injectedSleepWindows,
            customBlocks: []
        )
        policyInjectionSnapshot.planningPreferences = PlanningPreferences(
            autoReduceEnabled: false,
            planningTimeZoneIdentifier: timeZoneIdentifier
        )
        let configuredPlanEngine = StudyEngineRegistry.makeDailyPlanEngine(
            for: policyInjectionSnapshot,
            context: context
        ) as? LocalDailyPlanEngine
        let automaticPolicy = configuredPlanEngine?.minimumPolicy as? StudyMinimumPlanPolicy
        let registeredAutomaticPolicy = productionEngines.resolvedMinimumPolicy(
            for: policyInjectionSnapshot,
            isManual: false
        ) as? StudyMinimumPlanPolicy
        check(policyInjectionSnapshot.scheduleCourses.isEmpty, "最低任务策略注入不依赖已配置课程")
        checkEqual(automaticPolicy?.configuration.respectsAutoReduceSetting, true, "自动路径的最低任务策略保留自动减量开关约束")
        checkEqual(automaticPolicy?.configuration.sleepWindows, injectedSleepWindows, "没有课程时自动路径仍读取当前快照的睡眠窗口")
        checkEqual(registeredAutomaticPolicy?.configuration, automaticPolicy?.configuration, "自动计划引擎与注册表工厂使用相同配置")
        let injectedManualPolicy = StudyEngineRegistry.makeMinimumPlanPolicy(for: policyInjectionSnapshot, isManual: true) as? StudyMinimumPlanPolicy
        let registeredManualPolicy = productionEngines.resolvedMinimumPolicy(
            for: policyInjectionSnapshot,
            isManual: true
        ) as? StudyMinimumPlanPolicy
        checkEqual(injectedManualPolicy?.configuration.respectsAutoReduceSetting, false, "手动采用路径不受自动减量关闭开关限制")
        checkEqual(injectedManualPolicy?.configuration.sleepWindows, injectedSleepWindows, "没有课程时手动采用路径仍尊重用户睡眠窗口")
        checkEqual(registeredManualPolicy?.configuration, injectedManualPolicy?.configuration, "手动预览与应用从同一快照工厂获取配置")

        // 22. 真实引擎端到端生成今日计划（离线可用，不需要网络或 API Key）
        let productionCoordinator = StudyPlanCoordinator(engines: productionEngines)
        var liveSnapshot = StoreSnapshot()
        liveSnapshot.reviewTasks = [
            ReviewTask(title: "复习任务：三角函数", dueDate: date(2026, 9, 23, 9, 0), priority: 4)
        ]
        liveSnapshot.availabilitySettings = AvailabilitySettings(
            weekdayStudyWindows: [
                DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 22, minute: 0))
            ],
            weekendStudyWindows: [],
            sleepWindows: [],
            customBlocks: []
        )
        liveSnapshot.planningPreferences = PlanningPreferences(
            dailyCapMinutes: 180,
            planningTimeZoneIdentifier: timeZoneIdentifier
        )

        let livePlanResult = productionCoordinator.coordinate(
            .regeneratePlan(dayKey: dayKey, force: false),
            state: liveSnapshot,
            context: context
        )
        let livePlan = livePlanResult.snapshot.dailyPlans.first { $0.dayKey == dayKey && $0.isActive }
        check(livePlanResult.didChange, "真实引擎会生成今日计划（不再返回未接入）")
        check(livePlan != nil, "生成后存在生效的今日计划")
        check((livePlan?.items.count ?? 0) > 0, "到期的复习任务被排进今天的计划")
        check(!(livePlan?.explanation.lines.isEmpty ?? true), "计划带解释（说明预算与生成原因）")
        check(livePlan?.items.allSatisfy { $0.scheduledDayKey == dayKey } ?? false, "计划项都归属今天的学习日")
        check(
            livePlan?.items.allSatisfy { $0.source.kind != .reviewTask || $0.source.reviewTaskID != nil } ?? false,
            "复习类计划项都保留真实来源"
        )

        // 23. 相同输入重复生成：复用旧计划，不新增版本、不重复建任务
        let liveRepeat = productionCoordinator.coordinate(
            .regeneratePlan(dayKey: dayKey, force: false),
            state: livePlanResult.snapshot,
            context: context
        )
        check(!liveRepeat.didChange, "相同输入重复生成不会新建版本")
        checkEqual(
            liveRepeat.snapshot.dailyPlans.count,
            livePlanResult.snapshot.dailyPlans.count,
            "重复生成不会新增计划记录"
        )

        // 24. 输入指纹：总分钟数相同、空闲时段不同 → 不是同一输入
        var windowA = liveSnapshot
        windowA.availabilitySettings = AvailabilitySettings(
            weekdayStudyWindows: [
                DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 21, minute: 0))
            ],
            weekendStudyWindows: [],
            sleepWindows: [],
            customBlocks: []
        )
        var windowB = liveSnapshot
        windowB.availabilitySettings = AvailabilitySettings(
            weekdayStudyWindows: [
                DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 20, minute: 0), end: TimeOfDay(hour: 22, minute: 0))
            ],
            weekendStudyWindows: [],
            sleepWindows: [],
            customBlocks: []
        )
        let availabilityA = AvailabilityCalculator.availability(
            on: dayKey.startOfDay(calendar: context.calendar) ?? context.now,
            schedule: windowA.scheduleForComputation,
            preferences: windowA.availabilityPreferences,
            now: context.now
        )
        let availabilityB = AvailabilityCalculator.availability(
            on: dayKey.startOfDay(calendar: context.calendar) ?? context.now,
            schedule: windowB.scheduleForComputation,
            preferences: windowB.availabilityPreferences,
            now: context.now
        )
        checkEqual(availabilityA.totalFreeMinutes, availabilityB.totalFreeMinutes, "（前提）两个分布的总分钟数相同")
        let fingerprintA = fingerprint(for: windowA, dayKey: dayKey, context: context)
        let fingerprintB = fingerprint(for: windowB, dayKey: dayKey, context: context)
        check(fingerprintA != fingerprintB, "总时长相同但空闲时段不同 → 不同输入指纹")

        // 25. 指纹：精力 / 学习信号 / 完成进度变化都必须反映出来
        var tiredSnapshot = windowA
        tiredSnapshot.planningPreferences.energyLevelIdentifier = StudyEnergyLevel.tired.rawValue
        check(
            fingerprint(for: tiredSnapshot, dayKey: dayKey, context: context) != fingerprintA,
            "精力档位变化会改变输入指纹"
        )

        var masteredSnapshot = windowA
        let masteryPoint = KnowledgePoint(title: "三角函数", subject: "数学", summary: "", mastery: 0.9)
        masteredSnapshot.knowledgePoints = [masteryPoint]
        masteredSnapshot.reviewTasks[0].knowledgePointID = masteryPoint.id
        check(
            fingerprint(for: masteredSnapshot, dayKey: dayKey, context: context) != fingerprintA,
            "知识点掌握度变化会改变输入指纹"
        )

        var progressedSnapshot = windowA
        progressedSnapshot.completionEvents = [
            CompletionEvent.make(
                planItemID: UUID(),
                dayKey: dayKey,
                completedScope: .tasks(1),
                actualMinutes: 15,
                completedAt: now,
                createdAt: now
            )
        ]
        check(
            fingerprint(for: progressedSnapshot, dayKey: dayKey, context: context) != fingerprintA,
            "当天完成进度变化会改变输入指纹"
        )

        // 25b. 计划稳定性：有受保护任务时，重复重新评估不会不断新建版本
        var startedSnapshot = livePlanResult.snapshot
        let startedItemID = startedSnapshot.dailyPlans.first { $0.isActive }?.items.first?.id
        if let startedItemID {
            for planIndex in startedSnapshot.dailyPlans.indices {
                guard let itemIndex = startedSnapshot.dailyPlans[planIndex].items.firstIndex(where: { $0.id == startedItemID }) else { continue }
                startedSnapshot.dailyPlans[planIndex].items[itemIndex].status = .inProgress
                // 模拟"用户已经把这条任务放到 20:00 开始"，重新规划必须保留这个时间。
                startedSnapshot.dailyPlans[planIndex].items[itemIndex].scheduledStart = date(2026, 9, 23, 20, 0)
                startedSnapshot.dailyPlans[planIndex].items[itemIndex].scheduledEnd = date(2026, 9, 23, 20, 30)
            }
            let protectedReplan = productionCoordinator.coordinate(
                .regeneratePlan(dayKey: dayKey, force: true),
                state: startedSnapshot,
                context: context
            )
            let protectedAfter = protectedReplan.snapshot.dailyPlans.first { $0.isActive }
            check(
                protectedAfter?.items.contains { $0.id == startedItemID } ?? false,
                "重新规划不会丢掉正在进行中的任务"
            )
            if let kept = protectedAfter?.items.first(where: { $0.id == startedItemID }) {
                checkEqual(kept.scheduledStart, date(2026, 9, 23, 20, 0), "重新规划保留进行中任务的开始时间")
                checkEqual(kept.status, .inProgress, "重新规划保留进行中任务的状态")
            }

            let stableAgain = productionCoordinator.coordinate(
                .regeneratePlan(dayKey: dayKey, force: false),
                state: protectedReplan.snapshot,
                context: context
            )
            if stableAgain.didChange {
                let versionsAfter = stableAgain.snapshot.dailyPlans.filter { $0.dayKey == dayKey }.count
                let versionsBefore = protectedReplan.snapshot.dailyPlans.filter { $0.dayKey == dayKey }.count
                check(false, "存在受保护任务时，同一输入不应再次新建版本（\(versionsBefore) → \(versionsAfter)）")
            } else {
                check(true, "存在受保护任务时，同一输入不会再次新建版本")
            }
        } else {
            check(false, "（前提）第一次生成应当至少排入一个计划项")
        }

        // 25c. 新增公共字段（精力档位）的存储往返与容错
        var energySnapshot = liveSnapshot
        energySnapshot.planningPreferences.energyLevelIdentifier = StudyEnergyLevel.energetic.rawValue
        let energyLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "IntegrationEnergy")
        defer { try? FileManager.default.removeItem(at: energyLocation.directory) }
        do {
            let energyStore = try SnapshotFileStore(location: energyLocation)
            try energyStore.save(energySnapshot)
            let reloaded = try energyStore.load()
            checkEqual(
                reloaded?.planningPreferences.energyLevelIdentifier,
                StudyEnergyLevel.energetic.rawValue,
                "精力档位能写入并回读"
            )
            checkEqual(
                StudyEngineRegistry.engineConfiguration(for: reloaded ?? StoreSnapshot()).energyOverride,
                StudyEnergyLevel.energetic,
                "回读后的精力档位会真正进入规划配置"
            )
        } catch {
            check(false, "精力档位存储往返失败：\(error)")
        }
        checkEqual(
            PlanningPreferences.normalizedEnergyIdentifier("unknown-level"),
            nil,
            "无法识别的精力档位按「没有手动设置」处理"
        )
        checkEqual(
            PlanningPreferences(energyLevelIdentifier: "TIRED").energyLevelIdentifier,
            StudyEnergyLevel.tired.rawValue,
            "精力档位解析大小写无关"
        )

        // 26. 刷新与重新规划分开：刷新只重算状态，不动安排
        let beforeRefresh = livePlanResult.snapshot
        let refreshResult = productionCoordinator.coordinate(.refresh(dayKey: dayKey), state: beforeRefresh, context: context)
        checkEqual(refreshResult.snapshot.dailyPlans, beforeRefresh.dailyPlans, "刷新不会改动已有的计划安排")
        check(refreshResult.reminderChanges.isEmpty, "纯刷新不会产生通知重排意图")
        check(refreshResult.snapshot.studySessions.count == 0 && refreshResult.snapshot.completionEvents.count == 0, "刷新不会凭空造出会话或完成事件")

        // 27. 没有可用时间：允许预算为 0，不崩溃也不造假完成
        var noTimeSnapshot = liveSnapshot
        noTimeSnapshot.availabilitySettings = AvailabilitySettings(
            weekdayStudyWindows: [],
            weekendStudyWindows: [],
            sleepWindows: [],
            customBlocks: []
        )
        let noTimeResult = productionCoordinator.coordinate(
            .regeneratePlan(dayKey: dayKey, force: true),
            state: noTimeSnapshot,
            context: context
        )
        let noTimePlan = noTimeResult.snapshot.dailyPlans.first { $0.isActive }
        check(noTimePlan != nil, "没有可用时间时仍然给出计划（预算为 0）")
        checkEqual(noTimePlan?.items.count ?? -1, 0, "没有可用时间时不排任何任务")
        checkEqual(noTimeResult.snapshot.completionEvents.count, 0, "生成计划不会产生完成事件")

        // 28. 没有任何任务：不编造任务
        var emptyTaskSnapshot = liveSnapshot
        emptyTaskSnapshot.reviewTasks = []
        let emptyTaskResult = productionCoordinator.coordinate(
            .regeneratePlan(dayKey: dayKey, force: true),
            state: emptyTaskSnapshot,
            context: context
        )
        checkEqual(
            emptyTaskResult.snapshot.dailyPlans.first { $0.isActive }?.items.count ?? -1,
            0,
            "没有任务时不会为凑预算造任务"
        )

        // 29. 全量计划来源：有课表且当天有课时，必须出现课程回顾候选
        var withCourseSnapshot = liveSnapshot
        withCourseSnapshot.scheduleSemester = ScheduleSemester(
            firstWeekStart: date(2026, 9, 21, 0, 0),
            weekCount: 16,
            timeZoneIdentifier: timeZoneIdentifier
        )
        withCourseSnapshot.scheduleCourses = [
            Course(
                name: "高等数学",
                subject: SubjectRef(displayName: "数学"),
                weekday: .wednesday,
                startTime: TimeOfDay(hour: 10, minute: 0),
                endTime: TimeOfDay(hour: 11, minute: 30)
            ),
            // 次日（周四）也有一节课，用于验证"预习"候选。
            Course(
                name: "线性代数",
                subject: SubjectRef(displayName: "数学"),
                weekday: .thursday,
                startTime: TimeOfDay(hour: 9, minute: 0),
                endTime: TimeOfDay(hour: 10, minute: 30)
            )
        ]
        let withCourseCandidates = PlanCandidateBuilder.candidates(
            from: withCourseSnapshot,
            dayKey: dayKey,
            context: context
        )
        check(
            withCourseCandidates.contains { $0.source.kind == .courseReview },
            "当天有课时会生成课程回顾候选（全量计划不只有旧复习任务）"
        )
        check(
            withCourseCandidates.contains { $0.source.kind == .preview },
            "次日有课时会生成预习候选"
        )
        check(
            withCourseCandidates.filter { $0.source.kind.requiresRealCourse }.allSatisfy { $0.source.courseID != nil },
            "课程类候选都带真实课程来源，不编造内容"
        )

        // 30. 不计时直接完成：任务算完成，但绝不凭空产生学习分钟数
        let unrecorded = productionCoordinator.completeDirect(
            key: StudyCompletionKey.reviewTask(reviewTask.id, dayKey: dayKey),
            dayKey: dayKey,
            source: .reviewTask(reviewTask.id),
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.4),
            completedScope: .tasks(1),
            minutes: 0,
            durationSource: .unrecorded,
            durationNote: "复习列表直接标记完成，未计时。",
            assessment: StudyAssessment(selfRating: ReviewPlanner.Quality.good.rawValue),
            note: "",
            state: reviewSnapshot,
            context: context,
            successMessage: ""
        )
        let unrecordedSummary = unrecorded.snapshot.dailySummary(for: dayKey)
        checkEqual(unrecordedSummary.recordedMinutes, 0, "不计时直接完成不会增加学习分钟数")
        checkEqual(unrecordedSummary.standardCompletedItemCount, 1, "不计时直接完成仍然记为完成")
        checkEqual(unrecordedSummary.unrecordedDurationItemCount, 1, "未记录时长的完成被单独统计")
        checkEqual(unrecorded.snapshot.completionEvents[0].durationSource, .unrecorded, "时长来源标记为未记录")
        check(!unrecorded.snapshot.completionEvents[0].hasRecordedDuration, "未记录时长的完成不计入时长")

        // 31. 真实计时完成：按会话有效时长计入，来源标记为真实计时
        let reviewTaskID2 = UUID()
        var sessionSnapshot = StoreSnapshot()
        let sessionPlanID = UUID()
        let sessionItem = DailyPlanItem(
            planID: sessionPlanID,
            source: .reviewTask(reviewTaskID2),
            title: "复习任务：三角函数",
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.4),
            estimatedMinutes: 20,
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        sessionSnapshot.dailyPlans = [
            DailyStudyPlan(
                id: sessionPlanID,
                dayKey: dayKey,
                budget: DailyPlanBudget(capacityMinutes: 120),
                items: [sessionItem],
                createdAt: now,
                updatedAt: now
            )
        ]
        sessionSnapshot.reviewTasks = [
            ReviewTask(id: reviewTaskID2, title: "复习任务：三角函数", dueDate: now, priority: 3)
        ]
        // 心跳是"此刻"，因此这是一段被连续观测的正常学习（不该被判成中断）。
        let runningSession = StudySession(
            planID: sessionPlanID,
            planItemID: sessionItem.id,
            dayKey: dayKey,
            startedAt: now.addingTimeInterval(-20 * 60),
            createdAt: now.addingTimeInterval(-20 * 60),
            updatedAt: now
        )
        sessionSnapshot.studySessions = [runningSession]

        let finishedSession = productionCoordinator.coordinate(
            .finishSession(sessionID: runningSession.id, scope: .tasks(1), assessment: StudyAssessment(selfRating: 4), note: ""),
            state: sessionSnapshot,
            context: context
        )
        checkEqual(finishedSession.snapshot.completionEvents.count, 1, "结束会话产生一条完成事件")
        checkEqual(finishedSession.snapshot.completionEvents[0].actualMinutes, 20, "真实计时按会话有效时长计入")
        checkEqual(finishedSession.snapshot.completionEvents[0].durationSource, .timed, "时长来源标记为真实计时")
        checkEqual(finishedSession.snapshot.dailySummary(for: dayKey).recordedMinutes, 20, "计时完成计入学习分钟数")

        // 31b. 统一提交统计：完成动作会产出 insertCompletion 意图，
        //      AppStore 据此把"当日打卡"写进同一份候选快照（一次提交保持一致）。
        check(
            finishedSession.mutations.contains { $0.kind == .insertCompletion },
            "完成动作会产出 insertCompletion 意图（打卡与完成事件同一次提交）"
        )
        check(
            finishedSession.mutations.contains { $0.kind == .upsertPlan },
            "完成动作同时会更新计划项状态（同一份快照）"
        )

        // 32. 跨入口统一去重：会话完成后再从计划项直接完成，不会重复计数
        let completionKey = finishedSession.snapshot.completionEvents[0].idempotencyKey
        check(completionKey.hasPrefix("completion|item:"), "会话完成使用计划项统一去重键（实际：\(completionKey)）")
        let duplicatedByDirectEntry = productionCoordinator.coordinate(
            .completeItemDirectly(planItemID: sessionItem.id, scope: .tasks(1), minutes: 0, assessment: nil, note: ""),
            state: finishedSession.snapshot,
            context: context
        )
        checkEqual(duplicatedByDirectEntry.snapshot.completionEvents.count, 1, "跨入口重复提交只保留一条完成事件")
        check(!duplicatedByDirectEntry.didChange, "跨入口重复提交不会产生新的写入")
        checkEqual(
            duplicatedByDirectEntry.snapshot.reviewTasks[0].repetitionCount,
            1,
            "跨入口重复提交不会重复推进复习周期（SM-2 只推进一次）"
        )

        // 33. 全局单会话：已有计时时不允许再开第二个
        var twoItemSnapshot = sessionSnapshot
        twoItemSnapshot.studySessions = [runningSession]
        let secondItem = DailyPlanItem(
            planID: sessionPlanID,
            source: .manual(note: "另一条任务"),
            title: "另一条任务",
            plannedScope: .tasks(1),
            estimatedMinutes: 15,
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        twoItemSnapshot.dailyPlans[0].items.append(secondItem)

        let blockedStart = productionCoordinator.coordinate(
            .startSession(planItemID: secondItem.id),
            state: twoItemSnapshot,
            context: context
        )
        check(!blockedStart.didChange, "已有计时时不允许开始第二个计时")
        checkEqual(blockedStart.snapshot.studySessions.count, 1, "被拒绝的启动不会写入新会话")
        if case .invalidState = blockedStart.rejection {} else {
            check(false, "第二个计时会返回明确的拒绝原因")
        }
        let allowedRestart = productionCoordinator.coordinate(
            .startSession(planItemID: runningSession.planItemID ?? UUID()),
            state: twoItemSnapshot,
            context: context
        )
        check(allowedRestart.didChange || allowedRestart.rejection != nil, "同一条任务的重复启动走幂等判定而不是全局冲突")

        // 34. 跨日遗留会话：结束会归档到它自己的学习日，不影响今天的统计
        let yesterday = context.dayKey(for: date(2026, 9, 22, 10, 0))
        var staleSnapshot = StoreSnapshot()
        let staleSession = StudySession(
            planID: sessionPlanID,
            planItemID: sessionItem.id,
            dayKey: yesterday,
            startedAt: date(2026, 9, 22, 20, 0),
            createdAt: date(2026, 9, 22, 20, 0),
            updatedAt: date(2026, 9, 23, 9, 50)
        )
        staleSnapshot.studySessions = [staleSession]
        staleSnapshot.reviewTasks = [
            ReviewTask(id: reviewTaskID2, title: "复习任务：三角函数", dueDate: date(2026, 9, 22, 20, 0), priority: 3)
        ]
        checkEqual(
            staleSnapshot.studySessions.filter { $0.state.isActive && $0.dayKey != dayKey }.count,
            1,
            "跨日遗留会话可以被识别出来（不会既挡住刷新又看不见）"
        )

        let staleFinished = productionCoordinator.coordinate(
            .finishSession(sessionID: staleSession.id, scope: .tasks(1), assessment: nil, note: "跨日遗留会话，用户手动结束"),
            state: staleSnapshot,
            context: context
        )
        checkEqual(staleFinished.snapshot.completionEvents.count, 1, "跨日遗留会话可以被正常结束")
        checkEqual(
            staleFinished.snapshot.completionEvents[0].dayKey,
            yesterday,
            "跨日会话的完成事件归属它原本的学习日（不会给今天重复发奖）"
        )
        checkEqual(
            staleFinished.snapshot.dailySummary(for: dayKey).source,
            .none,
            "跨日会话不会给今天产生任何学习记录"
        )
        checkEqual(
            staleFinished.snapshot.dailySummary(for: dayKey).recordedMinutes ?? 0,
            0,
            "跨日会话的时长不会算进今天的统计"
        )

        // 35. 未确认中断：未知离线时间默认排除；连续学习不误判
        var interruptedSnapshot = StoreSnapshot()
        let interruptedSession = StudySession(
            dayKey: dayKey,
            startedAt: now.addingTimeInterval(-120 * 60),
            createdAt: now.addingTimeInterval(-120 * 60),
            updatedAt: now.addingTimeInterval(-90 * 60)
        )
        interruptedSnapshot.studySessions = [interruptedSession]
        let interruptedFinish = productionCoordinator.coordinate(
            .finishSession(sessionID: interruptedSession.id, scope: .tasks(1), assessment: nil, note: ""),
            state: interruptedSnapshot,
            context: context
        )
        checkEqual(
            interruptedFinish.snapshot.completionEvents[0].actualMinutes,
            30,
            "未确认的 90 分钟离线时间被排除，只保留确认过的 30 分钟"
        )
        checkEqual(interruptedFinish.snapshot.completionEvents[0].durationSource, .timed, "排除后仍标记为计时来源")
        check(
            interruptedFinish.snapshot.studySessions[0].note.contains("auto-excluded"),
            "自动排除会在会话里留下来源说明"
        )

        let continuousFinish = productionCoordinator.coordinate(
            .finishSession(sessionID: runningSession.id, scope: .tasks(1), assessment: nil, note: ""),
            state: sessionSnapshot,
            context: context
        )
        checkEqual(
            continuousFinish.snapshot.completionEvents[0].actualMinutes,
            20,
            "连续观测到的正常学习不会被误判为中断"
        )

        // 36. 超过可信上限的部分默认排除
        let cappedEngine = StudySessionEngineImpl(configuration: StudySessionEngineConfiguration(maximumSessionMinutes: 60))
        let longSession = StudySession(
            dayKey: dayKey,
            startedAt: now.addingTimeInterval(-180 * 60),
            createdAt: now.addingTimeInterval(-180 * 60),
            updatedAt: now
        )
        let capped = StudyPlanCoordinator.excludingUntrustedTime(
            from: longSession,
            engine: cappedEngine,
            context: context
        )
        checkEqual(
            capped.effectiveMinutes(asOf: now, calendar: context.calendar),
            60,
            "超过可信上限的时长被排除，只保留上限内的部分"
        )
        check(capped.note.contains("untrustedDuration"), "超上限排除会留下来源说明")

        // 37. 手动补记时长：保留来源与原因，并计入学习分钟数
        let corrected = unrecorded.snapshot.completionEvents[0].correctingDuration(
            to: 45,
            source: .manualEntry,
            reason: "在书上做了 45 分钟"
        )
        var correctedSnapshot = unrecorded.snapshot
        correctedSnapshot.completionEvents = [corrected]
        let correctedSummary = correctedSnapshot.dailySummary(for: dayKey)
        checkEqual(corrected.durationSource, .manualEntry, "补记后时长来源变为手动补记")
        checkEqual(corrected.durationNote, "在书上做了 45 分钟", "补记保留原因")
        checkEqual(correctedSummary.recordedMinutes, 45, "补记后计入学习分钟数")
        checkEqual(correctedSummary.unrecordedDurationItemCount, 0, "补记后不再是未记录")

        // 38. 存储不可用/不可写时明确失败（不返回成功）
        let filePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrationStoreIsAFile-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: filePath.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: filePath) }
        var initializationThrew = false
        do {
            _ = try SnapshotFileStore(location: SnapshotStoreLocation(directory: filePath))
        } catch {
            initializationThrew = true
        }
        check(initializationThrew, "存储位置不可用时初始化明确失败（不会被静默跳过）")

        let readOnlyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrationReadOnly-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDirectory.path)
            try? FileManager.default.removeItem(at: readOnlyDirectory)
        }
        do {
            let readOnlyStore = try SnapshotFileStore(location: SnapshotStoreLocation(directory: readOnlyDirectory))
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDirectory.path)
            var writeThrew = false
            do {
                try readOnlyStore.save(StoreSnapshot())
            } catch {
                writeThrew = true
            }
            check(writeThrew, "目录不可写时保存明确抛错（调用方因此不会显示成功）")
        } catch {
            check(false, "只读目录的存储初始化不应失败：\(error)")
        }

        // 40. 减量：模式由策略决定，预览与应用一致（不能预览保底、应用成轻量）
        var reduceSnapshot = StoreSnapshot()
        let reducePlanID = UUID()
        let reduceItem = DailyPlanItem(
            planID: reducePlanID,
            source: .manual(note: "一组 5 道题"),
            title: "一组 5 道题",
            plannedScope: .questions(5),
            minimumScope: .questions(2),
            estimatedMinutes: 20,
            scheduledDayKey: dayKey,
            isSplittable: true,
            createdAt: now,
            updatedAt: now
        )
        reduceSnapshot.dailyPlans = [
            DailyStudyPlan(
                id: reducePlanID,
                dayKey: dayKey,
                budget: DailyPlanBudget(capacityMinutes: 20, plannedMinutes: 20),
                items: [reduceItem],
                createdAt: now,
                updatedAt: now
            )
        ]
        let reducePolicy = StudyMinimumPlanPolicy(
            configuration: MinimumPlanPolicyConfiguration.standard(
                availability: reduceSnapshot.availabilityPreferences,
                isManual: true
            )
        )
        let previewProposal = reducePolicy.reduce(
            plan: reduceSnapshot.dailyPlans[0],
            remainingMinutes: 12,
            splittableItemIDs: [reduceItem.id],
            context: context
        )
        let applied = productionCoordinator.coordinate(
            .applyMinimumPlan(dayKey: dayKey, remainingMinutes: 12, expectedPlanID: reducePlanID, expectedVersion: 1),
            state: reduceSnapshot,
            context: context
        )
        let appliedPlan = applied.snapshot.dailyPlans.first { $0.isActive }
        checkEqual(appliedPlan?.mode, previewProposal.plan.mode, "应用后的模式必须等于预览的模式")
        checkEqual(appliedPlan?.mode, .minimum, "剩余 12 分钟、只留 1 条核心动作时应为保底")
        check(applied.snapshot.completionEvents.isEmpty, "减量不会写入任何完成记录")
        check(
            (appliedPlan?.unplaceable.isEmpty == false),
            "缩掉的剩余范围被保留为待安排，而不是消失"
        )
        check(
            appliedPlan?.unplaceable.allSatisfy { $0.detail.contains("待安排") && $0.detail.contains("未顺延完成") } ?? false,
            "待安排项明确说明未完成、未顺延完成"
        )

        // 41. 过期预览必须被拒绝，不能悄悄应用成别的方案
        let staleApply = productionCoordinator.coordinate(
            .applyMinimumPlan(dayKey: dayKey, remainingMinutes: 12, expectedPlanID: reducePlanID, expectedVersion: 99),
            state: applied.snapshot,
            context: context
        )
        check(!staleApply.didChange, "版本不符的预览不会被应用")
        if case .invalidState = staleApply.rejection {} else {
            check(false, "过期预览会返回明确的拒绝原因")
        }
        checkEqual(staleApply.snapshot.dailyPlans.count, applied.snapshot.dailyPlans.count, "拒绝时不会新增计划版本")

        // 42a. 撤销减量（没有新完成时）：恢复到减量前的内容
        let undoneClean = productionCoordinator.coordinate(.undoMinimumPlan(dayKey: dayKey), state: applied.snapshot, context: context)
        let restoredClean = undoneClean.snapshot.dailyPlans.first { $0.isActive }
        check(undoneClean.didChange, "撤销减量会产生新的计划版本")
        checkEqual(restoredClean?.mode, .standard, "撤销后回到减量前的标准模式")
        checkEqual(
            restoredClean?.plannedMinutesFromItems,
            reduceItem.estimatedMinutes,
            "撤销后恢复到减量前的任务规模"
        )
        let undoAgain = productionCoordinator.coordinate(.undoMinimumPlan(dayKey: dayKey), state: undoneClean.snapshot, context: context)
        check(!undoAgain.didChange, "一次减量撤销后再次调用会被拒绝")
        checkEqual(undoAgain.snapshot.dailyPlans.count, undoneClean.snapshot.dailyPlans.count, "重复撤销不再产生新计划版本")
        if case .invalidState = undoAgain.rejection {} else {
            check(false, "重复撤销返回明确的无可撤销状态")
        }

        // 42b. 撤销减量不能覆盖减量后新增的完成记录
        var afterReduction = applied.snapshot
        if let reducedItemID = appliedPlan?.items.first?.id {
            let completionAfterReduction = productionCoordinator.coordinate(
                .completeItemDirectly(planItemID: reducedItemID, scope: .questions(2), minutes: 0, assessment: nil, note: ""),
                state: afterReduction,
                context: context
            )
            afterReduction = completionAfterReduction.snapshot
        }
        let completionsBeforeUndo = afterReduction.completionEvents.filter { !$0.isRevoked }.count
        let undone = productionCoordinator.coordinate(.undoMinimumPlan(dayKey: dayKey), state: afterReduction, context: context)
        checkEqual(
            undone.snapshot.completionEvents.filter { !$0.isRevoked }.count,
            completionsBeforeUndo,
            "撤销减量不会删除减量后的完成记录"
        )
        checkEqual(
            undone.snapshot.completionEvents.first?.tier,
            .minimum,
            "保留的完成记录保持原来的档次"
        )

        // 43. 用户自定义睡眠时间被尊重（不再使用固定的 23:00–07:00）
        let customSleep = AvailabilitySettings(
            weekdayStudyWindows: [],
            weekendStudyWindows: [],
            sleepWindows: [
                DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 1, minute: 0), end: TimeOfDay(hour: 5, minute: 0))
            ],
            customBlocks: []
        )
        var customSleepSnapshot = reduceSnapshot
        customSleepSnapshot.availabilitySettings = customSleep
        customSleepSnapshot.planningPreferences = PlanningPreferences(
            autoReduceEnabled: true,
            planningTimeZoneIdentifier: timeZoneIdentifier
        )
        let customAutomaticPolicy = StudyEngineRegistry.makeMinimumPlanPolicy(
            for: customSleepSnapshot,
            isManual: false
        )!
        let customManualPolicy = StudyEngineRegistry.makeMinimumPlanPolicy(
            for: customSleepSnapshot,
            isManual: true
        )!
        check(
            (customAutomaticPolicy as? StudyMinimumPlanPolicy)?.configuration.sleepWindows == customSleep.sleepWindows,
            "自动路径工厂把用户睡眠窗口注入真实策略"
        )
        let latePlan = reduceSnapshot.dailyPlans[0]
        let nightContext = PlanningContext(now: date(2026, 9, 23, 23, 40), timeZoneIdentifier: timeZoneIdentifier)
        let nightProposal = customAutomaticPolicy.reduce(plan: latePlan, remainingMinutes: 30, splittableItemIDs: [], context: nightContext)
        check(
            !nightProposal.explanation.blockedReasons.contains { $0.contains("睡眠") },
            "23:40 不在用户配置的 01:00–05:00 睡眠时段内，不应触发睡眠保护"
        )
        let earlyContext = PlanningContext(now: date(2026, 9, 23, 2, 0), timeZoneIdentifier: timeZoneIdentifier)
        let earlyProposal = customManualPolicy.reduce(plan: latePlan, remainingMinutes: 30, splittableItemIDs: [], context: earlyContext)
        check(earlyProposal.isRestSuggestion, "落在用户配置的睡眠时段内应返回休息建议")
        check(
            earlyProposal.explanation.blockedReasons.contains { $0.contains("睡眠") },
            "睡眠保护要说明原因"
        )
        // 没有任何睡眠配置 → 不做睡眠保护（不替用户假设）
        var noSleepSnapshot = customSleepSnapshot
        noSleepSnapshot.availabilitySettings = .unconfigured
        let noSleepPolicy = StudyEngineRegistry.makeMinimumPlanPolicy(for: noSleepSnapshot, isManual: true)!
        let noSleepProposal = noSleepPolicy.reduce(plan: latePlan, remainingMinutes: 30, splittableItemIDs: [], context: nightContext)
        check(
            !noSleepProposal.explanation.blockedReasons.contains { $0.contains("睡眠") },
            "用户没有配置睡眠时段时不应假定固定睡眠窗口"
        )

        // 44. 自动减量默认关闭；关闭后仍可手动采用方案
        checkEqual(PlanningPreferences().autoReduceEnabled, false, "自动减量默认关闭")
        var autoOffPlan = reduceSnapshot.dailyPlans[0]
        autoOffPlan.explanation.blockedReasons.append(MinimumPlanPolicyConfiguration.autoReduceDisabledMarker)
        var autoOffSnapshot = reduceSnapshot
        autoOffSnapshot.dailyPlans = [autoOffPlan]
        let autoPolicy = StudyEngineRegistry.makeMinimumPlanPolicy(for: autoOffSnapshot, isManual: false)!
        let autoResult = autoPolicy.reduce(plan: autoOffPlan, remainingMinutes: 12, splittableItemIDs: [reduceItem.id], context: context)
        checkEqual(
            autoResult.plan.plannedMinutesFromItems,
            autoOffPlan.plannedMinutesFromItems,
            "自动减量为关时，自动路径不会改动计划"
        )
        let manualPolicy = StudyEngineRegistry.makeMinimumPlanPolicy(for: autoOffSnapshot, isManual: true)!
        let manualProposal = manualPolicy.reduce(plan: autoOffPlan, remainingMinutes: 12, splittableItemIDs: [reduceItem.id], context: context)
        check(
            manualProposal.plan.plannedMinutesFromItems <= autoOffPlan.plannedMinutesFromItems,
            "自动减量为关时，用户仍可主动采用手动方案"
        )
        check(
            manualProposal.reducedMinutes < autoOffPlan.plannedMinutesFromItems || manualProposal.isRestSuggestion,
            "手动方案确实产生了减量效果"
        )

        // 45. 娱乐：不能同时开始两个计时；跨日/过期/已使用的奖励不可操作
        var rewardState = StoreSnapshot()
        rewardState.entertainmentRules = [
            EntertainmentRule(
                name: "完成一项奖励 30 分钟",
                condition: .standardItems(1),
                rewardMinutes: 30,
                createdAt: now,
                updatedAt: now
            )
        ]
        rewardState.completionEvents = [
            CompletionEvent.make(
                planItemID: UUID(),
                dayKey: dayKey,
                plannedScope: .tasks(1),
                completedScope: .tasks(1),
                actualMinutes: 20,
                durationSource: .timed,
                completedAt: now,
                createdAt: now
            )
        ]
        let granted = productionCoordinator.coordinate(.refresh(dayKey: dayKey), state: rewardState, context: context)
        checkEqual(granted.snapshot.rewardGrants.count, 1, "达标后发放一条奖励")
        let grantA = granted.snapshot.rewardGrants[0]

        let startedA = productionCoordinator.coordinate(.startReward(grantID: grantA.id), state: granted.snapshot, context: context)
        checkEqual(startedA.snapshot.rewardGrants[0].state, .started, "开始娱乐计时后状态为已开始")
        checkEqual(startedA.reminderChanges.count, 1, "开始娱乐只安排一条到期提醒")
        checkEqual(startedA.reminderChanges.first?.kind, .entertainmentEnd, "娱乐提醒有明确的类型")
        checkEqual(
            startedA.reminderChanges.first?.businessID,
            grantA.id.uuidString,
            "娱乐提醒统一绑定 grantID"
        )
        checkEqual(
            startedA.reminderChanges.first?.stableIdentifier,
            ReminderKind.entertainmentEnd.identifierPrefix + grantA.id.uuidString,
            "娱乐提醒标识 = 类型前缀 + grantID（不再用标题哈希）"
        )

        // 改规则不会重新发同日奖励；构造第二条独立测试记录来验证全局单计时。
        var secondRuleState = startedA.snapshot
        secondRuleState.entertainmentRules[0] = secondRuleState.entertainmentRules[0].revised(
            name: "完成一项奖励 45 分钟",
            rewardMinutes: 45,
            at: now
        )
        var editedWhileRunning = productionCoordinator.coordinate(.refresh(dayKey: dayKey), state: secondRuleState, context: context)
        checkEqual(editedWhileRunning.snapshot.rewardGrants.count, 1, "编辑规则不会再次发放同日奖励")
        checkEqual(editedWhileRunning.snapshot.rewardGrants.first?.state, .started, "编辑规则不会中断正在进行的娱乐")
        let editedRule = editedWhileRunning.snapshot.entertainmentRules[0]
        var grantB = grantA
        grantB.id = UUID()
        grantB.grantKey = "独立单计时验证-\(UUID().uuidString)"
        grantB.ruleSnapshot = editedRule.snapshotValue
        grantB.ruleRevisionID = editedRule.revisionID
        grantB.ruleVersion = editedRule.ruleVersion
        grantB.grantedMinutes = 45
        grantB.state = .claimed
        grantB.claimedAt = now
        grantB.startedAt = nil
        grantB.endedAt = nil
        grantB.usedMinutes = 0
        grantB.revocation = nil
        editedWhileRunning.snapshot.rewardGrants.append(grantB)
        let blockedSecond = productionCoordinator.coordinate(.startReward(grantID: grantB.id), state: editedWhileRunning.snapshot, context: context)
        check(!blockedSecond.didChange, "已有娱乐计时时不能开始第二个计时")
        if case .anotherRewardRunning = blockedSecond.rejection {} else {
            check(false, "第二个娱乐计时会返回明确的拒绝原因")
        }

        // 提前结束 → 取消到期提醒
        let finishedA = productionCoordinator.coordinate(.finishReward(grantID: grantA.id, usedMinutes: 5), state: editedWhileRunning.snapshot, context: context)
        checkEqual(finishedA.snapshot.rewardGrants[0].state, .finished, "结束娱乐计时后状态为已结束")
        checkEqual(finishedA.reminderChanges.first?.action, .cancel, "提前结束会取消这条娱乐的到期提醒")
        checkEqual(finishedA.reminderChanges.first?.businessID, grantA.id.uuidString, "取消也绑定同一个 grantID")
        checkEqual(finishedA.snapshot.rewardGrant(id: grantB.id)?.state, .claimed, "旧规则版本失效不妨碍正在进行的娱乐正常结束")
        let usedAgain = productionCoordinator.coordinate(.claimReward(grantID: grantA.id), state: finishedA.snapshot, context: context)
        check(!usedAgain.didChange, "已经使用完的奖励不能再领取")
        if case .rewardAlreadyUsed = usedAgain.rejection {} else {
            check(false, "已使用的奖励会返回明确的拒绝原因")
        }

        // 跨日奖励不可操作
        let yesterdayGrantState = granted.snapshot
        let tomorrowContext = PlanningContext(now: date(2026, 9, 24, 10, 0), timeZoneIdentifier: timeZoneIdentifier)
        let crossDayClaim = productionCoordinator.coordinate(.claimReward(grantID: grantA.id), state: yesterdayGrantState, context: tomorrowContext)
        check(!crossDayClaim.didChange, "昨天的奖励不能在今天领取")
        if case .rewardNotUsableToday = crossDayClaim.rejection {} else {
            check(false, "跨日奖励会返回明确的拒绝原因")
        }

        // 46. 空计划 / 没有完成事件不会解锁奖励
        var emptyPlanState = StoreSnapshot()
        emptyPlanState.entertainmentRules = rewardState.entertainmentRules
        let emptyRefresh = productionCoordinator.coordinate(.refresh(dayKey: dayKey), state: emptyPlanState, context: context)
        check(emptyRefresh.snapshot.rewardGrants.isEmpty, "没有完成事件时不会发放任何奖励")

        // 撤销学习后资格回退
        let revokedReward = productionCoordinator.coordinate(
            .revokeCompletion(completionID: granted.snapshot.completionEvents[0].id, reason: "误点"),
            state: granted.snapshot,
            context: context
        )
        checkEqual(
            revokedReward.snapshot.rewardGrants.first?.state,
            .revoked,
            "撤销完成会同步撤销尚未使用的奖励"
        )
        checkEqual(
            revokedReward.snapshot.dailySummary(for: dayKey).standardCompletedItemCount,
            0,
            "撤销完成后的达标数回退，解锁条件不被绕过"
        )

        print("")
        print("Integration flow verification complete. passed=\(passed) failed=\(failed)")
        if failed > 0 {
            exit(1)
        }
    }
}
