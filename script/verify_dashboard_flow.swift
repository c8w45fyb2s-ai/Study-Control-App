import Foundation

// MARK: - F 模块（首页 / 一级导航）行为验证
//
// 只编译 Foundation 与公共数据契约（源码目标目录之外，不会进入正式 App）。
// 覆盖的是业务行为：入口兼容映射、今日概览口径、任务选择、整页唯一主按钮、
// 娱乐状态机与规则版本绑定、反馈去重、跨午夜休息时段、考试摘要相关性。
//
// 运行方式见文件末尾注释。

@main
struct DashboardVerifyHarness {

    static func main() {

var checks = 0
var failures: [String] = []

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        print("  ✗ \(message)")
        failures.append(message)
    }
}

func section(_ title: String) {
    print("\n[\(title)]")
}

// MARK: - 固定时间与夹具

let timeZone = TimeZone(identifier: "Asia/Shanghai")!
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = timeZone
calendar.locale = Locale(identifier: "zh_CN")

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// 2026-03-04 是星期三。
let now = date(2026, 3, 4, 20, 0)
let context = PlanningContext(now: now, timeZone: timeZone)
let today = context.todayKey

func makeItem(
    title: String,
    minutes: Int = 15,
    start: Date? = nil,
    status: DailyPlanItemStatus = .pending,
    source: DailyPlanItemSourceKind = .reviewTask,
    dueDate: Date? = nil,
    tier: PlanCompletionTier? = nil,
    splittable: Bool = false
) -> DailyPlanItem {
    DailyPlanItem(
        planID: UUID(),
        source: DailyPlanItemSource(kind: source),
        title: title,
        plannedScope: .tasks(1),
        minimumScope: .tasks(0.5),
        estimatedMinutes: minutes,
        scheduledStart: start,
        scheduledEnd: start.map { $0.addingTimeInterval(TimeInterval(minutes * 60)) },
        scheduledDayKey: today,
        dueDate: dueDate,
        status: status,
        completionTier: tier,
        achievedScope: status == .completed ? .tasks(1) : nil,
        isSplittable: splittable,
        createdAt: now,
        updatedAt: now
    )
}

func makePlan(mode: DailyPlanMode, target: Int, items: [DailyPlanItem]) -> DailyStudyPlan {
    DailyStudyPlan(
        dayKey: today,
        mode: mode,
        budget: DailyPlanBudget(capacityMinutes: 120, plannedMinutes: items.reduce(0) { $0 + $1.estimatedMinutes }),
        goal: DailyPlanGoal(targetMinutes: target, label: "今日目标"),
        explanation: DailyPlanExplanation(lines: ["按可用容量和到期复习任务排的，先做最紧的一项。"]),
        items: items,
        createdAt: now,
        updatedAt: now
    )
}

func summary(
    recordedMinutes: Int?,
    standard: Int = 0,
    minimum: Int = 0,
    studied: Int = 0,
    source: DailySummarySource = .recordedEvents,
    legacy: Int? = nil
) -> DailyStudySummary {
    DailyStudySummary(
        dayKey: today,
        source: source,
        standardCompletedItemCount: standard,
        minimumCompletedItemCount: minimum,
        studiedItemCount: studied,
        recordedMinutes: recordedMinutes,
        legacyCompletedTaskCount: legacy,
        isEntertainmentEligible: source == .recordedEvents ? (standard + minimum) > 0 : nil,
        explanation: source == .recordedEvents ? "已完成事件汇总。" : "旧版本记录。"
    )
}

func makeRule(
    name: String = "看一集动画",
    requiredStandard: Int = 2,
    rewardMinutes: Int = 30,
    version: Int = 2
) -> EntertainmentRule {
    EntertainmentRule(
        name: name,
        condition: EntertainmentUnlockCondition.standardItems(requiredStandard),
        fallback: .fixedMinimumReward(minutes: 10),
        rewardMinutes: rewardMinutes,
        ruleVersion: version,
        createdAt: now,
        updatedAt: now
    )
}

