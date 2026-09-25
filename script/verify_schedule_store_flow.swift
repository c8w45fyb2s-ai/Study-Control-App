import Foundation

/// AppStore 与课表编辑保存结果的隔离集成测试。
@main
struct ScheduleStoreVerifyHarness {
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

    @MainActor
    static func main() {
        // 默认初始化也必须在测试隔离模式中运行；Makefile 为该进程设置独立目录与 TEST_MODE。
        if StudyRuntimeEnvironment.resolve().isTestMode {
            let defaultStore = AppStore()
            let defaultStoreDirectory = defaultStore.environment.storeLocation.directory
            defer { try? FileManager.default.removeItem(at: defaultStoreDirectory) }
            check(defaultStore.environment.isIsolatedStore, "默认 AppStore 初始化使用隔离测试目录")
            let defaultCourse = Course(
                name: "默认启动合成课程",
                subject: SubjectRef(displayName: "合成科目"),
                weekday: .monday,
                startTime: TimeOfDay(hour: 8, minute: 0),
                endTime: TimeOfDay(hour: 9, minute: 0)
            )
            checkEqual(defaultStore.saveCourse(defaultCourse), .saved, "AppStore() 默认启动后可以提交本地数据")
            checkEqual(
                try? SnapshotFileStore(location: defaultStore.environment.storeLocation).load()?.scheduleCourses.first?.id,
                defaultCourse.id,
                "默认初始化写入其隔离目录"
            )
        } else {
            check(false, "默认 AppStore 初始化验证要求启用测试隔离模式")
        }

        let location = SnapshotStoreLocation.isolatedTemporary(prefix: "ScheduleStoreVerify")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        do {
            // 未来 schema 让每次写入都以明确的存储错误失败；不触碰真实用户数据。
            try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
            try Data("{\"schemaVersion\":999}".utf8).write(to: location.storeURL, options: .atomic)
            let environment = StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: location,
                storeLocationOrigin: "schedule-store-verify"
            )
            let store = AppStore(environment: environment)
            check(store.environment.isTestMode, "显式注入环境保留测试隔离模式")
            checkEqual(store.environment.storeLocation.directory, location.directory, "显式注入环境使用指定隔离目录")
            let originalTemplates = store.snapshot.schedulePeriodTemplates
            let now = Date(timeIntervalSince1970: 1_790_000_000)
            let course = Course(
                name: "合成课程",
                subject: SubjectRef(displayName: "合成科目"),
                weekday: .monday,
                startTime: TimeOfDay(hour: 9, minute: 0),
                endTime: TimeOfDay(hour: 10, minute: 0)
            )
            let exceptions = [
                ScheduleException(kind: .cancellation, courseID: course.id, date: now, note: "合成停课", createdAt: now),
                ScheduleException(kind: .makeup, courseID: course.id, date: now.addingTimeInterval(86_400), note: "合成补课", createdAt: now)
            ]
            let semester = ScheduleSemester(
                firstWeekStart: now,
                weekCount: 16,
                timeZoneIdentifier: "Asia/Shanghai"
            )
            var settings = AvailabilitySettings.unconfigured
            settings.weekdayStudyWindows = [
                DayTimeRange(weekday: .monday, start: TimeOfDay(hour: 19, minute: 0), end: TimeOfDay(hour: 21, minute: 0))
            ]
            var templates = PeriodTemplate.defaultTemplates
            templates[0].name = "合成第一节"

            let failedCourse = store.saveCourse(course, now: now)
            check(failedCourse.errorMessage != nil && !failedCourse.mayCloseEditor, "课程保存失败返回明确失败结果")
            check(store.snapshot.scheduleCourses.isEmpty, "课程保存失败不发布候选数据")

            let failedExceptions = store.saveScheduleExceptions(exceptions, now: now)
            check(failedExceptions.errorMessage != nil && !failedExceptions.mayCloseEditor, "例外批量保存失败返回明确失败结果")
            check(store.snapshot.scheduleExceptions.isEmpty, "一次调课失败不会留下停课或补课的半完成状态")

            let failedSemester = store.saveSemester(semester, now: now)
            check(failedSemester.errorMessage != nil && !failedSemester.mayCloseEditor, "学期保存失败返回明确失败结果")
            check(store.snapshot.scheduleSemester == nil, "学期保存失败不发布候选数据")

            let failedRoutine = store.saveAvailabilityAndPeriodTemplates(settings: settings, templates: templates, now: now)
            check(failedRoutine.errorMessage != nil && !failedRoutine.mayCloseEditor, "作息与节次模板作为一个事务失败")
            check(store.snapshot.availabilitySettings == .unconfigured, "作息保存失败不发布学习窗口")
            check(store.snapshot.schedulePeriodTemplates == originalTemplates, "作息保存失败不发布节次模板")

            try FileManager.default.removeItem(at: location.storeURL)

            let savedCourse = store.saveCourse(course, now: now)
            check(savedCourse == .saved, "修复存储后重试课程保存成功")
            check(store.saveCourse(course, now: now) == .unchanged, "原样再次保存课程返回没有变化")
            checkEqual(store.snapshot.scheduleCourses.count, 1, "重试没有生成重复课程")

            let savedExceptions = store.saveScheduleExceptions(exceptions, now: now)
            check(savedExceptions == .saved, "修复存储后一次提交全部调课例外")
            checkEqual(store.snapshot.scheduleExceptions.count, 2, "一次调课完整保存两条例外")
            check(store.saveScheduleExceptions(exceptions, now: now) == .unchanged, "相同调课重试识别为没有变化")
            checkEqual(store.snapshot.scheduleExceptions.count, 2, "调课重试没有生成重复例外")

            // 删除失败时 Store 保留现有快照，页面结果映射会显示错误；修复存储后可重试。
            try Data("{\"schemaVersion\":999}".utf8).write(to: location.storeURL, options: .atomic)
            let failedCourseDelete = store.deleteCourse(id: course.id, now: now)
            check(failedCourseDelete.errorMessage != nil && !failedCourseDelete.mayCloseEditor, "课程删除失败返回错误结果")
            checkEqual(
                TimetableView.deletionErrorMessage(for: failedCourseDelete),
                failedCourseDelete.errorMessage,
                "课程删除失败结果映射为页面可见错误"
            )
            checkEqual(store.snapshot.scheduleCourses.map(\.id), [course.id], "课程删除失败后课程仍留在 Store")
            checkEqual(
                store.snapshot.scheduleExceptions.map(\.id).sorted { $0.uuidString < $1.uuidString },
                exceptions.map(\.id).sorted { $0.uuidString < $1.uuidString },
                "课程删除失败后关联例外仍留在 Store"
            )

            let failedExceptionDelete = store.deleteScheduleException(id: exceptions[0].id, now: now)
            check(failedExceptionDelete.errorMessage != nil && !failedExceptionDelete.mayCloseEditor, "例外删除失败返回错误结果")
            checkEqual(
                TimetableView.deletionErrorMessage(for: failedExceptionDelete),
                failedExceptionDelete.errorMessage,
                "例外删除失败结果映射为页面可见错误"
            )
            checkEqual(store.snapshot.scheduleExceptions.count, 2, "例外删除失败后例外仍留在 Store")
            checkEqual(TimetableView.deletionErrorMessage(for: .saved), nil, "后续删除成功会清除页面旧错误")
            checkEqual(TimetableView.deletionErrorMessage(for: .unchanged), nil, "删除未变化时清除旧错误且不声称成功")

            try FileManager.default.removeItem(at: location.storeURL)
            let retriedExceptionDelete = store.deleteScheduleException(id: exceptions[0].id, now: now)
            checkEqual(retriedExceptionDelete, .saved, "恢复存储后重试删除例外成功")
            checkEqual(store.snapshot.scheduleExceptions.map(\.id), [exceptions[1].id], "例外重试只删除目标例外")
            let retriedCourseDelete = store.deleteCourse(id: course.id, now: now)
            checkEqual(retriedCourseDelete, .saved, "恢复存储后重试删除课程成功")
            check(store.snapshot.scheduleCourses.isEmpty, "课程重试成功后课程从 Store 更新")
            check(store.snapshot.scheduleExceptions.isEmpty, "课程重试成功后关联例外随课程清理")

            check(store.saveSemester(semester, now: now) == .saved, "修复存储后学期保存成功")
            check(store.saveSemester(semester, now: now) == .unchanged, "原样再次保存学期返回没有变化")
            check(store.saveAvailabilityAndPeriodTemplates(settings: settings, templates: templates, now: now) == .saved, "修复存储后作息与节次模板一起保存")
            check(store.saveAvailabilityAndPeriodTemplates(settings: settings, templates: templates, now: now) == .unchanged, "原样再次保存作息与节次模板返回没有变化")
            checkEqual(store.snapshot.availabilitySettings, settings, "重试后作息已提交")
            checkEqual(store.snapshot.schedulePeriodTemplates, templates.sorted { $0.start.minutes < $1.start.minutes }, "重试后节次模板已提交")
            check(StoreChangeResult.failed("合成失败").mayCloseEditor == false, "失败结果会保留编辑面板")
            check(StoreChangeResult.unchanged.mayCloseEditor, "没有变化允许正常关闭编辑面板")

            // 手动任务写入走同一份隔离快照；同一 ID 重试幂等，同名不同 ID 各自保留。
            let manualLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "ManualTaskStoreVerify")
            defer { try? FileManager.default.removeItem(at: manualLocation.directory) }
            let manualStore = AppStore(environment: StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: manualLocation,
                storeLocationOrigin: "manual-task-store-verify"
            ))
            let manualNow = Date(timeIntervalSince1970: 1_790_000_000)
            let manualContext = PlanningContext(now: manualNow, timeZoneIdentifier: "Asia/Shanghai")
            let firstManualTask = ManualStudyTask(
                title: "  自定义复习  ",
                estimatedMinutes: 25,
                createdAt: manualNow
            )
            checkEqual(manualStore.saveManualStudyTask(firstManualTask, now: manualNow), .saved, "新增手动任务经统一存储入口保存")
            checkEqual(manualStore.snapshot.manualStudyTasks.first?.title, "自定义复习", "保存时清理标题首尾空白")
            let justSavedCandidates = PlanCandidateBuilder.candidates(
                from: manualStore.snapshot,
                dayKey: manualContext.todayKey,
                context: manualContext,
                includeCourseWork: false
            )
            check(justSavedCandidates.contains { $0.source.manualTaskID == firstManualTask.id }, "不填到期日的已保存任务立即进入统一候选池")
            checkEqual(manualStore.saveManualStudyTask(firstManualTask, now: manualNow), .unchanged, "重复提交相同手动任务不重复创建")
            let invalidManualTask = ManualStudyTask(title: "   ", estimatedMinutes: 20, createdAt: manualNow)
            let invalidManualResult = manualStore.saveManualStudyTask(invalidManualTask, now: manualNow)
            check(!invalidManualResult.mayCloseEditor, "空白标题保存失败并保留编辑器")
            checkEqual(manualStore.snapshot.manualStudyTasks.count, 1, "无效手动任务不会写入快照")
            let sameNameTask = ManualStudyTask(
                title: "自定义复习",
                dueDate: manualNow.addingTimeInterval(86_400),
                estimatedMinutes: 30,
                createdAt: manualNow.addingTimeInterval(1)
            )
            checkEqual(manualStore.saveManualStudyTask(sameNameTask, now: manualNow), .saved, "同名手动任务可用另一身份独立保存")
            checkEqual(manualStore.snapshot.manualStudyTasks.count, 2, "同名手动任务不会按标题合并")
            let editedManualTask = ManualStudyTask(
                id: firstManualTask.id,
                title: "自定义复习修订",
                dueDate: manualNow.addingTimeInterval(172_800),
                estimatedMinutes: 40,
                createdAt: firstManualTask.createdAt
            )
            checkEqual(manualStore.saveManualStudyTask(editedManualTask, now: manualNow), .saved, "编辑手动任务复用原稳定 ID")
            let persistedManualSnapshot = try SnapshotFileStore(location: manualLocation).load()
            let persistedManual = persistedManualSnapshot?.manualStudyTasks
            checkEqual(persistedManual?.count, 2, "重启读取时手动任务仍持久化")
            checkEqual(persistedManual?.first(where: { $0.id == firstManualTask.id })?.dueDate, editedManualTask.dueDate, "可选到期日随编辑持久化")
            checkEqual(persistedManual?.first(where: { $0.id == firstManualTask.id })?.estimatedMinutes, 40, "预计分钟随编辑持久化")
            if let persistedManualSnapshot, let dueDate = editedManualTask.dueDate {
                let dueContext = PlanningContext(now: dueDate.addingTimeInterval(3_600), timeZoneIdentifier: "Asia/Shanghai")
                let afterRestartCandidates = PlanCandidateBuilder.candidates(
                    from: persistedManualSnapshot,
                    dayKey: dueContext.todayKey,
                    context: dueContext,
                    includeCourseWork: false
                )
                check(afterRestartCandidates.contains { $0.source.manualTaskID == firstManualTask.id }, "重启读回后未完成的有期限任务仍进入到期日候选池")
            } else {
                check(false, "编辑任务后的到期日能从隔离存储读回")
            }
            checkEqual(manualStore.deleteManualStudyTask(id: firstManualTask.id, now: manualNow), .saved, "删除手动任务通过统一存储入口提交")
            checkEqual(manualStore.snapshot.manualStudyTasks.map(\.id), [sameNameTask.id], "删除只移除指定身份的任务")
            checkEqual(manualStore.deleteManualStudyTask(id: firstManualTask.id, now: manualNow), .unchanged, "重复删除不改变任务集合")

            let rewardRecheckLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "ManualTaskRewardRecheckVerify")
            defer { try? FileManager.default.removeItem(at: rewardRecheckLocation.directory) }
            let rewardedTask = ManualStudyTask(title: "待撤销奖励的手动任务", createdAt: manualNow)
            let manualRewardRule = EntertainmentRule(
                name: "手动任务完成奖励",
                condition: .standardItems(1),
                rewardMinutes: 20,
                createdAt: manualNow,
                updatedAt: manualNow
            )
            let manualTaskEvent = CompletionEvent.make(
                dayKey: manualContext.todayKey,
                source: .manual(manualTaskID: rewardedTask.id),
                plannedScope: .tasks(1),
                minimumScope: .tasks(0.5),
                completedScope: .tasks(1),
                actualMinutes: 0,
                completedAt: manualNow,
                createdAt: manualNow
            )
            let manualRewardProgress = RewardConditionProgress(
                ruleID: manualRewardRule.id,
                ruleRevisionID: manualRewardRule.revisionID,
                metric: .standardCompletedItemCount,
                achievedValue: 1,
                requiredValue: 1,
                detail: "标准完成 1 项",
                basisEventIDs: [manualTaskEvent.id],
                isSatisfied: true
            )
            let manualRewardGrant = RewardGrant.make(
                ruleSnapshot: manualRewardRule.snapshotValue,
                dayKey: manualContext.todayKey,
                basisEventIDs: [manualTaskEvent.id],
                conditionProgress: manualRewardProgress,
                grantedMinutes: 20,
                grantedAt: manualNow
            )
            var rewardRecheckSeed = StoreSnapshot()
            rewardRecheckSeed.manualStudyTasks = [rewardedTask]
            rewardRecheckSeed.entertainmentRules = [manualRewardRule]
            rewardRecheckSeed.completionEvents = [manualTaskEvent.revoked(at: manualNow.addingTimeInterval(1), reason: "合成撤销")]
            rewardRecheckSeed.rewardGrants = [manualRewardGrant]
            try SnapshotFileStore(location: rewardRecheckLocation).save(rewardRecheckSeed)
            let rewardRecheckStore = AppStore(environment: StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: rewardRecheckLocation,
                storeLocationOrigin: "manual-task-reward-recheck-verify"
            ))
            checkEqual(rewardRecheckStore.snapshot.rewardGrant(id: manualRewardGrant.id)?.state, .pending, "隔离测试初始奖励为待领取")
            rewardRecheckStore.deleteManualStudyTask(id: rewardedTask.id, now: manualNow)
            checkEqual(rewardRecheckStore.snapshot.rewardGrant(id: manualRewardGrant.id)?.state, .revoked, "删除手动任务时立即重查并撤销已失效的待用奖励")

            // 规则修改通过 AppStore 的实际本地持久化入口同步核验未使用奖励。
            let rewardLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "RewardRecheckVerify")
            defer { try? FileManager.default.removeItem(at: rewardLocation.directory) }
            let rewardNow = Date(timeIntervalSince1970: 1_790_000_000)
            let rewardContext = PlanningContext(now: rewardNow, timeZoneIdentifier: "Asia/Shanghai")
            let rewardDay = rewardContext.todayKey
            let rewardRule = EntertainmentRule(
                name: "合成规则",
                condition: .standardItems(1),
                rewardMinutes: 20,
                createdAt: rewardNow,
                updatedAt: rewardNow
            )
            let rewardEvent = CompletionEvent.make(
                planItemID: UUID(),
                dayKey: rewardDay,
                plannedScope: .tasks(1),
                minimumScope: .tasks(0.5),
                completedScope: .tasks(1),
                actualMinutes: 15,
                completedAt: rewardNow,
                createdAt: rewardNow
            )
            let rewardProgress = RewardConditionProgress(
                ruleID: rewardRule.id,
                ruleRevisionID: rewardRule.revisionID,
                metric: .standardCompletedItemCount,
                achievedValue: 1,
                requiredValue: 1,
                detail: "标准完成 1 项",
                basisEventIDs: [rewardEvent.id],
                isSatisfied: true
            )
            let rewardGrant = RewardGrant.make(
                ruleSnapshot: rewardRule.snapshotValue,
                dayKey: rewardDay,
                basisEventIDs: [rewardEvent.id],
                conditionProgress: rewardProgress,
                grantedMinutes: 20,
                grantedAt: rewardNow
            )
            var rewardSeed = StoreSnapshot()
            rewardSeed.entertainmentRules = [rewardRule]
            rewardSeed.completionEvents = [rewardEvent]
            rewardSeed.rewardGrants = [rewardGrant]
            try SnapshotFileStore(location: rewardLocation).save(rewardSeed)
            let rewardEnvironment = StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: rewardLocation,
                storeLocationOrigin: "reward-recheck-verify"
            )
            let rewardStore = AppStore(environment: rewardEnvironment)
            rewardStore.setEntertainmentRuleEnabled(id: rewardRule.id, isEnabled: false, now: rewardNow)
            checkEqual(rewardStore.snapshot.rewardGrant(id: rewardGrant.id)?.state, .revoked, "停用规则后 AppStore 当次提交立即撤销未使用奖励")
            checkEqual(
                rewardStore.snapshot.rewardGrant(id: rewardGrant.id)?.revocation?.reason,
                "发放依据的规则版本已失效，未使用奖励已取消。",
                "AppStore 持久化具体撤销原因"
            )
            rewardStore.setEntertainmentRuleEnabled(id: rewardRule.id, isEnabled: true, now: rewardNow)
            rewardStore.saveEntertainmentRule(
                name: "合成规则编辑版",
                condition: rewardRule.condition,
                fallback: rewardRule.fallback,
                rewardMinutes: rewardRule.rewardMinutes,
                ruleID: rewardRule.id,
                now: rewardNow.addingTimeInterval(60)
            )
            checkEqual(rewardStore.snapshot.rewardGrants.count, 1, "恢复并编辑规则不会在同一天重复发奖")
            let reloadedRewardSnapshot = try SnapshotFileStore(location: rewardLocation).load()
            checkEqual(reloadedRewardSnapshot?.rewardGrants.first?.state, .revoked, "撤销状态经 AppStore 写盘后可回读")

            // 删除规则也必须在当天同一份 AppStore 状态中撤销未使用奖励。
            let deletionLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "RewardRuleDeleteVerify")
            defer { try? FileManager.default.removeItem(at: deletionLocation.directory) }
            try SnapshotFileStore(location: deletionLocation).save(rewardSeed)
            let deletionStore = AppStore(environment: StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: deletionLocation,
                storeLocationOrigin: "reward-rule-delete-verify"
            ))
            deletionStore.deleteEntertainmentRule(id: rewardRule.id, now: rewardNow)
            checkEqual(deletionStore.snapshot.rewardGrant(id: rewardGrant.id)?.state, .revoked, "删除规则后 AppStore 当次提交立即撤销未使用奖励")
            let reloadedDeletionSnapshot = try SnapshotFileStore(location: deletionLocation).load()
            checkEqual(
                reloadedDeletionSnapshot?.rewardGrants.first?.revocation?.reason,
                "发放依据的规则版本已失效，未使用奖励已取消。",
                "删除规则后的撤销原因持久化"
            )
        } catch {
            check(false, "隔离存储测试准备失败：\(error)")
        }

        print("Schedule store verification complete. passed=\(passed) failed=\(failed)")
        if failed > 0 { exit(1) }
    }

    static func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        check(actual == expected, "\(message)（实际 \(actual)，期望 \(expected)）")
    }
}
