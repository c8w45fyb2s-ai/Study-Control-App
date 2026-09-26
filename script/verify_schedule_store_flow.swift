import Foundation

private actor RequestCountingTransport: AIHTTPTransporting {
    private var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(), response)
    }

    func count() -> Int { requestCount }
}

@MainActor
private final class MockAIKeychainStore: AIKeychainStoring {
    private var credentials: [String: AIKeychainCredentialState] = [:]
    private(set) var failNextSave = false
    private(set) var failNextRestore = false
    private(set) var credentialReadCount = 0
    private(set) var credentialSaveCount = 0
    private(set) var credentialRestoreCount = 0

    func loadAPIKey(for configuration: AIConnectionConfiguration, allowLegacyFallback: Bool) -> String {
        credentials[configuration.credentialScope]?.apiKey ?? ""
    }

    func credentialState(for configuration: AIConnectionConfiguration) throws -> AIKeychainCredentialState {
        credentialReadCount += 1
        return credentials[configuration.credentialScope] ?? AIKeychainCredentialState(apiKey: nil, migrationMarker: nil)
    }

    func saveAPIKey(_ value: String, for configuration: AIConnectionConfiguration) throws {
        credentialSaveCount += 1
        if failNextSave {
            failNextSave = false
            credentials[configuration.credentialScope] = AIKeychainCredentialState(
                apiKey: value.isEmpty ? nil : value,
                migrationMarker: "migrated"
            )
            throw MockError.injected("mock credential save failure")
        }
        credentials[configuration.credentialScope] = AIKeychainCredentialState(
            apiKey: value.isEmpty ? nil : value,
            migrationMarker: "migrated"
        )
    }

    func restoreCredentialState(_ state: AIKeychainCredentialState, for configuration: AIConnectionConfiguration) throws {
        credentialRestoreCount += 1
        if failNextRestore {
            failNextRestore = false
            throw MockError.injected("mock credential restore failure")
        }
        credentials[configuration.credentialScope] = state
    }

    func hasScopedCredential(for configuration: AIConnectionConfiguration) -> Bool {
        credentials[configuration.credentialScope]?.apiKey != nil
    }

    func setFailNextSave() { failNextSave = true }
    func setFailNextRestore() { failNextRestore = true }
    func hasCredential(for configuration: AIConnectionConfiguration) -> Bool {
        credentials[configuration.credentialScope]?.apiKey != nil
    }

    private enum MockError: LocalizedError {
        case injected(String)
        var errorDescription: String? {
            if case .injected(let message) = self { return message }
            return nil
        }
    }
}