func makeGrant(
    rule: EntertainmentRule,
    state: RewardGrantState,
    usedMinutes: Int = 0,
    grantedMinutes: Int = 30,
    version: Int
) -> RewardGrant {
    var snapshot = rule.snapshotValue
    snapshot.ruleVersion = version
    return RewardGrant(
        id: UUID(),
        grantKey: "grant|\(rule.id.uuidString)|\(today.localDateString)",
        dayKey: today,
        ruleSnapshot: snapshot,
        conditionProgress: RewardConditionProgress(
            ruleID: rule.id,
            ruleRevisionID: rule.revisionID,
            metric: .standardCompletedItemCount,
            achievedValue: Double(rule.condition.requiredValue),
            requiredValue: rule.condition.requiredValue,
            isSatisfied: true
        ),
        grantedMinutes: grantedMinutes,
        state: state,
        grantedAt: now,
        usedMinutes: usedMinutes
    )
}

// MARK: - 1. 一级入口与旧跳转兼容

section("一级入口与旧跳转兼容")
expect(StudyPrimarySection.allCases.count == 5, "一级入口必须是 5 个")
expect(
    StudyPrimarySection.allCases.map(\.title) == ["今日", "计划", "资料", "答疑", "我的"],
    "一级入口顺序与名称必须是 今日/计划/资料/答疑/我的"
)
expect(StudyPrimarySection.resolvingLegacyTabID("more") == .profile, "旧 tab「more」应落到「我的」")
expect(StudyPrimarySection.resolvingLegacyTabID("settings") == .profile, "旧 tab「settings」应落到「我的」")
expect(StudyPrimarySection.resolvingLegacyTabID("importData") == .library, "旧 tab「importData」应落到「资料」")
expect(StudyPrimarySection.resolvingLegacyTabID("reviews") == .plan, "旧 tab「reviews」应落到「计划」")
expect(StudyPrimarySection.resolvingLegacyTabID("dashboard") == .today, "旧 tab「dashboard」应落到「今日」")
expect(StudyPrimarySection.resolvingLegacyTabID("chat") == .chat, "旧 tab「chat」应落到「答疑」")
expect(StudyPrimarySection.resolvingLegacyTabID("plan") == .plan, "新入口 id 也要能被识别")
expect(StudyPrimarySection.resolvingLegacyTabID("") == nil, "空字符串不应映射到任何入口")
expect(StudyPrimarySection.resolvingLegacyTabID("   ") == nil, "只有空白的字符串不应映射")
expect(StudyPrimarySection.resolvingLegacyTabID("nonexistent") == nil, "未知取值不应映射")

// MARK: - 2. 今日概览

section("今日概览：状态、口径与不隐藏本地任务")

let emptySummary = summary(recordedMinutes: 0)

let noSchedule = StudyHomePresenter.overview(
    plan: nil,
    summary: emptySummary,
    isSemesterConfigured: false,
    planEngineMessage: nil,
    isModelConfigured: true
)
expect(noSchedule.state == .noSchedule, "没有课表也没有计划时必须是「尚未添加课表」状态")
expect(noSchedule.noticeLine?.contains("尚未添加课表") == true, "无课表时要给出明确提示")
expect(noSchedule.intensity == .none, "没有计划时档位是「尚未生成」")

let engineMissing = StudyHomePresenter.overview(
    plan: nil,
    summary: emptySummary,
    isSemesterConfigured: true,
    planEngineMessage: "尚未接入：今日计划引擎。",
    isModelConfigured: true
)
expect(engineMissing.state == .engineUnavailable, "引擎未接入要如实反映，而不是伪造计划")
expect(engineMissing.noticeLine?.contains("今日计划引擎") == true, "引擎未接入的说明要出现在提示里")

