import Foundation

// MARK: - F 模块：首页截图用的**演示数据**播种器
//
// 只写入命令行传入的目录（必须是隔离目录，例如 `.build-f/demo-store`），
// 绝不读写用户真实的 `store.json`。数据全部是演示用的通用条目，
// 不代表任何真实学习内容，也不参与 App 的正式逻辑。
//
// 用法：
//   swiftc -parse-as-library <CORE_MODEL_SOURCES> "study software/StudyHomePresentation.swift" \
//     "script/seed_dashboard_demo_store.swift" -o ".build-f/seed_dashboard_demo_store"
//   ".build-f/seed_dashboard_demo_store" ".build-f/demo-store"

@main
struct DashboardDemoSeed {

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("用法: seed_dashboard_demo_store <隔离目录> [full|minimum|empty]")
            exit(2)
        }
        let variant = arguments.count >= 3 ? arguments[2] : "full"

        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "zh_CN")

        let now = Date()
        let context = PlanningContext(now: now, timeZone: timeZone)
        let today = context.todayKey
        let todayStart = calendar.startOfDay(for: now)

        func offset(hours: Int = 0, minutes: Int = 0, days: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: days, hour: hours, minute: minutes), to: now) ?? now
        }

        // 学期：把本周设为第 6 周，保证今天有课。
        let weekdayComponent = calendar.component(.weekday, from: todayStart)
        let daysFromMonday = (weekdayComponent + 5) % 7
        let thisMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: todayStart) ?? todayStart
        let firstWeekStart = calendar.date(byAdding: .day, value: -35, to: thisMonday) ?? thisMonday
        let todayWeekday = ScheduleWeekday(calendarWeekday: weekdayComponent) ?? .monday

        let courseA = Course(
            name: "线性代数",
            subject: SubjectRef(displayName: "数学", linkedKnowledgeSubject: "数学"),
            weekday: todayWeekday,
            startTime: TimeOfDay(hour: 8, minute: 0),
            endTime: TimeOfDay(hour: 9, minute: 35),
            location: "教三 201",
            teacher: "李老师",
            recurrence: CourseRecurrence(lastWeek: 16)
        )
        let courseB = Course(
            name: "数据结构",
            subject: SubjectRef(displayName: "计算机", linkedKnowledgeSubject: "计算机"),
            weekday: todayWeekday,
            startTime: TimeOfDay(hour: 14, minute: 0),
            endTime: TimeOfDay(hour: 15, minute: 35),
            location: "实验楼 402",
            teacher: "王老师",
            recurrence: CourseRecurrence(lastWeek: 16)
        )

        // 学习资产（演示条目）
        let pointA = KnowledgePoint(title: "矩阵特征值与特征向量", subject: "数学", summary: "特征多项式与相似对角化。", mastery: 0.42)
        let pointB = KnowledgePoint(title: "二次型的标准形", subject: "数学", summary: "配方法与正交变换。", mastery: 0.30)
        let pointC = KnowledgePoint(title: "二叉搜索树", subject: "计算机", summary: "插入、删除与平衡。", mastery: 0.55)
        let mistakeA = Mistake(question: "求 3 阶矩阵的特征值", correctAnswer: "解特征多项式", errorReason: "行列式展开漏项", knowledgePointIDs: [pointA.id])
        let mistakeB = Mistake(question: "判断二次型正定性", correctAnswer: "顺序主子式全大于 0", errorReason: "与合同变换混淆", knowledgePointIDs: [pointB.id])

        // 到期的复习任务
        let taskA = ReviewTask(title: "复习任务：矩阵特征值与特征向量", dueDate: offset(hours: -6), knowledgePointID: pointA.id, priority: 3)
        let taskB = ReviewTask(title: "复习任务：二次型的标准形", dueDate: now, knowledgePointID: pointB.id, priority: 2)
        let taskC = ReviewTask(title: "复习任务：二叉搜索树", dueDate: offset(hours: 6), knowledgePointID: pointC.id, priority: 1)

        // 今日计划：一项已完成（标准完成），两项待开始
        let planID = UUID()
        let completedItem = DailyPlanItem(
            planID: planID,
            source: .reviewTask(taskA.id, knowledgePointID: pointA.id),
            title: taskA.title,
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.5),
            estimatedMinutes: 25,
            scheduledStart: offset(hours: -2),
            scheduledEnd: offset(hours: -1),
            scheduledDayKey: today,
            dueDate: taskA.dueDate,
            status: .completed,
            completionTier: .standard,
            achievedScope: .tasks(1),
            completedAt: offset(hours: -1),
            createdAt: now,
            updatedAt: now
        )
        let currentItem = DailyPlanItem(
            planID: planID,
            source: .reviewTask(taskB.id, knowledgePointID: pointB.id),
            title: taskB.title,
            plannedScope: .tasks(1),
            minimumScope: .tasks(0.5),
            estimatedMinutes: 25,
            scheduledStart: offset(minutes: 15),
            scheduledEnd: offset(minutes: 40),
            scheduledDayKey: today,
            dueDate: taskB.dueDate,
            isSplittable: true,
            createdAt: now,
            updatedAt: now
        )
        let laterItem = DailyPlanItem(
            planID: planID,
            source: .courseReview(courseID: courseB.id),
            title: "课程回顾：数据结构",
            plannedScope: .sections(1),
            estimatedMinutes: 20,
            scheduledStart: offset(minutes: 75),
            scheduledEnd: offset(minutes: 95),
            scheduledDayKey: today,
            dueDate: offset(hours: 6),
            createdAt: now,
            updatedAt: now
        )

        let plan = DailyStudyPlan(
            id: planID,
            dayKey: today,
            mode: .standard,
            budget: DailyPlanBudget(capacityMinutes: 210, dailyCapMinutes: 120, plannedMinutes: 70),
            goal: DailyPlanGoal(targetMinutes: 90, label: "今日目标"),
            explanation: DailyPlanExplanation(
                lines: ["今天有两节课，学习窗口只剩 19:00–22:30，先安排到期的复习任务。"],
                assumptions: ["按已配置的作息窗口计算可用时间。"]
            ),
            items: [completedItem, currentItem, laterItem],
            createdAt: now,
            updatedAt: now
        )

        let completion = CompletionEvent(
            id: UUID(),
            idempotencyKey: "demo|\(completedItem.id.uuidString)",
            planID: planID,
            planItemID: completedItem.id,
            dayKey: today,
            source: completedItem.source,
            plannedScope: completedItem.plannedScope,
            completedScope: .tasks(1),
            tier: .standard,
            actualMinutes: 25,
            completedAt: offset(hours: -1),
            createdAt: now
        )

        // 娱乐规则与待领取奖励（演示：标准完成 1 项换 30 分钟）
        let rule = EntertainmentRule(
            name: "看一集动画",
            condition: EntertainmentUnlockCondition.standardItems(1),
            fallback: .fixedMinimumReward(minutes: 10),
            rewardMinutes: 30,
            createdAt: now,
            updatedAt: now
        )
        let progress = RewardConditionProgress(
            ruleID: rule.id,
            ruleRevisionID: rule.revisionID,
            metric: .standardCompletedItemCount,
            achievedValue: 1,
            requiredValue: 1,
            detail: "今天标准完成 1 项。",
            basisEventIDs: [completion.id],
            isSatisfied: true
        )
        let grant = RewardGrant(
            id: UUID(),
            grantKey: "demo|\(rule.id.uuidString)|\(today.localDateString)",
            dayKey: today,
            ruleSnapshot: rule.snapshotValue,
            basisEventIDs: [completion.id],
            conditionProgress: progress,
            grantedMinutes: 30,
            state: .pending,
            grantedAt: now
        )

        let examGoal = ExamGoal(
            name: "线性代数期中",
            examDate: offset(days: 5),
            subjects: ["数学"],
            dailyAvailableMinutes: 90,
            targetScore: "90"
        )

        // 作息：工作日 19:00–22:30；每天 23:00–次日 07:00 睡眠。
        var sleepWindows: [DayTimeRange] = []
        for weekday in ScheduleWeekday.allCases {
            sleepWindows.append(
                DayTimeRange(
                    weekday: weekday,
                    start: TimeOfDay(hour: 23, minute: 0),
                    end: TimeOfDay(hour: 7, minute: 0),
                    endDayOffset: 1
                )
            )
        }
        let availability = AvailabilitySettings(
            weekdayStudyWindows: [
                DayTimeRange(weekday: .monday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 22, minute: 30)),
                DayTimeRange(weekday: .tuesday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 22, minute: 30)),
                DayTimeRange(weekday: .wednesday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 22, minute: 30)),
                DayTimeRange(weekday: .thursday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 22, minute: 30)),
                DayTimeRange(weekday: .friday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 22, minute: 30))
            ],
            weekendStudyWindows: [
                DayTimeRange(weekday: .saturday, start: TimeOfDay(hour: 9, minute: 0), end: TimeOfDay(hour: 12, minute: 0)),
                DayTimeRange(weekday: .saturday, start: TimeOfDay(hour: 14, minute: 0), end: TimeOfDay(hour: 21, minute: 0)),
                DayTimeRange(weekday: .sunday, start: TimeOfDay(hour: 9, minute: 0), end: TimeOfDay(hour: 12, minute: 0)),
                DayTimeRange(weekday: .sunday, start: TimeOfDay(hour: 14, minute: 0), end: TimeOfDay(hour: 21, minute: 0))
            ],
            sleepWindows: sleepWindows,
            customBlocks: [],
            commuteMinutes: 0,
            bufferMinutes: 10,
            minimumFreeBlockMinutes: 5
        )

        var snapshot = StoreSnapshot()
        snapshot.onboardingCompleted = true
        snapshot.settings.allowModelRequests = true
        snapshot.semesterIdentity = SemesterIdentity(name: "2026 春季学期", createdAt: now)
        snapshot.scheduleSemester = ScheduleSemester(
            firstWeekStart: firstWeekStart,
            weekCount: 18,
            timeZoneIdentifier: timeZone.identifier
        )
        snapshot.scheduleCourses = [courseA, courseB]
        snapshot.availabilitySettings = availability
        snapshot.planningPreferences.dailyCapMinutes = 120
        snapshot.planningPreferences.planningTimeZoneIdentifier = timeZone.identifier
        snapshot.planningPreferences.minimumScopeRatio = 0.5
        snapshot.knowledgePoints = [pointA, pointB, pointC]
        snapshot.mistakes = [mistakeA, mistakeB]
        snapshot.reviewTasks = [taskA, taskB, taskC]
        snapshot.dailyPlans = [plan]
        snapshot.completionEvents = [completion]
        snapshot.entertainmentRules = [rule]
        snapshot.rewardGrants = [grant]
        snapshot.examGoals = [examGoal]

        // 变体：只影响演示数据，用来覆盖首页的不同状态。
        switch variant {
        case "empty":
            // 尚未添加课表 + 尚未添加任务
            var empty = StoreSnapshot()
            empty.onboardingCompleted = true
            snapshot = empty
        case "minimum":
            // 保底模式 + 娱乐尚未解锁
            var reduced = plan
            reduced.mode = .minimum
            reduced.goal = DailyPlanGoal(targetMinutes: 30, label: "保底目标")
            reduced.items = [completedItem]
            reduced.budget = DailyPlanBudget(capacityMinutes: 40, plannedMinutes: 25)
            snapshot.dailyPlans = [reduced]
            snapshot.rewardGrants = []
        default:
            break
        }

        do {
            let store = try SnapshotFileStore(directory: directory)
            try store.save(snapshot)
            print("演示数据已写入：\(store.storeURL.path)")
            print("学习日：\(today.localDateString)（\(timeZone.identifier)）")
        } catch {
            print("写入失败：\(error)")
            exit(1)
        }
    }
}
