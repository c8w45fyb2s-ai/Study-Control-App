import Foundation

// MARK: - 工厂数据（仅测试 / 预览）

/// 仅用于测试或预览的工厂数据。
///
/// 硬约束：这些函数**只构造内存里的值**，不接受任何存储路径、不写文件，
/// 因此不可能把示例数据写进用户的真实资料库。所有示例标题都带「示例」前缀，
/// 避免被误认为真实学习内容。
enum StudyDataFactory {
    static let sampleMarker = "示例"

    static func context(now: Date, timeZoneIdentifier: String = "Asia/Shanghai") -> PlanningContext {
        PlanningContext(now: now, timeZoneIdentifier: timeZoneIdentifier)
    }

    static func semester(
        firstWeekStart: Date,
        weekCount: Int = 20,
        timeZoneIdentifier: String = "Asia/Shanghai"
    ) -> ScheduleSemester {
        ScheduleSemester(
            firstWeekStart: firstWeekStart,
            weekCount: weekCount,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    static func sampleCourse(
        name: String = "\(sampleMarker)课程",
        subjectName: String = "\(sampleMarker)科目",
        weekday: ScheduleWeekday = .monday,
        start: TimeOfDay = TimeOfDay(hour: 8, minute: 0),
        end: TimeOfDay = TimeOfDay(hour: 9, minute: 40),
        location: String = "\(sampleMarker)教室"
    ) -> Course {
        Course(
            name: name,
            subject: SubjectRef(displayName: subjectName),
            weekday: weekday,
            startTime: start,
            endTime: end,
            location: location,
            teacher: "\(sampleMarker)教师"
        )
    }

    static func sampleReviewTask(
        title: String = "\(sampleMarker)复习任务",
        dueDate: Date,
        knowledgePointID: UUID? = nil
    ) -> ReviewTask {
        ReviewTask(title: title, dueDate: dueDate, knowledgePointID: knowledgePointID)
    }

    static func sampleTimezoneDate(
        year: Int = 2026,
        month: Int = 3,
        day: Int = 2,
        hour: Int = 0,
        minute: Int = 0,
        timeZoneIdentifier: String = "Asia/Shanghai"
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// 一份包含计划、会话、完成事件、规则与奖励的示例快照（内存值，不落盘）。
    static func sampleSnapshot(
        now: Date,
        timeZoneIdentifier: String = "Asia/Shanghai"
    ) -> StoreSnapshot {
        let context = context(now: now, timeZoneIdentifier: timeZoneIdentifier)
        let firstWeekStart = sampleTimezoneDate(timeZoneIdentifier: timeZoneIdentifier)
        let course = sampleCourse()
        let dayKey = context.todayKey

        var snapshot = StoreSnapshot()
        snapshot.scheduleSemester = semester(firstWeekStart: firstWeekStart, timeZoneIdentifier: timeZoneIdentifier)
        snapshot.semesterIdentity = SemesterIdentity(name: "\(sampleMarker)学期", createdAt: now)
        snapshot.scheduleCourses = [course]
        snapshot.planningPreferences = PlanningPreferences(
            dailyCapMinutes: 180,
            planningTimeZoneIdentifier: timeZoneIdentifier
        )
        snapshot.availabilitySettings = .assumedDefaults

        let planID = UUID()
        let item = DailyPlanItem(
            planID: planID,
            source: .reviewTask(UUID()),
            title: "\(sampleMarker)复习任务",
            plannedScope: .tasks(4),
            minimumScope: .tasks(2),
            estimatedMinutes: 40,
            scheduledDayKey: dayKey,
            dueDate: now,
            createdAt: now,
            updatedAt: now
        )
        let plan = DailyStudyPlan(
            id: planID,
            dayKey: dayKey,
            version: 1,
            mode: .standard,
            budget: DailyPlanBudget(capacityMinutes: 180, dailyCapMinutes: 180, plannedMinutes: 40),
            goal: DailyPlanGoal(targetMinutes: 40, targetScope: .tasks(4), label: "\(sampleMarker)目标"),
            explanation: DailyPlanExplanation(lines: ["\(sampleMarker)解释：按当天可用容量安排。"]),
            items: [item],
            inputFingerprint: "sample",
            createdAt: now,
            updatedAt: now
        )
        snapshot.dailyPlans = [plan]
        snapshot.manualStudyTasks = [
            ManualStudyTask(
                id: StudyStableKey.uuid(from: "sample/manual-task"),
                title: "\(sampleMarker)手动任务",
                dueDate: now.addingTimeInterval(86_400),
                estimatedMinutes: 25,
                createdAt: now
            )
        ]

        let session = StudySession(
            planID: planID,
            planItemID: item.id,
            dayKey: dayKey,
            startedAt: now.addingTimeInterval(-3_600),
            endedAt: now,
            state: .finished,
            progress: .tasks(4),
            assessment: StudyAssessment(totalQuestions: 4, correctQuestions: 3, selfRating: 4),
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now
        )
        snapshot.studySessions = [session]

        let completion = CompletionEvent.make(
            sessionID: session.id,
            planID: planID,
            planItemID: item.id,
            dayKey: dayKey,
            source: item.source,
            plannedScope: item.plannedScope,
            minimumScope: item.minimumScope,
            completedScope: .tasks(4),
            actualMinutes: 40,
            completedAt: now,
            assessment: session.assessment,
            createdAt: now
        )
        snapshot.completionEvents = [completion]

        let rule = EntertainmentRule(
            name: "\(sampleMarker)娱乐规则",
            condition: .standardItems(1),
            fallback: .scaledReward(ratio: 0.5),
            rewardMinutes: 30,
            createdAt: now,
            updatedAt: now
        )
        snapshot.entertainmentRules = [rule]

        let progress = RewardConditionProgress(
            ruleID: rule.id,
            ruleRevisionID: rule.revisionID,
            metric: rule.condition.metric,
            achievedValue: 1,
            requiredValue: rule.condition.requiredValue,
            detail: "\(sampleMarker)进度",
            basisEventIDs: [completion.id],
            isSatisfied: true
        )
        snapshot.rewardGrants = [
            RewardGrant.make(
                ruleSnapshot: rule.snapshotValue,
                dayKey: dayKey,
                basisEventIDs: [completion.id],
                conditionProgress: progress,
                grantedMinutes: 30,
                grantedAt: now
            )
        ]

        return snapshot
    }

    /// 只有旧版本"每日完成总数"的快照（用于验证不会凭空推算时长与资格）。
    static func legacyOnlySnapshot(now: Date) -> StoreSnapshot {
        var snapshot = StoreSnapshot()
        snapshot.schemaVersion = StudySchema.legacyBaselineVersion
        snapshot.dailyActivityRecords = [
            DailyActivityRecord(date: now, completedTaskCount: 3)
        ]
        return snapshot
    }
}