let noPlan = StudyHomePresenter.overview(
    plan: nil,
    summary: emptySummary,
    isSemesterConfigured: true,
    planEngineMessage: nil,
    isModelConfigured: true
)
expect(noPlan.state == .noPlan, "有课表但没有计划时是「今天还没有计划」")

let items = [
    makeItem(title: "复习任务：特征值", minutes: 15, start: date(2026, 3, 4, 19, 0)),
    makeItem(title: "复习任务：二次型", minutes: 20, start: date(2026, 3, 4, 20, 30))
]
let standardPlan = makePlan(mode: .standard, target: 60, items: items)
let partial = summary(recordedMinutes: 20, standard: 1, minimum: 0, studied: 0)

let planned = StudyHomePresenter.overview(
    plan: standardPlan,
    summary: partial,
    isSemesterConfigured: true,
    planEngineMessage: nil,
    isModelConfigured: true
)
expect(planned.state == .planned, "有计划和进度时是正常计划状态")
expect(planned.intensity == .standard, "标准计划的档位是「标准」")
expect(planned.targetMinutes == 60 && planned.completedMinutes == 20, "目标与已完成分钟必须来自真实数据")
expect(planned.remainingMinutes == 40, "还差多少分钟要算对")
expect(abs(planned.progressRatio - 1.0 / 3.0) < 0.0001, "进度比例要按 已完成/目标 计算")
expect(planned.progressText.contains("20") && planned.progressText.contains("60"), "进度文字要同时给出已完成与目标")
expect(planned.reasonLine == "按可用容量和到期复习任务排的，先做最紧的一项。", "安排原因要来自计划的解释")
expect(planned.completionText.contains("标准完成 1 项"), "完成口径要分别给出标准/保底/已学习")
expect(planned.completionCompactText == "标准 1 · 保底 0 · 已学习 0", "紧凑口径同样要分开标准/保底/已学习")

let minimumPlan = makePlan(mode: .minimum, target: 30, items: [items[0]])
let minimumOverview = StudyHomePresenter.overview(
    plan: minimumPlan,
    summary: summary(recordedMinutes: 10, minimum: 1),
    isSemesterConfigured: true,
    planEngineMessage: nil,
    isModelConfigured: true
)
expect(minimumOverview.state == .minimumMode, "保底计划要进入保底模式状态")
expect(minimumOverview.intensity == .minimum, "保底档位必须是「保底」而不是靠颜色区分")
expect(minimumOverview.stateLabel.contains("保底"), "保底状态要有明确的文字")

let reached = StudyHomePresenter.overview(
    plan: minimumPlan,
    summary: summary(recordedMinutes: 30, minimum: 1),
    isSemesterConfigured: true,
    planEngineMessage: nil,
    isModelConfigured: true
)
expect(reached.state == .goalReached, "达到目标分钟数要进入「今日目标完成」")
expect(reached.stateLabel.contains("保底目标已完成"), "保底达标要与标准达标分开表述")
expect(reached.progressRatio == 1, "达标后进度比例封顶为 1")

let lightOverview = StudyHomePresenter.overview(
    plan: makePlan(mode: .reduced, target: 45, items: [items[0]]),
    summary: summary(recordedMinutes: 0),
    isSemesterConfigured: true,
    planEngineMessage: nil,
    isModelConfigured: true
)
expect(lightOverview.intensity == .light, "自动减量在界面上叫「轻量」")
expect(lightOverview.intensity.label == "轻量", "轻量的文字标签要正确")
expect(lightOverview.noticeLine?.contains("轻量") == true, "减量原因要有一句说明")

let legacyOverview = StudyHomePresenter.overview(
    plan: nil,
    summary: summary(recordedMinutes: nil, source: .legacyAggregate, legacy: 3),
    isSemesterConfigured: true,
    planEngineMessage: nil,
    isModelConfigured: true
)
expect(legacyOverview.hasRecordedMinutes == false, "旧版本只有完成总数时不能编造时长")
expect(legacyOverview.progressText.contains("旧版本"), "旧数据要说明口径不同")