private actor RequestObservingTransport: AIHTTPTransporting {
    private var captured: [URLRequest] = []
    private let responseBody: String

    init(responseBody: String = #"{"choices":[{"finish_reason":"stop","message":{"content":"OK"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#) {
        self.responseBody = responseBody
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(responseBody.utf8), response)
    }

    func lastRequest() -> URLRequest? { captured.last }
    func count() -> Int { captured.count }
}

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
    static func main() async {
        await verifyModelRequestPrivacyGate()
        await verifyOfflineSettingsCanBeSaved()
        await verifySettingsCredentialTransactions()
        await verifyModelRefusalStopsAnalysis()
        await verifyMemoryRefusalStopsChat()

        // 默认初始化也必须在测试隔离模式中运行；Makefile 为该进程设置独立目录与 TEST_MODE。
        if StudyRuntimeEnvironment.resolve().isTestMode {
            let defaultStore = AppStore(keychainStore: MockAIKeychainStore())
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
            let store = AppStore(environment: environment, keychainStore: MockAIKeychainStore())
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
            ), keychainStore: MockAIKeychainStore())
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
            ), keychainStore: MockAIKeychainStore())
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
            let rewardStore = AppStore(environment: rewardEnvironment, keychainStore: MockAIKeychainStore())
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
            ), keychainStore: MockAIKeychainStore())
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

    @MainActor
    private static func verifyModelRequestPrivacyGate() async {
        let location = SnapshotStoreLocation.isolatedTemporary(prefix: "AIRequestPrivacyVerify")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        do {
            var seed = StoreSnapshot()
            seed.settings.allowModelRequests = false
            seed.settings.baseURL = "https://mock.example/v1"
            seed.settings.model = "mock-model"
            try SnapshotFileStore(location: location).save(seed)

            let transport = RequestCountingTransport()
            let environment = StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: location,
                storeLocationOrigin: "ai-request-privacy-verify"
            )
            let store = AppStore(environment: environment, underlyingAITransport: transport, keychainStore: MockAIKeychainStore())
            store.apiKey = "mock-key"
            store.chatQuestion = "请解释光合作用的基本过程。"
            store.askQuestion()

            for _ in 0..<100 {
                if !store.hasActiveAIRequest { break }
                try await Task.sleep(for: .milliseconds(20))
            }

            checkEqual(await transport.count(), 0, "关闭模型请求时答疑不会发起网络调用")
            checkEqual(store.statusMessage, "已关闭 AI 请求：请在隐私设置中开启后再提问", "隐私开关向用户说明请求已拦截")
        } catch {
            check(false, "AI 请求隐私开关验证准备失败：\(error)")
        }
    }

    @MainActor
    private static func verifyOfflineSettingsCanBeSaved() async {
        let location = SnapshotStoreLocation.isolatedTemporary(prefix: "OfflineSettingsSaveVerify")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let keychain = MockAIKeychainStore()
        let transport = RequestCountingTransport()
        let store = AppStore(
            environment: StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: location,
                storeLocationOrigin: "offline-settings-save-verify"
            ),
            underlyingAITransport: transport,
            keychainStore: keychain
        )
        let baseURL = store.settings.baseURL
        check(saveTestSettings(store, baseURL: baseURL, model: "", apiKey: "", allowModelRequests: false, includePersonalContext: false), "没有模型和密钥也能保存关闭 AI、提醒和个人资料引用")
        check(!store.settings.allowModelRequests && !store.settings.remindersEnabled && !store.settings.includePersonalContextInAnswers, "离线设置当次保存后生效")
        check(!store.isAIConnectionReady, "保存离线设置不会把未配置的 AI 连接标为就绪")
        checkEqual(keychain.credentialReadCount, 0, "只改本地偏好无需读取 Keychain 凭据事务")
        checkEqual(keychain.credentialSaveCount, 0, "只改本地偏好无需写入 Keychain")
        do {
            let reloaded = try SnapshotFileStore(location: location).load()
            check(reloaded?.settings.allowModelRequests == false && reloaded?.settings.remindersEnabled == false && reloaded?.settings.includePersonalContextInAnswers == false, "离线设置写盘后可完整回读")
        } catch {
            check(false, "离线设置回读失败：\(error)")
        }

        check(saveTestSettings(store, baseURL: baseURL, model: "test-model", apiKey: "", allowModelRequests: true), "即使 AI 开关打开，也允许保存未填密钥的配置")
        do {
            _ = try store.makeClient()
            check(false, "缺少密钥时不能创建请求客户端")
        } catch AIError.missingAPIKey {
            check(true, "实际请求仍校验必需的密钥")
        } catch {
            check(false, "缺少密钥时返回了意外错误：\(error)")
        }
        store.chatQuestion = "解释光合作用。"
        store.askQuestion()
        for _ in 0..<100 {
            if !store.hasActiveAIRequest { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        checkEqual(await transport.count(), 0, "保存和使用不完整连接都不会发出网络请求")
        check(saveTestSettings(store, baseURL: "", model: "", apiKey: "", allowModelRequests: false), "完全未配置 AI 的离线状态可以保存")
        check(!store.settings.allowModelRequests && !store.isAIConnectionReady, "空连接保存后保持 AI 关闭且未就绪")
    }

    @MainActor
    private static func verifySettingsCredentialTransactions() async {
        let location = SnapshotStoreLocation.isolatedTemporary(prefix: "AISettingsCredentialTransactionVerify")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        do {
            let environment = StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: location,
                storeLocationOrigin: "ai-settings-credential-transaction-verify"
            )
            let keychain = MockAIKeychainStore()
            let transport = RequestObservingTransport()
            let store = AppStore(environment: environment, underlyingAITransport: transport, keychainStore: keychain)

            check(saveTestSettings(store, baseURL: "https://old.example/proxy/v1", model: "old-model", apiKey: "old-key"), "初始连接设置和凭据原子保存")
            await checkCurrentRequest(store, transport, baseURL: "https://old.example/proxy/v1/chat/completions", apiKey: "Bearer old-key", message: "已保存连接请求使用旧地址和旧密钥")

            keychain.setFailNextSave()
            check(!saveTestSettings(store, baseURL: "https://switched.example/v1", model: "switched-model", apiKey: "switched-key"), "Keychain 写入失败会拒绝服务切换")
            checkEqual(keychain.credentialRestoreCount, 1, "凭据写入失败只由设置事务回滚一次")
            checkEqual(store.snapshot.settings.baseURL, "https://old.example/proxy/v1", "Keychain 失败后设置地址仍是旧值")
            checkEqual(store.snapshot.settings.model, "old-model", "Keychain 失败后模型仍是旧值")
            checkEqual(store.apiKey, "old-key", "Keychain 失败后运行密钥仍是旧值")
            checkEqual(store.settingsDraftAPIKey, "old-key", "Keychain 失败后草稿密钥仍是旧值")
            let persistedAfterKeychainFailure = try SnapshotFileStore(location: location).load()
            checkEqual(persistedAfterKeychainFailure?.settings.baseURL, "https://old.example/proxy/v1", "Keychain 失败没有隐式写入候选地址")
            check(
                !(persistedAfterKeychainFailure?.diagnosticEvents.contains { $0.message.contains("保存 AI 服务密钥失败") } ?? false),
                "Keychain 失败诊断没有触发额外隐式保存"
            )
            await checkCurrentRequest(store, transport, baseURL: "https://old.example/proxy/v1/chat/completions", apiKey: "Bearer old-key", message: "服务切换的 Keychain 失败后请求仍使用旧连接")

            try Data("{\"schemaVersion\":999}".utf8).write(to: location.storeURL, options: .atomic)
            check(!saveTestSettings(store, baseURL: "https://old.example/proxy/v1", model: "same-scope-new-model", apiKey: "replacement-key"), "设置写盘失败会拒绝发布候选配置")
            let oldConfiguration = AIConnectionConfiguration(settings: store.snapshot.settings)
            checkEqual(keychain.loadAPIKey(for: oldConfiguration, allowLegacyFallback: false), "old-key", "同一连接写盘失败后 Keychain 原密钥已恢复")
            checkEqual(store.snapshot.settings.model, "old-model", "同一连接写盘失败后内存配置仍旧")
            checkEqual(store.apiKey, "old-key", "同一连接写盘失败后运行密钥仍旧")
            checkEqual(store.settingsDraftAPIKey, "old-key", "同一连接写盘失败后草稿密钥仍旧")
            await checkCurrentRequest(store, transport, baseURL: "https://old.example/proxy/v1/chat/completions", apiKey: "Bearer old-key", message: "同一连接写盘失败后请求地址和密钥保持匹配")

            let switchedConfiguration = AIConnectionConfiguration(
                baseURL: "https://disk-failed-switch.example/v1",
                model: "disk-failed-model",
                protocolKind: .openAIChatCompletions,
                authMode: .providerKey,
                chatTokenParameter: .maxTokens,
                anthropicOutputTokenLimit: 128,
                temperature: nil,
                useNativeJSONMode: false
            )
            check(!saveTestSettings(store, baseURL: switchedConfiguration.baseURL, model: switchedConfiguration.model, apiKey: "disk-failed-key"), "切換服務時快照寫盤失敗會回滚候选连接密钥")
            check(!keychain.hasCredential(for: switchedConfiguration), "切換服務寫盤失敗後新地址沒有留下候選密鑰")
            checkEqual(store.snapshot.settings.baseURL, "https://old.example/proxy/v1", "切換服务写盘失败后仍绑定旧地址")
            checkEqual(store.apiKey, "old-key", "切换服务写盘失败后仍绑定旧密钥")
            await checkCurrentRequest(store, transport, baseURL: "https://old.example/proxy/v1/chat/completions", apiKey: "Bearer old-key", message: "切换服务写盘失败后后续请求仍使用旧地址和旧密钥")

            keychain.setFailNextRestore()
            check(!saveTestSettings(store, baseURL: "https://old.example/proxy/v1", model: "restore-failed-model", apiKey: "restore-failed-key"), "Keychain 恢复失败时设置仍不会发布")
            check(store.statusMessage.contains("恢复失败"), "Keychain 恢复失败会向用户明确报告")
            checkEqual(store.snapshot.settings.baseURL, "https://old.example/proxy/v1", "密钥恢复失败时运行地址仍是旧值")
            checkEqual(store.apiKey, "old-key", "密钥恢复失败时本次进程仍用旧密钥")
            await checkCurrentRequest(store, transport, baseURL: "https://old.example/proxy/v1/chat/completions", apiKey: "Bearer old-key", message: "密钥恢复失败后本次进程请求仍使用旧连接")
        } catch {
            check(false, "AI 设置凭据事务测试准备失败：\(error)")
        }
    }

    @MainActor
    private static func verifyModelRefusalStopsAnalysis() async {
        let location = SnapshotStoreLocation.isolatedTemporary(prefix: "AIRefusalAnalysisVerify")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let transport = RequestObservingTransport(responseBody: #"{"choices":[{"finish_reason":"stop","message":{"refusal":"我不能分析这份内容。","content":null}}],"usage":{"prompt_tokens":12,"completion_tokens":5}}"#)
        let environment = StudyRuntimeEnvironment(
            isTestMode: true,
            allowsSystemNotifications: false,
            storeLocation: location,
            storeLocationOrigin: "ai-refusal-analysis-verify"
        )
        let store = AppStore(environment: environment, underlyingAITransport: transport, keychainStore: MockAIKeychainStore())
        check(saveTestSettings(store, baseURL: "https://refusal.example/v1", model: "refusal-model", apiKey: "mock-key"), "拒绝响应测试连接保存成功")

        let document = StudyDocument(title: "拒绝测试资料", sourceName: "mock.txt", kind: .note, content: "待分析内容")
        store.analyzeDocument(document)
        for _ in 0..<100 {
            if !store.hasActiveAIRequest { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let requestCount = await transport.count()
        checkEqual(requestCount, 1, "资料分析收到首个拒绝响应后只发送一次请求")
        check(store.snapshot.drafts.isEmpty, "模型拒绝后没有生成资料分析草稿")
        check(store.snapshot.aiPlanDrafts.isEmpty, "模型拒绝后没有生成规划草稿")
        checkEqual(store.snapshot.usageStats.requestCount, 1, "拒绝响应 usage 仍计为一次模型请求")
        checkEqual(store.snapshot.usageStats.inputTokens, 12, "拒绝响应输入 token 被计入用量")
        checkEqual(store.snapshot.usageStats.outputTokens, 5, "拒绝响应输出 token 被计入用量")
        check(store.statusMessage.contains("我不能分析这份内容。"), "拒绝说明直接显示在用户状态中")

        let chatLocation = SnapshotStoreLocation.isolatedTemporary(prefix: "AIRefusalChatVerify")
        defer { try? FileManager.default.removeItem(at: chatLocation.directory) }
        let chatTransport = RequestObservingTransport(responseBody: #"{"choices":[{"finish_reason":"stop","message":{"refusal":"我不能帮助制定这类计划。","content":null}}],"usage":{"prompt_tokens":8,"completion_tokens":3}}"#)
        let chatStore = AppStore(
            environment: StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: chatLocation,
                storeLocationOrigin: "ai-refusal-chat-verify"
            ),
            underlyingAITransport: chatTransport,
            keychainStore: MockAIKeychainStore()
        )
        check(saveTestSettings(chatStore, baseURL: "https://refusal.example/v1", model: "refusal-model", apiKey: "mock-key"), "答疑拒绝测试连接保存成功")
        chatStore.chatQuestion = "请帮我制定一个学习计划。"
        chatStore.askQuestion()
        for _ in 0..<100 {
            if !chatStore.hasActiveAIRequest { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let chatRequestCount = await chatTransport.count()
        checkEqual(chatRequestCount, 1, "答疑收到拒绝后不会再生成规划草稿")
        checkEqual(chatStore.chatAnswer, "我不能帮助制定这类计划。", "答疑直接展示模型拒绝说明")
        check(chatStore.snapshot.aiPlanDrafts.isEmpty, "答疑拒绝不会创建 AI 计划草稿")
        checkEqual(chatStore.snapshot.usageStats.requestCount, 1, "答疑拒绝的 usage 被记录")
    }

    @MainActor
    private static func verifyMemoryRefusalStopsChat() async {
        let location = SnapshotStoreLocation.isolatedTemporary(prefix: "AIMemoryRefusalVerify")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        var seed = StoreSnapshot()
        seed.chatMessages = (0..<20).map { index in
            ChatHistoryMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: String(repeating: "以前讨论过数学复习与练习方法。", count: 80)
            )
        }
        do {
            try SnapshotFileStore(location: location).save(seed)
        } catch {
            check(false, "长期记忆拒绝测试准备失败：\(error)")
            return
        }

        let transport = RequestObservingTransport(responseBody: #"{"choices":[{"finish_reason":"stop","message":{"refusal":"我不能压缩这段对话。","content":null}}],"usage":{"prompt_tokens":6,"completion_tokens":4}}"#)
        let store = AppStore(
            environment: StudyRuntimeEnvironment(
                isTestMode: true,
                allowsSystemNotifications: false,
                storeLocation: location,
                storeLocationOrigin: "ai-memory-refusal-verify"
            ),
            underlyingAITransport: transport,
            keychainStore: MockAIKeychainStore()
        )
        check(saveTestSettings(store, baseURL: "https://refusal.example/v1", model: "refusal-model", apiKey: "mock-key"), "长期记忆拒绝测试连接保存成功")
        store.chatQuestion = "如何开始复习比较好？"
        store.askQuestion()
        for _ in 0..<100 {
            if !store.hasActiveAIRequest { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let requestCount = await transport.count()
        checkEqual(requestCount, 1, "长期记忆压缩拒绝后不会继续发送答疑请求")
        checkEqual(store.snapshot.chatContextSummaryMessageCount, 0, "长期记忆拒绝不会提交压缩摘要")
        checkEqual(store.chatAnswer, "我不能压缩这段对话。", "长期记忆拒绝说明直接展示给用户")
        checkEqual(store.snapshot.usageStats.inputTokens, 6, "长期记忆拒绝的输入 token 计入用量")
        checkEqual(store.snapshot.usageStats.outputTokens, 4, "长期记忆拒绝的输出 token 计入用量")
    }

    @MainActor
    private static func saveTestSettings(_ store: AppStore, baseURL: String, model: String, apiKey: String, allowModelRequests: Bool = true, includePersonalContext: Bool? = nil) -> Bool {
        let current = store.settings
        return store.updateSettings(
            baseURL: baseURL,
            model: model,
            servicePreset: .custom,
            protocolKind: .openAIChatCompletions,
            authMode: .providerKey,
            chatTokenParameter: current.chatTokenParameter,
            anthropicOutputTokenLimit: current.anthropicOutputTokenLimit,
            temperature: nil,
            useNativeJSONMode: false,
            remindersEnabled: false,
            defaultReminderHour: current.defaultReminderHour,
            apiKey: apiKey,
            allowModelRequests: allowModelRequests,
            allowStructuredPlanRequests: current.allowStructuredPlanRequests,
            includePersonalContextInAnswers: includePersonalContext ?? current.includePersonalContextInAnswers,
            keepDocumentContent: current.keepDocumentContent,
            answerMode: current.answerMode,
            maxAnalysisChunkCharacters: current.maxAnalysisChunkCharacters,
            inputTokenCostPerMillion: current.inputTokenCostPerMillion,
            outputTokenCostPerMillion: current.outputTokenCostPerMillion
        )
    }

    @MainActor
    private static func checkCurrentRequest(
        _ store: AppStore,
        _ transport: RequestObservingTransport,
        baseURL: String,
        apiKey: String,
        message: String
    ) async {
        do {
            try await store.makeClient().testConnection()
            let request = await transport.lastRequest()
            check(request?.url?.absoluteString == baseURL && request?.value(forHTTPHeaderField: "Authorization") == apiKey, message)
        } catch {
            check(false, "\(message)：mock 请求失败：\(error.localizedDescription)")
        }
    }

    static func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        check(actual == expected, "\(message)（实际 \(actual)，期望 \(expected)）")
    }
}