let offlineOverview = StudyHomePresenter.overview(
    plan: standardPlan,
    summary: partial,
    isSemesterConfigured: true,
    planEngineMessage: nil,
    isModelConfigured: false
)
expect(offlineOverview.state == .planned, "未配置 API Key 不得把计划状态变成不可用")
expect(offlineOverview.targetMinutes == 60, "未配置 API Key 不得隐藏本地任务与目标")
expect(offlineOverview.noticeLine?.contains("未配置 API Key") == true, "未配置 API Key 要有一行说明")

let examLine = StudyHomePresenter.examLine(
    goal: ExamGoal(
        name: "期中考试",
        examDate: date(2026, 3, 6, 9, 0),
        subjects: ["线性代数"],
        dailyAvailableMinutes: 60,
        targetScore: "90"
    ),
    plan: standardPlan,
    now: now,
    context: context
)
expect(examLine?.contains("期中考试") == true, "临近考试要给出一行摘要")

let farExamLine = StudyHomePresenter.examLine(
    goal: ExamGoal(
        name: "期末考试",
        examDate: date(2026, 6, 20, 9, 0),
        subjects: ["概率论"],
        dailyAvailableMinutes: 60,
        targetScore: "90"
    ),
    plan: standardPlan,
    now: now,
    context: context
)
expect(farExamLine == nil, "与今天安排无关的考试不应常驻首页")

let relatedFarExam = StudyHomePresenter.examLine(
    goal: ExamGoal(
        name: "期末考试",
        examDate: date(2026, 6, 20, 9, 0),
        subjects: ["二次型"],
        dailyAvailableMinutes: 60,
        targetScore: "90"
    ),
    plan: standardPlan,
    now: now,
    context: context
)
expect(relatedFarExam != nil, "今天确实有该科目的任务时，考试摘要应出现")

// MARK: - 3. 接下来做

section("接下来做：任务选择与进行中会话")

let mixedItems = [
    makeItem(title: "晚一点的任务", minutes: 20, start: date(2026, 3, 4, 21, 0)),
    makeItem(title: "已经完成的任务", minutes: 15, start: date(2026, 3, 4, 17, 0), status: .completed, tier: .standard),
    makeItem(title: "最近的一项", minutes: 15, start: date(2026, 3, 4, 18, 30)),
    makeItem(title: "第三项", minutes: 10, start: date(2026, 3, 4, 22, 0)),
    makeItem(title: "没有安排时间的任务", minutes: 10)
]
let steps = StudyHomePresenter.nextSteps(items: mixedItems, activeSession: nil, now: now, context: context, upcomingLimit: 2)
expect(steps.current?.title == "最近的一项", "当前推荐任务应是安排时间最早且未完成的那一项")
expect(steps.remainingCount == 4, "剩余数量要排除已完成项")
expect(steps.upcoming.count == 2, "后续任务最多两项")
expect(steps.upcoming.map(\.title).contains("最近的一项") == false, "后续任务不应包含当前任务")
expect(steps.upcoming.map(\.title) == ["晚一点的任务", "第三项"], "后续任务按安排时间排序")
expect(steps.isStudying == false, "没有会话时不应显示正在学习")

let emptySteps = StudyHomePresenter.nextSteps(items: [], activeSession: nil, now: now, context: context)
expect(emptySteps.isEmpty, "没有任务时是空状态")
expect(emptySteps.emptyTitle == "今天还没有任务", "没有任务时的标题要准确")
expect(emptySteps.emptySubtitle.contains("生成今日计划"), "没有任务时要给出下一步指引")

let doneItems = [makeItem(title: "已完成", status: .completed, tier: .standard)]
let doneSteps = StudyHomePresenter.nextSteps(items: doneItems, activeSession: nil, now: now, context: context)
expect(doneSteps.isEmpty, "全部完成后没有当前任务")
expect(doneSteps.emptyTitle.contains("都处理完了"), "全部完成与从未安排要区分")

let studyingItem = items[0]
let runningSession = StudySession(
    planItemID: studyingItem.id,
    dayKey: today,
    startedAt: now.addingTimeInterval(-30 * 60),
    state: .running,
    createdAt: now.addingTimeInterval(-30 * 60),
    updatedAt: now
)
let studying = StudyHomePresenter.nextSteps(
    items: items,
    activeSession: runningSession,
    now: now,
    context: context,
    upcomingLimit: 2
)
expect(studying.isStudying, "有进行中的会话时要显示正在学习")
expect(studying.isPaused == false, "运行中的会话不应显示暂停")
expect(studying.sessionStatusText?.contains("正在学习") == true, "正在学习要有一句状态")
expect(studying.sessionStatusText?.contains("30") == true, "状态里要包含已记录分钟")
expect(studying.upcoming.contains { $0.id == studyingItem.id } == false, "正在学的任务不应同时出现在后续任务里")

let pausedSession = StudySession(
    id: runningSession.id,
    planItemID: studyingItem.id,
    dayKey: today,
    startedAt: runningSession.startedAt,
    pauses: [StudyPauseInterval(startedAt: now.addingTimeInterval(-60), endedAt: nil)],
    state: .paused,
    createdAt: runningSession.createdAt,
    updatedAt: now
)
let paused = StudyHomePresenter.nextSteps(items: items, activeSession: pausedSession, now: now, context: context)
expect(paused.isPaused, "暂停中的会话要显示暂停")
expect(paused.sessionStatusText?.contains("已暂停") == true, "暂停状态要有明确文字")

let dueItem = makeItem(
    title: "逾期的复习任务",
    minutes: 15,
    start: date(2026, 3, 4, 19, 0),
    dueDate: date(2026, 3, 1, 9, 0)
)
let dueTask = StudyHomePresenter.task(from: dueItem, now: now, context: context)
expect(dueTask.isDueOnAnotherDay, "到期日与安排日不同必须被标出")
expect(dueTask.dueText?.contains("安排在今天") == true, "到期日与安排日要分开表达")
expect(dueTask.scheduleText == "19:00 开始", "安排时间要按规划时区显示")

let unscheduledTask = StudyHomePresenter.task(from: makeItem(title: "未安排时间", minutes: 10), now: now, context: context)
expect(unscheduledTask.scheduleText == "今天内安排", "没有安排时间时不应编造时间")

let manualTask = StudyHomePresenter.task(
    from: makeItem(title: "我自己加的任务", source: .manual),
    now: now,
    context: context
)
expect(manualTask.sourceLabel == "手动任务", "任务来源必须区分手动任务")
expect(manualTask.title == "我自己加的任务", "标题必须原样来自真实数据")
let courseTask = StudyHomePresenter.task(
    from: makeItem(title: "课程回顾：线性代数", source: .courseReview),
    now: now,
    context: context
)
expect(courseTask.sourceLabel == "课程回顾", "任务来源必须区分课程回顾")
expect(courseTask.accessibilityText.contains("课程回顾"), "无障碍朗读要包含来源")

// MARK: - 4. 整页唯一主按钮

section("整页唯一主按钮")

let rule = makeRule()
let claimableGrant = makeGrant(rule: rule, state: .pending, version: 2)
let claimableEntertainment = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [claimableGrant],
    progress: [],
    summary: partial,
    isWithinRestWindow: false
)
expect(claimableEntertainment.state == .claimable, "达标后应为可领取")
expect(claimableEntertainment.action == .claimReward(grantID: claimableGrant.id), "可领取时的操作要指向真实发放记录")

let withTask = StudyHomePresenter.pagePrimaryAction(
    nextSteps: steps,
    activeSession: nil,
    entertainment: claimableEntertainment
)
expect(withTask == .startStudy(itemID: steps.current!.id), "有任务时主按钮必须是开始学习")
expect(
    StudyHomePresenter.entertainmentActionIsPrimary(pagePrimary: withTask, entertainment: claimableEntertainment) == false,
    "已经有学习主按钮时，领取奖励必须降级为次级入口"
)

let withoutTask = StudyHomePresenter.pagePrimaryAction(
    nextSteps: doneSteps,
    activeSession: nil,
    entertainment: claimableEntertainment
)
expect(withoutTask == .claimReward(grantID: claimableGrant.id), "没有任务可做时，领奖成为唯一主按钮")
expect(
    StudyHomePresenter.entertainmentActionIsPrimary(pagePrimary: withoutTask, entertainment: claimableEntertainment),
    "没有学习主按钮时，领奖应当是主按钮"
)

let studyingPrimary = StudyHomePresenter.pagePrimaryAction(
    nextSteps: studying,
    activeSession: runningSession,
    entertainment: claimableEntertainment
)
expect(studyingPrimary == .finishSession(sessionID: runningSession.id), "正在学习时主按钮是结束学习")
let pausedPrimary = StudyHomePresenter.pagePrimaryAction(
    nextSteps: paused,
    activeSession: pausedSession,
    entertainment: claimableEntertainment
)
expect(pausedPrimary == .resumeSession(sessionID: pausedSession.id), "暂停时主按钮是继续学习")

let nothingPrimary = StudyHomePresenter.pagePrimaryAction(
    nextSteps: emptySteps,
    activeSession: nil,
    entertainment: StudyHomePresenter.entertainment(
        rules: [],
        grants: [],
        progress: [],
        summary: emptySummary,
        isWithinRestWindow: false
    )
)
expect(nothingPrimary == .none, "没有任何可做的事时不应有主按钮")
expect(nothingPrimary.isPrimary == false, "none 不是主按钮")

// MARK: - 5. 娱乐与休息

section("娱乐与休息：状态机与规则版本绑定")

let noRules = StudyHomePresenter.entertainment(
    rules: [],
    grants: [],
    progress: [],
    summary: emptySummary,
    isWithinRestWindow: false
)
expect(noRules.state == .noRules, "没有规则时是「还没有娱乐规则」")
expect(noRules.action == .none, "没有规则时不应出现领取按钮")

let locked = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [],
    progress: [],
    summary: partial,
    isWithinRestWindow: false
)
expect(locked.state == .locked, "有规则但没达标时是锁定状态")
expect(locked.detail.contains(rule.condition.displayText), "锁定状态要显示真实的解锁条件")
expect(locked.detail.contains("奖励 30 分钟"), "锁定状态要显示奖励时长")
expect(locked.headline.contains(rule.name), "锁定状态要显示规则名")

let rest = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [],
    progress: [],
    summary: partial,
    isWithinRestWindow: true
)
expect(rest.state == .restTime, "休息时段要显示「已到休息时间」")
expect(rest.headline == "已到休息时间", "休息状态文案要明确")
expect(rest.detail.contains("奖励不会消失"), "休息时段要说明奖励仍然有效")

let undecidable = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [],
    progress: [],
    summary: summary(recordedMinutes: nil, source: .legacyAggregate, legacy: 2),
    isWithinRestWindow: false
)
expect(undecidable.state == .undecidable, "只有旧版本总数时不能推算娱乐资格")

let claimedGrant = makeGrant(rule: rule, state: .claimed, version: 2)
let claimed = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [claimedGrant],
    progress: [],
    summary: partial,
    isWithinRestWindow: false
)
expect(claimed.state == .claimed, "已领取要显示已领取")
expect(claimed.action == .startReward(grantID: claimedGrant.id), "已领取时操作是开始娱乐")

let running = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [makeGrant(rule: rule, state: .started, usedMinutes: 12, version: 2)],
    progress: [],
    summary: partial,
    isWithinRestWindow: false
)
expect(running.state == .running, "已开始要显示娱乐进行中")
expect(running.remainingMinutes == 18, "剩余分钟数要按 发放 - 已用 计算")
expect(running.detail.contains("剩余 18 分钟"), "剩余分钟要出现在说明里")

let finished = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [makeGrant(rule: rule, state: .finished, usedMinutes: 30, version: 2)],
    progress: [],
    summary: partial,
    isWithinRestWindow: false
)
expect(finished.state == .finished, "已结束要显示本次娱乐已结束")
expect(finished.detail.contains("30"), "结束状态要给出实际使用分钟")
expect(finished.action == .none, "结束状态不应再有主按钮")

var revokedGrant = makeGrant(rule: rule, state: .claimed, version: 2)
revokedGrant = revokedGrant.revoked(at: now, reason: "相关学习记录已撤销，未使用奖励已取消。")!
let revoked = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [revokedGrant],
    progress: [],
    summary: partial,
    isWithinRestWindow: false
)
expect(revoked.state == .revoked, "首页显示未使用奖励已撤销")
expect(revoked.detail.contains("相关学习记录已撤销"), "首页简短说明撤销原因")
expect(revoked.action == .none, "撤销奖励不显示可领取操作")

var expiredGrant = makeGrant(rule: rule, state: .expired, version: 2)
expiredGrant.dayKey = StudyDayKey(date: now.addingTimeInterval(-86_400), timeZone: timeZone)
let expired = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [expiredGrant],
    progress: [],
    summary: partial,
    isWithinRestWindow: false
)
expect(expired.state == .expired, "首页显示超出使用日期的奖励已过期")
expect(expired.detail.contains(expiredGrant.dayKey.localDateString), "首页说明过期奖励所属日期")

// 规则被编辑到 v3 后，历史奖励仍然绑定当时的 v2。
var editedRule = rule
editedRule.ruleVersion = 3
let historical = StudyHomePresenter.entertainment(
    rules: [editedRule],
    grants: [makeGrant(rule: rule, state: .started, usedMinutes: 5, version: 2)],
    progress: [],
    summary: partial,
    isWithinRestWindow: false
)
expect(historical.ruleVersionText?.contains("v2") == true, "历史奖励必须保留当时的规则版本")
expect(historical.ruleVersionText?.contains("v3") == false, "规则编辑不得改写历史奖励的版本")

let withProgress = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [],
    progress: [
        RewardConditionProgress(
            ruleID: rule.id,
            ruleRevisionID: rule.revisionID,
            metric: .standardCompletedItemCount,
            achievedValue: 1,
            requiredValue: 2,
            isSatisfied: false
        )
    ],
    summary: partial,
    isWithinRestWindow: false
)
expect(withProgress.progressText == "1 / 2", "有评估结果时要显示条件进度")

let satisfiedNoGrant = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [],
    progress: [
        RewardConditionProgress(
            ruleID: rule.id,
            ruleRevisionID: rule.revisionID,
            metric: .standardCompletedItemCount,
            achievedValue: 2,
            requiredValue: 2,
            isSatisfied: true
        )
    ],
    summary: partial,
    isWithinRestWindow: false
)
expect(satisfiedNoGrant.headline.contains("已达标"), "条件已满足但还没发放时要如实说已达标")
expect(satisfiedNoGrant.detail.contains("不会重复发放"), "已达标待发放要说明幂等，避免用户重复点击")
expect(satisfiedNoGrant.progressText == "2 / 2", "已达标时进度应显示 2 / 2")

// 另一条规则的条件进度不得串到当前显示的规则上。
let otherRuleProgress = RewardConditionProgress(
    ruleID: UUID(),
    ruleRevisionID: UUID(),
    metric: .recordedMinutes,
    achievedValue: 90,
    requiredValue: 90,
    isSatisfied: true
)
let otherRule = StudyHomePresenter.entertainment(
    rules: [rule],
    grants: [],
    progress: [otherRuleProgress],
    summary: partial,
    isWithinRestWindow: false
)
expect(otherRule.progressText == nil, "不同规则的条件进度不能混用")
expect(otherRule.headline.contains("已达标") == false, "别的规则达标不能算当前规则达标")

// MARK: - 6. 反馈浮层去重

section("完成反馈：去重且不叠加")
var gate = StudyHomeFeedbackGate()
expect(gate.begin(trigger: 1), "首次触发应播放")
expect(gate.isShowingOverlay, "播放期间应标记浮层可见")
expect(gate.begin(trigger: 1) == false, "同一触发重复到达不得重复播放")
expect(gate.begin(trigger: 2) == false, "已有浮层时不得再叠加第二个")
gate.end(trigger: 1)
expect(gate.isShowingOverlay == false, "浮层结束后状态要复位")
expect(gate.begin(trigger: 2), "结束之后新的触发可以播放")
gate.end(trigger: 2)
expect(gate.begin(trigger: 0) == false, "0 不是有效触发")
expect(gate.begin(trigger: 1) == false, "已经处理过的旧触发不得回放")

// MARK: - 7. 休息时段（跨午夜）

section("休息时段判定（跨午夜）")
let restSettings = AvailabilitySettings(
    weekdayStudyWindows: [DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 22, minute: 0))],
    weekendStudyWindows: [],
    sleepWindows: [DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 23, minute: 0), end: TimeOfDay(hour: 7, minute: 0), endDayOffset: 1)],
    customBlocks: [DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 12, minute: 0), end: TimeOfDay(hour: 13, minute: 0))],
    commuteMinutes: 0,
    bufferMinutes: 0,
    minimumFreeBlockMinutes: 5
)
func restContext(at moment: Date) -> PlanningContext {
    PlanningContext(now: moment, timeZone: timeZone)
}
func isRest(_ moment: Date) -> Bool {
    let ctx = restContext(at: moment)
    return StudyHomePresenter.isWithinRestWindow(
        now: moment,
        dayKey: ctx.todayKey,
        settings: restSettings,
        context: ctx
    )
}
expect(isRest(date(2026, 3, 4, 23, 30)), "周三 23:30 属于睡眠时段")
expect(isRest(date(2026, 3, 5, 6, 30)), "周四 06:30 仍属于前一天的跨午夜睡眠")
expect(isRest(date(2026, 3, 4, 12, 30)), "周三 12:30 属于固定占用")
expect(isRest(date(2026, 3, 4, 20, 0)) == false, "周三 20:00 是学习时间，不是休息")
expect(isRest(date(2026, 3, 5, 8, 0)) == false, "周四 08:00 睡眠已结束")

// MARK: - 结果

print("\n共 \(checks) 项断言，失败 \(failures.count) 项。")
if failures.isEmpty {
    print("✅ F 模块（首页 / 一级导航）行为验证通过")
    exit(0)
} else {
    print("❌ 失败项：")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(1)
}

    }
}

// 运行命令（在仓库根目录，即包含 Makefile 的目录）：
//
//   S="study software"
//   swiftc -parse-as-library \
//     "$S/AIPlanIntent.swift" "$S/Models.swift" "$S/ReviewPlanner.swift" "$S/AIPlanIterationEngine.swift" \
//     "$S/AIPlanDraftQualityValidator.swift" "$S/AIPlanPatchEngine.swift" "$S/String+StudyText.swift" \
//     "$S/StudyContextRetriever.swift" "$S/StudyProfileSummary.swift" "$S/StudyFeatureInsights.swift" \
//     "$S/ScheduleResolver.swift" "$S/AvailabilityCalculator.swift" "$S/ScheduleModels.swift" \
//     "$S/StudyPlanningModels.swift" "$S/StudySessionModels.swift" "$S/EntertainmentModels.swift" \
//     "$S/PlanningContracts.swift" "$S/SnapshotMigration.swift" "$S/PersistenceStore.swift" \
//     "$S/StudyHomePresentation.swift" "script/verify_dashboard_flow.swift" -o ".build-f/verify_dashboard_flow"
//   ".build-f/verify_dashboard_flow"
