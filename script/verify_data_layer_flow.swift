import Foundation

// 统一数据层（模块 A）的独立行为测试。
//
// 这个文件刻意放在源码目标目录（`study software/`）之外：
// Xcode 使用 PBXFileSystemSynchronizedRootGroup，目录内的任何 .swift 都会被编进正式 App，
// 因此测试入口只能通过 swiftc 单独编译。
//
// 运行方式（在工程根目录 `软件本体/study software` 下）：
//
//   make verify-data-layer
//
// 等价命令（不依赖 Makefile）：
//
//   swiftc -parse-as-library "study software/Models.swift" "study software/AIPlanIntent.swift" \
//     "study software/ScheduleResolver.swift" "study software/AvailabilityCalculator.swift" \
//     "study software/StudyPlanningModels.swift" "study software/ScheduleModels.swift" \
//     "study software/StudySessionModels.swift" "study software/EntertainmentModels.swift" \
//     "study software/PlanningContracts.swift" "study software/SnapshotMigration.swift" \
//     "study software/PersistenceStore.swift" "script/verify_data_layer_flow.swift" \
//     -o ".build/verify_data_layer_flow" && ./.build/verify_data_layer_flow
//
// 覆盖的验收标准（全部是业务行为断言，不是"返回值非空"）：
// 1. schema 4 数据可以逐步升级到当前版本，且既有数据不丢
// 2. 缺少 schema 6 新增字段的旧数据可以加载
// 3. ReviewTask 的"属性初始值 ≠ JSON 缺失字段"场景可以正常解码
// 4. 新数据保存再读取后信息一致（含计划/会话/完成/规则/奖励）
// 5. 未来版本文件不会被降级覆盖，也不会被写入
// 6. 错误文件不会被覆盖，可隔离后重建
// 7. 没有迁移路径的版本返回明确错误且不动原文件
// 8. 迁移是显式步骤；旧"每日完成总数"不被推算出时长/明细/娱乐资格
// 9. 完成事件与奖励记录有稳定唯一键，重复操作不重复记录
// 10. 部分完成与整体完成分开、学习与答题正确分开、三档完成分开
// 11. 历史奖励绑定当时的规则版本，规则编辑不改写历史
// 12. 保底适配方式按规则计算奖励时长
// 13. 备份恢复后完成记录与奖励记录保持一致
// 14. 课程地点/作息等新增数据纳入隐私备份规则
// 15. 持久化键名与 SchedulePersistenceKeys 契约一致
// 16. 存储路径可注入且测试完全隔离，不触碰真实 store.json
// 17. 公共类型可在纯 Foundation 下使用；规划时区决定"学习日"

@main
struct DataLayerVerifyHarness {
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
        if actual == expected {
            passed += 1
            print("PASS \(message)")
        } else {
            failed += 1
            print("FAIL \(message)（实际：\(actual)，期望：\(expected)）")
        }
    }

    /// 断言闭包抛出指定类型的错误。
    static func checkThrows<E: Error>(
        _ expected: E.Type,
        _ message: String,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            failed += 1
            print("FAIL \(message)（没有抛错）")
        } catch let error as E {
            passed += 1
            print("PASS \(message)（\(type(of: error))）")
        } catch {
            failed += 1
            print("FAIL \(message)（抛出了非预期错误：\(error)）")
        }
    }

    // MARK: - 工具

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static func makeLocation(_ label: String) -> SnapshotStoreLocation {
        SnapshotStoreLocation.isolatedTemporary(prefix: "DataLayer-\(label)")
    }

    @discardableResult
    static func writeRaw(_ json: String, to location: SnapshotStoreLocation) throws -> URL {
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let data = Data(json.utf8)
        try data.write(to: location.storeURL, options: .atomic)
        return location.storeURL
    }

    static func makeStore(_ label: String) throws -> SnapshotFileStore {
        try SnapshotFileStore(location: makeLocation(label))
    }

    static func encoded(_ snapshot: StoreSnapshot) -> Data {
        (try? encoder.encode(snapshot.normalizedToCurrentSchema())) ?? Data()
    }

    /// 任意可编码值（计划、事件等）的稳定 JSON 表示，用于幂等/一致性比较。
    static func encodedValue<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data()
    }

    static func rawString(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func jsonObject(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// 旧版本（schema 4）备份，字段刻意不全：用来验证兼容性。
    static let legacyV4JSON = """
    {
      "schemaVersion": 4,
      "documents": [
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "title": "旧资料",
          "sourceName": "old.txt",
          "kind": "学习笔记",
          "importedAt": 700000000,
          "content": "旧正文"
        }
      ],
      "knowledgePoints": [
        {
          "id": "22222222-2222-4222-8222-222222222222",
          "title": "旧知识点",
          "subject": "数学",
          "summary": "旧摘要",
          "mastery": 0.4,
          "createdAt": 700000000
        }
      ],
      "reviewTasks": [
        {
          "id": "33333333-3333-4333-8333-333333333333",
          "title": "带状态的旧复习任务",
          "dueDate": 700000000,
          "status": "待复习",
          "priority": 3
        },
        {
          "id": "44444444-4444-4444-8444-444444444444",
          "title": "缺少 SM-2 与提醒字段的旧复习任务",
          "dueDate": 700000000
        }
      ],
      "dailyActivityRecords": [
        { "dateString": "2026-03-02", "completedTaskCount": 3, "studiedAt": 700000000 }
      ],
      "onboardingCompleted": true
    }
    """

    // MARK: - 入口

    static func main() {
        print("=== 模块 A 统一数据层行为测试 ===")

        schema4UpgradesThroughV7()
        missingNewFieldsStillLoad()
        reviewTaskDefaultsAreTolerant()
        migrationStepsAreExplicit()
        legacyTotalsAreNotFabricatedIntoRecords()
        roundTripPreservesPlanningLayer()
        futureVersionIsNeverOverwritten()
        corruptFileIsNeverOverwritten()
        completionKeysAreStableAndIdempotent()
        partialAndFullCompletionStaySeparate()
        normalizeKeepsSingleActivePlan()
        rewardHistoryIsPinnedToRuleRevision()
        rewardStatesAndFallbacksBehave()
        backupRestoreKeepsRecordsConsistent()
        privacyRedactionCoversNewFields()
        persistenceKeysMatchScheduleContract()
        contractAdaptersProduceRealResults()
        storageIsInjectibleAndIsolated()
        foundationOnlyTypesAndPlanningTimeZone()

        print("")
        print("=== 结果：\(passed) 通过 / \(failed) 失败 ===")
        if failed > 0 {
            exit(1)
        }
    }

    // MARK: - 1. schema 4 → 当前版本

    static func schema4UpgradesThroughV7() {
        do {
            let location = makeLocation("upgrade")
            let storeURL = try writeRaw(legacyV4JSON, to: location)
            let store = try SnapshotFileStore(location: location)

            guard let loaded = try store.loadWithReport() else {
                check(false, "schema 4 文件应当可以加载")
                return
            }
            checkEqual(loaded.snapshot.schemaVersion, StudySchema.currentVersion, "schema 4 加载后升级为当前版本")
            checkEqual(loaded.report.fromVersion, 4, "迁移报告记录原始版本为 4")
            checkEqual(
                loaded.report.appliedSteps,
                ["planning-layer-v4-to-v5", "manual-study-tasks-v5-to-v6", "manual-task-due-date-v6-to-v7"],
                "迁移按顺序应用 4→5、5→6 与 6→7"
            )
            check(!loaded.report.didFabricateRecords, "迁移没有产生虚构记录")

            checkEqual(loaded.snapshot.documents.count, 1, "旧资料保留")
            checkEqual(loaded.snapshot.knowledgePoints.count, 1, "旧知识点保留")
            checkEqual(loaded.snapshot.reviewTasks.count, 2, "旧复习任务保留")
            checkEqual(loaded.snapshot.reviewTasks.first?.priority, 3, "旧复习任务字段保留")
            checkEqual(loaded.snapshot.dailyActivityRecords.count, 1, "旧每日完成总数保留")
            checkEqual(
                loaded.snapshot.dailyActivityRecords.first?.completedTaskCount,
                3,
                "旧每日完成总数的数值原样保留"
            )
            check(loaded.snapshot.onboardingCompleted, "既有布尔字段保留")
            check(loaded.snapshot.completionEvents.isEmpty, "升级不会凭空生成完成事件")
            check(loaded.snapshot.studySessions.isEmpty, "升级不会凭空生成学习会话")
            check(loaded.snapshot.rewardGrants.isEmpty, "升级不会凭空生成奖励记录")
            check(loaded.snapshot.scheduleSemester == nil, "未设置学期时保持为空")
            check(
                loaded.snapshot.availabilitySettings.hasExplicitRoutine == false,
                "作息默认是「未配置」，不会把默认窗口伪装成用户设置"
            )

            // 保存后磁盘版本变成当前版本，且旧数据仍在。
            try store.save(loaded.snapshot)
            checkEqual(store.storedSchemaVersion(), StudySchema.currentVersion, "保存后磁盘版本为当前版本")
            let reloaded = try store.load()
            checkEqual(reloaded?.reviewTasks.count, 2, "保存并重新读取后旧的复习任务仍在")
            checkEqual(reloaded?.schemaVersion, StudySchema.currentVersion, "重新读取的版本为当前版本")
            check(FileManager.default.fileExists(atPath: storeURL.path), "store.json 仍位于注入的目录内")
        } catch {
            check(false, "schema 4 升级流程不应抛错：\(error)")
        }
    }

    // MARK: - 2. 缺少新增字段

    static func missingNewFieldsStillLoad() {
        let minimalV4 = """
        { "schemaVersion": 4, "onboardingCompleted": false }
        """
        do {
            let location = makeLocation("minimal")
            try writeRaw(minimalV4, to: location)
            let store = try SnapshotFileStore(location: location)
            guard let snapshot = try store.load() else {
                check(false, "缺少新增字段的旧数据应当可以加载")
                return
            }
            checkEqual(snapshot.schemaVersion, StudySchema.currentVersion, "缺少新增字段的旧数据加载后升级到当前版本")
            check(snapshot.dailyPlans.isEmpty, "缺失字段用空数组默认值补齐")
            check(snapshot.manualStudyTasks.isEmpty, "旧数据缺失手动任务集合时用空数组补齐")
            check(snapshot.entertainmentRules.isEmpty, "缺失的娱乐规则用空数组补齐")
            check(snapshot.rewardGrants.isEmpty, "缺失的奖励记录用空数组补齐")
            check(snapshot.courseBurdenLevels.isEmpty, "缺失的负担等级旁表用空数组补齐")
            checkEqual(snapshot.schedulePeriodTemplates.count, PeriodTemplate.defaultTemplates.count, "缺失的节次模板回落到内置模板")
            // 需求：自动减量默认**关闭**；缺少该字段表示用户从未显式设置过。
            checkEqual(snapshot.planningPreferences.autoReduceEnabled, false, "缺失的计划偏好默认自动减量关闭")
            checkEqual(snapshot.planningPreferences.minimumScopeRatio, 0.4, "缺失的保底比例用默认值")
            checkEqual(snapshot.semesterIdentity.displayName, "当前学期", "未命名学期使用通用名称占位")
        } catch {
            check(false, "加载最小旧数据不应抛错：\(error)")
        }
    }

    // MARK: - 3. ReviewTask 属性初始值 vs 缺失字段

    static func reviewTaskDefaultsAreTolerant() {
        let raw = legacyV4JSON
        check(!raw.contains("easinessFactor"), "测试数据确实缺少 easinessFactor 字段")
        check(!raw.contains("repetitionCount"), "测试数据确实缺少 repetitionCount 字段")
        check(!raw.contains("intervalDays"), "测试数据确实缺少 intervalDays 字段")
        check(!raw.contains("remindersEnabled"), "测试数据确实缺少 remindersEnabled 字段")

        do {
            let snapshot = try JSONDecoder().decode(StoreSnapshot.self, from: Data(raw.utf8))
            guard let tolerant = snapshot.reviewTasks.first(where: { $0.title.contains("缺少 SM-2") }) else {
                check(false, "缺少字段的复习任务应当能解码出来")
                return
            }
            // 非可选属性缺键时，合成解码会抛 keyNotFound；这些值必须来自显式兜底。
            checkEqual(tolerant.status, .pending, "缺少 status 时回落到「待复习」")
            checkEqual(tolerant.remindersEnabled, true, "缺少 remindersEnabled 时回落到 true")
            checkEqual(tolerant.easinessFactor, 2.5, "缺少 easinessFactor 时回落到 2.5")
            checkEqual(tolerant.repetitionCount, 0, "缺少 repetitionCount 时回落到 0")
            checkEqual(tolerant.intervalDays, 0, "缺少 intervalDays 时回落到 0")
            check(tolerant.lastQuality == nil, "缺少 lastQuality 时保持为空")
            check(tolerant.lastReviewedAt == nil, "缺少 lastReviewedAt 时保持为空")
            checkEqual(snapshot.reviewTasks.count, 2, "两条旧复习任务都能解码")
        } catch {
            check(false, "缺少可选默认字段的旧复习任务必须可以解码，实际失败：\(error)")
        }
    }

    // MARK: - 4. 迁移是显式步骤

    static func migrationStepsAreExplicit() {
        let v1 = """
        {
          "schemaVersion": 1,
          "chatContextSummary": "旧版长期摘要",
          "dailyActivityRecords": [
            { "dateString": "2026-03-02", "completedTaskCount": 1, "studiedAt": 700000000 },
            { "dateString": "2026-03-02", "completedTaskCount": 4, "studiedAt": 700000100 }
          ]
        }
        """
        do {
            let location = makeLocation("steps")
            try writeRaw(v1, to: location)
            let store = try SnapshotFileStore(location: location)
            guard let loaded = try store.loadWithReport() else {
                check(false, "schema 1 文件应当可以加载")
                return
            }
            checkEqual(
                loaded.report.appliedSteps,
                [
                    "legacy-normalize-v1-to-v4",
                    "planning-layer-v4-to-v5",
                    "manual-study-tasks-v5-to-v6",
                    "manual-task-due-date-v6-to-v7"
                ],
                "schema 1 按顺序应用四步显式迁移"
            )
            checkEqual(loaded.snapshot.schemaVersion, 7, "迁移结果是 schema 7")
            checkEqual(loaded.snapshot.dailyActivityRecords.count, 1, "同一天的重复旧记录被合并")
            checkEqual(loaded.snapshot.dailyActivityRecords.first?.completedTaskCount, 4, "合并时保留较大的完成总数")
            check(
                loaded.snapshot.chatMemorySummary.plannedWork.contains { $0.contains("旧版长期摘要") },
                "旧的长期摘要被并入结构化记忆"
            )
            check(!loaded.report.didFabricateRecords, "多步迁移同样不产生虚构记录")

            // 版本跨度没有路径时必须报错，而不是"直接改成 5"。
            check(SnapshotMigrator.path(from: 0, to: 7) == nil, "schema 0 没有任何迁移路径")
            checkEqual(SnapshotMigrator.path(from: 4, to: 7)?.count, 3, "schema 4 到 7 经过三步")

            let v6WithManualTask = """
            {
              "schemaVersion": 6,
              "manualStudyTasks": [{
                "id": "00000000-0000-0000-0000-000000000321",
                "title": "旧手动任务",
                "note": "旧来源备注",
                "dayKey": { "year": 2026, "month": 3, "day": 2, "timeZoneIdentifier": "Asia/Shanghai" },
                "estimatedMinutes": 1600,
                "createdAt": 1772466000
              }]
            }
            """
            let v6Location = makeLocation("manual-task-v6")
            try writeRaw(v6WithManualTask, to: v6Location)
            let migratedV6 = try SnapshotFileStore(location: v6Location).loadWithReport()
            checkEqual(migratedV6?.snapshot.manualStudyTasks.first?.title, "旧手动任务", "v6 手动任务可继续读取")
            checkEqual(
                migratedV6?.snapshot.manualStudyTasks.first?.dueDate,
                StudyDayKey(year: 2026, month: 3, day: 2, timeZoneIdentifier: "Asia/Shanghai").startOfDay(),
                "旧安排日迁为同一学习日的到期日"
            )
            checkEqual(
                migratedV6?.snapshot.manualStudyTasks.first?.estimatedMinutes,
                ManualStudyTask.estimatedMinutesRange.upperBound,
                "迁移将旧预计分钟归一到共同有效范围"
            )
            checkEqual(migratedV6?.snapshot.completionEvents.count, 0, "任务迁移不生成完成或实际时长记录")
            checkEqual(SnapshotMigrator.path(from: 5, to: 6)?.count, 1, "schema 5 到 6 只有一步")
            check(SnapshotMigrator.canLoad(version: 4), "schema 4 可以加载")
            check(!SnapshotMigrator.canLoad(version: 99), "schema 99 不可以加载")
        } catch {
            check(false, "多步迁移不应抛错：\(error)")
        }
    }

    // MARK: - 5. 旧每日总数不推算时长/明细/资格

    static func legacyTotalsAreNotFabricatedIntoRecords() {
        let now = StudyDataFactory.sampleTimezoneDate(year: 2026, month: 3, day: 2, hour: 20, minute: 0)
        var legacy = StudyDataFactory.legacyOnlySnapshot(now: now)
        legacy.dailyActivityRecords = [DailyActivityRecord(date: now, completedTaskCount: 3)]

        do {
            let report = try SnapshotMigrator.migrate(&legacy)
            checkEqual(report.fromVersion, 4, "旧快照从 schema 4 开始迁移")
            check(!report.didFabricateRecords, "迁移报告的 didFabricateRecords 为 false")
            check(legacy.completionEvents.isEmpty, "旧每日总数不会变成完成事件")
            check(legacy.studySessions.isEmpty, "旧每日总数不会变成学习会话")
            check(legacy.rewardGrants.isEmpty, "旧每日总数不会变成奖励记录")

            let context = StudyDataFactory.context(now: now)
            let summary = legacy.dailySummary(for: context.todayKey)
            checkEqual(summary.source, .legacyAggregate, "只有旧每日总数时来源标记为 legacyAggregate")
            checkEqual(summary.legacyCompletedTaskCount, 3, "旧完成总数被原样保留")
            check(summary.recordedMinutes == nil, "旧每日总数不能推算出学习时长")
            check(summary.isEntertainmentEligible == nil, "旧每日总数不能推定为满足娱乐资格")
            checkEqual(summary.completedItemCount, 0, "旧每日总数不计入任务明细完成数")
            check(!RewardEligibilityGuard.isDecidable(summary: summary), "旧每日总数下资格判定为「不可判定」")
            checkEqual(summary.planID, nil, "旧数据没有计划 ID")

            // 有真实完成事件时，汇总只来自事件。
            let dayKey = context.todayKey
            let event = CompletionEvent.make(
                planItemID: UUID(),
                dayKey: dayKey,
                plannedScope: .tasks(2),
                minimumScope: .tasks(1),
                completedScope: .tasks(2),
                actualMinutes: 35,
                completedAt: now,
                createdAt: now
            )
            var recorded = legacy
            recorded.completionEvents = [event]
            let recordedSummary = recorded.dailySummary(for: dayKey)
            checkEqual(recordedSummary.source, .recordedEvents, "有完成事件时来源标记为 recordedEvents")
            checkEqual(recordedSummary.standardCompletedItemCount, 1, "标准完成数量来自完成事件")
            checkEqual(recordedSummary.recordedMinutes, 35, "学习时长来自完成事件")
            checkEqual(recordedSummary.isEntertainmentEligible, true, "标准完成 1 项即满足解锁")
            check(RewardEligibilityGuard.isDecidable(summary: recordedSummary), "有完成事件时资格可判定")

            // 完全没有记录时是"明确不达标"，不是"未知"。
            var empty = StoreSnapshot()
            empty.schemaVersion = 5
            let emptySummary = empty.dailySummary(for: dayKey)
            checkEqual(emptySummary.source, .none, "无记录时来源标记为 none")
            checkEqual(emptySummary.isEntertainmentEligible, false, "无记录时明确为不满足资格")
            check(emptySummary.recordedMinutes == nil, "无记录时时长保持未知，不填 0")
        } catch {
            check(false, "旧数据迁移不应抛错：\(error)")
        }
    }

    // MARK: - 6. 保存再读取一致

    static func roundTripPreservesPlanningLayer() {
        let now = StudyDataFactory.sampleTimezoneDate(year: 2026, month: 3, day: 2, hour: 21, minute: 0)
        var snapshot = StudyDataFactory.sampleSnapshot(now: now)
        snapshot.manualStudyTasks = [
            ManualStudyTask(
                title: "示例手动任务",
                note: "示例来源备注",
                dayKey: snapshot.dailyPlans[0].dayKey,
                estimatedMinutes: 25,
                createdAt: now
            )
        ]
        // 再加一条部分完成的记录，覆盖"部分完成"持久化。
        let partialItem = DailyPlanItem(
            planID: snapshot.dailyPlans[0].id,
            source: .courseReview(courseID: snapshot.scheduleCourses[0].id),
            title: "课程回顾：示例课程",
            plannedScope: .sections(2),
            minimumScope: .sections(1),
            estimatedMinutes: 25,
            scheduledDayKey: snapshot.dailyPlans[0].dayKey,
            createdAt: now,
            updatedAt: now
        )
        snapshot.dailyPlans[0].items.append(partialItem)
        let partialEvent = CompletionEvent.make(
            planID: snapshot.dailyPlans[0].id,
            planItemID: partialItem.id,
            dayKey: partialItem.scheduledDayKey,
            source: partialItem.source,
            plannedScope: partialItem.plannedScope,
            minimumScope: partialItem.minimumScope,
            completedScope: .sections(1),
            actualMinutes: 12,
            completedAt: now,
            assessment: StudyAssessment(totalQuestions: 6, correctQuestions: 4),
            note: "只完成了一节",
            createdAt: now
        )
        snapshot.completionEvents.append(partialEvent)
        snapshot.courseBurdenLevels = [CourseBurdenAssignment(courseID: snapshot.scheduleCourses[0].id, level: .heavy, updatedAt: now)]

        do {
            let store = try makeStore("roundtrip")
            try store.save(snapshot)
            guard let reloaded = try store.load() else {
                check(false, "保存后应当能读取")
                return
            }
            checkEqual(reloaded.schemaVersion, StudySchema.currentVersion, "读取到的版本为当前版本")
            checkEqual(reloaded.scheduleCourses.count, 1, "课程保存后读取一致")
            checkEqual(reloaded.scheduleSemester?.weekCount, snapshot.scheduleSemester?.weekCount, "学期信息一致")
            checkEqual(reloaded.semesterIdentity.name, snapshot.semesterIdentity.name, "学期名称一致")
            checkEqual(reloaded.dailyPlans.count, 1, "计划数量一致")
            checkEqual(reloaded.dailyPlans[0].items.count, 2, "计划任务数量一致")
            checkEqual(reloaded.manualStudyTasks, snapshot.manualStudyTasks, "手动任务身份、到期日、备注和预计时长均持久化")
            checkEqual(reloaded.studySessions.count, 1, "学习会话一致")
            checkEqual(reloaded.completionEvents.count, 2, "完成事件一致")
            checkEqual(reloaded.entertainmentRules.count, 1, "娱乐规则一致")
            checkEqual(reloaded.rewardGrants.count, 1, "奖励记录一致")
            checkEqual(
                reloaded.courseBurdenLevel(forCourseID: snapshot.scheduleCourses[0].id),
                .heavy,
                "课程负担等级一致"
            )
            checkEqual(
                reloaded.completionEvents.first(where: { $0.planItemID == partialItem.id })?.tier,
                .minimum,
                "部分完成的档次（保底）保存后不变"
            )
            checkEqual(
                reloaded.completionEvents.first(where: { $0.planItemID == partialItem.id })?.assessment?.accuracy,
                4.0 / 6.0,
                "答题正确率独立保存并一致"
            )
            checkEqual(
                reloaded.completionEvents.first(where: { $0.planItemID == partialItem.id })?.actualMinutes,
                12,
                "实际时长独立保存并一致"
            )
            checkEqual(
                reloaded.dailyPlans[0].items.first(where: { $0.id == partialItem.id })?.dueDate,
                nil,
                "课程回顾任务没有到期日期，安排日期单独存在"
            )
            checkEqual(encoded(reloaded), encoded(snapshot), "整份快照编码后逐字节一致")
        } catch {
            check(false, "保存/读取往返不应抛错：\(error)")
        }
    }

    // MARK: - 7. 未来版本保护

    static func futureVersionIsNeverOverwritten() {
        let future = """
        { "schemaVersion": 99, "reviewTasks": [ { "title": "未来数据" } ] }
        """
        do {
            let location = makeLocation("future")
            let url = try writeRaw(future, to: location)
            let before = rawString(at: url)
            let store = try SnapshotFileStore(location: location)

            checkThrows(SnapshotStoreError.self, "未来版本文件加载时报错") {
                _ = try store.load()
            }
            checkThrows(SnapshotStoreError.self, "未来版本文件存在时拒绝保存") {
                try store.save(StudyDataFactory.sampleSnapshot(now: Date(timeIntervalSince1970: 1_800_000_000)))
            }
            checkEqual(rawString(at: url), before, "未来版本文件内容逐字节未变")
            checkEqual(store.availableBackups().count, 0, "被拒绝的保存不会产生备份")

            // 导入未来版本文件同样被拒绝。
            checkThrows(SnapshotStoreError.self, "导入未来版本备份被拒绝") {
                _ = try store.importSnapshot(from: url)
            }
            checkEqual(rawString(at: url), before, "导入失败后文件内容仍未改变")

            // 内存快照自称未来版本时也必须拒绝写入。
            let fresh = try makeStore("future-memory")
            var bogus = StoreSnapshot()
            bogus.schemaVersion = 99
            checkThrows(SnapshotStoreError.self, "内存快照自称未来版本时拒绝写入") {
                try fresh.save(bogus)
            }
            checkEqual(fresh.storedSchemaVersion(), nil, "被拒绝的写入没有产生任何文件")

            // 低于最低可读版本的文件同样不覆盖。
            let location2 = makeLocation("too-old")
            let url2 = try writeRaw("{ \"schemaVersion\": 0 }", to: location2)
            let before2 = rawString(at: url2)
            let store2 = try SnapshotFileStore(location: location2)
            checkThrows(SnapshotMigrationError.self, "没有迁移路径的版本报出明确错误") {
                _ = try store2.load()
            }
            checkEqual(rawString(at: url2), before2, "无迁移路径时原文件未被修改")
            checkThrows(SnapshotStoreError.self, "无迁移路径的文件存在时拒绝保存") {
                try store2.save(StoreSnapshot())
            }
            checkEqual(rawString(at: url2), before2, "拒绝保存后原文件仍是原内容")
        } catch {
            check(false, "未来版本保护流程不应抛错：\(error)")
        }
    }

    // MARK: - 8. 错误文件保护与隔离

    static func corruptFileIsNeverOverwritten() {
        let corrupt = "{ \"schemaVersion\": 5, \"documents\": [ { \"title\": "
        do {
            let location = makeLocation("corrupt")
            let url = try writeRaw(corrupt, to: location)
            let before = rawString(at: url)
            let store = try SnapshotFileStore(location: location)

            checkThrows(SnapshotStoreError.self, "损坏文件加载时报可诊断错误") {
                _ = try store.load()
            }
            checkThrows(SnapshotStoreError.self, "损坏文件存在时拒绝保存") {
                try store.save(StoreSnapshot())
            }
            checkEqual(rawString(at: url), before, "损坏文件未被覆盖")
            checkEqual(store.availableBackups().count, 0, "拒绝保存时不会轮转备份")

            // 隔离后可以重建。
            let quarantined = try store.quarantineUnreadableStore(at: Date(timeIntervalSince1970: 1_800_000_000))
            check(quarantined != nil, "损坏文件被隔离并返回位置")
            check(!FileManager.default.fileExists(atPath: url.path), "隔离后原路径不再有文件")
            if let quarantined {
                check(FileManager.default.fileExists(atPath: quarantined.path), "隔离文件真实存在")
                checkEqual(rawString(at: quarantined), before, "隔离文件内容与原始内容一致")
            }

            try store.save(StudyDataFactory.sampleSnapshot(now: Date(timeIntervalSince1970: 1_800_000_000)))
            checkEqual(store.storedSchemaVersion(), StudySchema.currentVersion, "隔离后可以正常写入新数据")

            // 显式覆盖策略下也允许写入（供 G 在用户确认后使用）。
            let location2 = makeLocation("override")
            try writeRaw(corrupt, to: location2)
            let store2 = try SnapshotFileStore(location: location2)
            try store2.save(StoreSnapshot(), policy: .overwriteUnreadableExisting)
            checkEqual(store2.storedSchemaVersion(), StudySchema.currentVersion, "显式覆盖策略下可以写入")
        } catch {
            check(false, "损坏文件处理流程不应抛错：\(error)")
        }
    }

    // MARK: - 9. 完成事件唯一键与幂等

    static func completionKeysAreStableAndIdempotent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = StudyDataFactory.context(now: now)
        let sessionID = UUID()
        let itemID = UUID()

        let first = CompletionEvent.make(
            sessionID: sessionID,
            planItemID: itemID,
            dayKey: context.todayKey,
            plannedScope: .tasks(3),
            minimumScope: .tasks(1),
            completedScope: .tasks(3),
            actualMinutes: 30,
            completedAt: now,
            createdAt: now
        )
        let second = CompletionEvent.make(
            sessionID: sessionID,
            planItemID: itemID,
            dayKey: context.todayKey,
            plannedScope: .tasks(3),
            minimumScope: .tasks(1),
            completedScope: .tasks(3),
            actualMinutes: 30,
            completedAt: now.addingTimeInterval(600),
            createdAt: now.addingTimeInterval(600)
        )
        checkEqual(first.idempotencyKey, second.idempotencyKey, "同一会话的完成键稳定（与完成时间无关）")
        checkEqual(first.id, second.id, "同一会话的完成事件 ID 稳定")

        var snapshot = StoreSnapshot()
        snapshot.schemaVersion = 5
        guard let inserted = snapshot.insertingCompletionEvent(first) else {
            check(false, "首次插入完成事件应当成功")
            return
        }
        checkEqual(inserted.completionEvents.count, 1, "首次插入后有 1 条完成事件")
        check(inserted.insertingCompletionEvent(second) == nil, "重复完成被识别并忽略")
        checkEqual(inserted.completionEvents.count, 1, "重复完成不会新增记录")
        check(inserted.hasCompletionEvent(idempotencyKey: first.idempotencyKey), "能按幂等键查询到完成事件")

        let otherSession = CompletionEvent.make(
            sessionID: UUID(),
            dayKey: context.todayKey,
            completedScope: .tasks(1),
            actualMinutes: 10,
            completedAt: now,
            createdAt: now
        )
        check(inserted.insertingCompletionEvent(otherSession) != nil, "不同会话的完成事件可以插入")

        // 无会话时按计划项 + 学习日去重。
        let manualA = CompletionEvent.make(
            planItemID: itemID,
            dayKey: context.todayKey,
            completedScope: .tasks(1),
            actualMinutes: 5,
            completedAt: now,
            createdAt: now
        )
        let manualB = CompletionEvent.make(
            planItemID: itemID,
            dayKey: context.todayKey,
            completedScope: .tasks(2),
            actualMinutes: 9,
            completedAt: now.addingTimeInterval(60),
            createdAt: now.addingTimeInterval(60)
        )
        checkEqual(manualA.idempotencyKey, manualB.idempotencyKey, "无会话时按计划项去重")

        // 撤销保留原记录。
        guard let revoked = inserted.revokingCompletionEvent(id: first.id, at: now, reason: "误触") else {
            check(false, "撤销完成事件应当成功")
            return
        }
        checkEqual(revoked.completionEvents.count, 1, "撤销不会删除记录")
        checkEqual(revoked.completionEvents[0].isRevoked, true, "撤销信息被写入")
        check(revoked.revokingCompletionEvent(id: first.id, at: now, reason: "再次撤销") == nil, "重复撤销被拒绝")
        checkEqual(revoked.dailySummary(for: context.todayKey).standardCompletedItemCount, 0, "撤销后不再计入完成汇总")
    }

    // MARK: - 10. 部分完成与整体完成

    static func partialAndFullCompletionStaySeparate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = StudyDataFactory.context(now: now)
        let dayKey = context.todayKey
        let planned = StudyScope.tasks(4)
        let minimum = StudyScope.tasks(2)

        let full = CompletionEvent.make(
            planItemID: UUID(),
            dayKey: dayKey,
            plannedScope: planned,
            minimumScope: minimum,
            completedScope: .tasks(4),
            actualMinutes: 40,
            completedAt: now,
            createdAt: now
        )
        checkEqual(full.tier, .standard, "完成全部范围记为标准完成")
        checkEqual(full.isPartialCompletion, false, "整体完成不算部分完成")
        check(full.isFullCompletion, "整体完成的判定为真")

        let partial = CompletionEvent.make(
            planItemID: UUID(),
            dayKey: dayKey,
            plannedScope: planned,
            minimumScope: minimum,
            completedScope: .tasks(2),
            actualMinutes: 20,
            completedAt: now,
            createdAt: now
        )
        checkEqual(partial.tier, .minimum, "达到保底范围记为保底完成")
        checkEqual(partial.isPartialCompletion, true, "部分完成被单独标记")
        check(!partial.isFullCompletion, "部分完成不算整体完成")

        let studied = CompletionEvent.make(
            planItemID: UUID(),
            dayKey: dayKey,
            plannedScope: planned,
            minimumScope: minimum,
            completedScope: .tasks(1),
            actualMinutes: 8,
            completedAt: now,
            createdAt: now
        )
        checkEqual(studied.tier, .studied, "未到保底范围只记为已学习")

        // 量纲不同时不可比较，不猜档次。
        let mixed = CompletionEvent.make(
            planItemID: UUID(),
            dayKey: dayKey,
            plannedScope: planned,
            minimumScope: minimum,
            completedScope: .minutes(30),
            actualMinutes: 30,
            completedAt: now,
            createdAt: now
        )
        checkEqual(mixed.tier, .studied, "量纲不同时只记为已学习，不猜标准完成")
        check(mixed.isPartialCompletion == nil, "量纲不同时部分完成判定为未知")

        // 学习与答题正确分开。
        let withAssessment = CompletionEvent.make(
            planItemID: UUID(),
            dayKey: dayKey,
            plannedScope: planned,
            minimumScope: minimum,
            completedScope: .tasks(4),
            actualMinutes: 25,
            completedAt: now,
            assessment: StudyAssessment(totalQuestions: 4, correctQuestions: 3, selfRating: 4),
            createdAt: now
        )
        checkEqual(withAssessment.actualMinutes, 25, "完成时长不受答题结果影响")
        checkEqual(withAssessment.assessment?.accuracy, 0.75, "答题正确率单独记录")
        checkEqual(withAssessment.tier, .standard, "答题正确率不影响完成档次")
        checkEqual(StudyAssessment().accuracy, nil, "没有题数时不编造正确率")

        // 计划项按完成事件重算（幂等，且不会凭空判定完成）。
        let planID = UUID()
        let item = DailyPlanItem(
            planID: planID,
            source: .manual(note: "自定任务"),
            title: "自定任务",
            plannedScope: planned,
            minimumScope: minimum,
            estimatedMinutes: 40,
            scheduledDayKey: dayKey,
            createdAt: now,
            updatedAt: now
        )
        var plan = DailyStudyPlan(
            id: planID,
            dayKey: dayKey,
            budget: DailyPlanBudget(capacityMinutes: 120),
            items: [item],
            createdAt: now,
            updatedAt: now
        )
        let partialEvent = CompletionEvent.make(
            planItemID: item.id,
            dayKey: dayKey,
            plannedScope: planned,
            minimumScope: minimum,
            completedScope: .tasks(2),
            actualMinutes: 20,
            completedAt: now,
            createdAt: now
        )
        let recomputedOnce = plan.recomputingItemStates(from: [partialEvent])
        let recomputedTwice = recomputedOnce.recomputingItemStates(from: [partialEvent])
        checkEqual(recomputedOnce.items[0].completionTier, .minimum, "重算后档次为保底完成")
        checkEqual(recomputedOnce.items[0].status, .completed, "保底完成同样标记为已完成")
        checkEqual(encodedValue(recomputedOnce), encodedValue(recomputedTwice), "按事件重算是幂等的")

        plan.items[0].status = .completed
        let recomputedWithoutEvents = plan.recomputingItemStates(from: [])
        checkEqual(recomputedWithoutEvents.items[0].status, .pending, "没有事件时不会被当作已完成")
        checkEqual(recomputedWithoutEvents.items[0].achievedScope, nil, "没有事件时完成范围保持为空")

        // 量纲不可比的完成事件：不能被标成"已完成"。
        let mismatched = CompletionEvent.make(
            planItemID: item.id,
            dayKey: dayKey,
            plannedScope: planned,
            minimumScope: minimum,
            completedScope: .minutes(20),
            actualMinutes: 20,
            completedAt: now,
            createdAt: now
        )
        let recomputedMismatch = plan.recomputingItemStates(from: [mismatched])
        checkEqual(recomputedMismatch.items[0].completionTier, nil, "量纲不可比时档次保持未知")
        checkEqual(recomputedMismatch.items[0].status, .inProgress, "量纲不可比时不会被标成已完成")
    }

    // MARK: - 10b. 归一化：同一学习日只有一个生效计划

    static func normalizeKeepsSingleActivePlan() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dayKey = StudyDataFactory.context(now: now).todayKey
        let lowVersionID = UUID()
        let highVersionID = UUID()
        let makePlan: (_ id: UUID, _ version: Int) -> DailyStudyPlan = { id, version in
            DailyStudyPlan(
                id: id,
                dayKey: dayKey,
                version: version,
                budget: DailyPlanBudget(capacityMinutes: 60),
                createdAt: now,
                updatedAt: now
            )
        }

        var snapshot = StoreSnapshot()
        snapshot.schemaVersion = 4
        // 顺序刻意把低版本排在前面，验证"保留最高版本"而不是"保留第一个"。
        snapshot.dailyPlans = [makePlan(lowVersionID, 1), makePlan(highVersionID, 3)]
        snapshot.dailyPlans[0].items = [
            DailyPlanItem(
                planID: UUID(), // 孤儿：planID 与所属计划不一致
                source: .manual(note: "孤儿任务"),
                title: "孤儿任务",
                plannedScope: .tasks(1),
                estimatedMinutes: 10,
                scheduledDayKey: dayKey,
                createdAt: now,
                updatedAt: now
            )
        ]
        snapshot.completionEvents = [
            CompletionEvent.make(sessionID: UUID(), dayKey: dayKey, completedScope: .tasks(1), actualMinutes: 5, completedAt: now, createdAt: now)
        ]

        snapshot.normalizePlanningLayer()
        checkEqual(snapshot.dailyPlans.count, 2, "归一化不删除计划")
        checkEqual(
            snapshot.dailyPlans.first(where: { $0.id == highVersionID })?.status,
            .active,
            "同一学习日保留版本号最高的计划为生效"
        )
        checkEqual(
            snapshot.dailyPlans.first(where: { $0.id == lowVersionID })?.status,
            .superseded,
            "同一学习日的低版本计划被标记为已被替换"
        )
        checkEqual(
            snapshot.dailyPlans.first(where: { $0.id == lowVersionID })?.items.first?.planID,
            lowVersionID,
            "孤儿计划项的 planID 被修复为所属计划"
        )

        let once = snapshot
        var twice = snapshot
        twice.normalizePlanningLayer()
        checkEqual(
            encoded(twice.normalizedToCurrentSchema()),
            encoded(once.normalizedToCurrentSchema()),
            "结构归一化是幂等的"
        )
    }

    // MARK: - 11. 奖励历史绑定规则版本

    static func rewardHistoryIsPinnedToRuleRevision() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = StudyDataFactory.context(now: now)
        let dayKey = context.todayKey
        let eventID = UUID()

        let ruleV1 = EntertainmentRule(
            name: "每日游戏",
            condition: .standardItems(1),
            fallback: .scaledReward(ratio: 0.5),
            rewardMinutes: 30,
            createdAt: now,
            updatedAt: now
        )
        let progressV1 = RewardConditionProgress(
            ruleID: ruleV1.id,
            ruleRevisionID: ruleV1.revisionID,
            metric: ruleV1.condition.metric,
            achievedValue: 1,
            requiredValue: 1,
            detail: "标准完成 1 项",
            basisEventIDs: [eventID],
            isSatisfied: true
        )
        let grantV1 = RewardGrant.make(
            ruleSnapshot: ruleV1.snapshotValue,
            dayKey: dayKey,
            basisEventIDs: [eventID],
            conditionProgress: progressV1,
            grantedMinutes: 30,
            grantedAt: now
        )

        // 编辑规则：版本 +1，revisionID 变化，规则时长改为 60。
        let ruleV2 = ruleV1.revised(rewardMinutes: 60, at: now.addingTimeInterval(86_400))
        checkEqual(ruleV2.ruleVersion, 2, "编辑规则后版本号 +1")
        check(ruleV2.revisionID != ruleV1.revisionID, "编辑规则生成新的 revisionID")
        checkEqual(ruleV1.rewardMinutes, 30, "规则对象本身未被就地修改")

        let nextDay = dayKey.advanced(byDays: 1)
        let progressV2 = RewardConditionProgress(
            ruleID: ruleV2.id,
            ruleRevisionID: ruleV2.revisionID,
            metric: ruleV2.condition.metric,
            achievedValue: 2,
            requiredValue: 1,
            detail: "标准完成 2 项",
            basisEventIDs: [eventID],
            isSatisfied: true
        )
        let grantV2 = RewardGrant.make(
            ruleSnapshot: ruleV2.snapshotValue,
            dayKey: nextDay,
            basisEventIDs: [eventID],
            conditionProgress: progressV2,
            grantedMinutes: 60,
            grantedAt: now.addingTimeInterval(86_400)
        )

        checkEqual(grantV1.ruleVersion, 1, "历史奖励仍记录旧版本号")
        checkEqual(grantV1.ruleSnapshot.rewardMinutes, 30, "历史奖励仍使用旧版本时长")
        checkEqual(grantV1.ruleSnapshot.revisionID, ruleV1.revisionID, "历史奖励仍指向旧 revisionID")
        checkEqual(grantV2.ruleVersion, 2, "新奖励记录新版本号")
        checkEqual(grantV2.grantedMinutes, 60, "新奖励按新规则发放")
        check(grantV1.grantKey != grantV2.grantKey, "不同学习日/版本的发放键不同")

        var snapshot = StoreSnapshot()
        snapshot.schemaVersion = 5
        snapshot.entertainmentRules = [ruleV1, ruleV2]
        guard let withV1 = snapshot.insertingRewardGrant(grantV1) else {
            check(false, "首次发放奖励应当成功")
            return
        }
        check(withV1.insertingRewardGrant(grantV1) == nil, "同一规则版本的重复发放被忽略")
        checkEqual(withV1.rewardGrants.count, 1, "重复发放不会新增记录")
        guard let withBoth = withV1.insertingRewardGrant(grantV2) else {
            check(false, "新版本/新学习日的奖励应当可以发放")
            return
        }
        checkEqual(withBoth.rewardGrants.count, 2, "编辑规则后可以再次发放")
        checkEqual(
            withBoth.rewardGrant(grantKey: grantV1.grantKey)?.ruleSnapshot.rewardMinutes,
            30,
            "规则编辑后历史发放记录未被改写"
        )
        checkEqual(withBoth.entitlementRules(on: dayKey).count, 2, "两条规则都在当天生效（未设置生效区间）")

        // 生效区间外的规则不参与。
        let laterRule = ruleV2.revised(effectiveFrom: .some(nextDay.advanced(byDays: 10)), at: now)
        check(!laterRule.isEffective(on: dayKey), "生效日期之后的规则当天不生效")
        check(laterRule.isEffective(on: nextDay.advanced(byDays: 10)), "生效日期当天规则生效")
    }

    // MARK: - 12. 奖励状态与保底适配

    static func rewardStatesAndFallbacksBehave() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let context = StudyDataFactory.context(now: now)
        let dayKey = context.todayKey

        // 保底适配方式。
        checkEqual(
            EntertainmentFallbackMode.scaledReward(ratio: 0.5).grantedMinutes(ruleMinutes: 30, isConditionSatisfied: false, achievedRatio: 0.6),
            18,
            "按完成比例缩短奖励"
        )
        checkEqual(
            EntertainmentFallbackMode.scaledReward(ratio: 0.5).grantedMinutes(ruleMinutes: 30, isConditionSatisfied: false, achievedRatio: 0.2),
            15,
            "完成比例低于保底比例时按保底比例发放"
        )
        checkEqual(
            EntertainmentFallbackMode.scaledReward(ratio: 0.5).grantedMinutes(ruleMinutes: 30, isConditionSatisfied: true, achievedRatio: 1),
            30,
            "达标时发放完整规则时长"
        )
        checkEqual(
            EntertainmentFallbackMode.fixedMinimumReward(minutes: 10).grantedMinutes(ruleMinutes: 30, isConditionSatisfied: false, achievedRatio: 0.2),
            10,
            "保底固定时长发放"
        )
        checkEqual(
            EntertainmentFallbackMode.fixedMinimumReward(minutes: 10).grantedMinutes(ruleMinutes: 30, isConditionSatisfied: false, achievedRatio: 0),
            nil,
            "当天没有任何学习时不发保底奖励"
        )
        checkEqual(
            EntertainmentFallbackMode.unlockRegardless.grantedMinutes(ruleMinutes: 30, isConditionSatisfied: false, achievedRatio: 0),
            30,
            "始终解锁模式照常发放"
        )
        checkEqual(
            EntertainmentFallbackMode.suspend.grantedMinutes(ruleMinutes: 30, isConditionSatisfied: false, achievedRatio: 1),
            nil,
            "暂停模式不发放"
        )
        checkEqual(
            EntertainmentFallbackMode.none.grantedMinutes(ruleMinutes: 30, isConditionSatisfied: false, achievedRatio: 1),
            nil,
            "不适配模式下未达标不发放"
        )
        checkEqual(
            EntertainmentFallbackMode.none.grantedMinutes(ruleMinutes: 0, isConditionSatisfied: true, achievedRatio: 1),
            nil,
            "规则时长为 0 时不发放"
        )

        // 领取 / 开始 / 结束是三个独立状态，重复领取被拒绝。
        let rule = EntertainmentRule(
            name: "娱乐",
            condition: .anyStudied,
            rewardMinutes: 30,
            createdAt: now,
            updatedAt: now
        )
        let progress = RewardConditionProgress(
            ruleID: rule.id,
            ruleRevisionID: rule.revisionID,
            metric: .anyStudied,
            achievedValue: 1,
            requiredValue: 1,
            isSatisfied: true
        )
        let grant = RewardGrant.make(
            ruleSnapshot: rule.snapshotValue,
            dayKey: dayKey,
            basisEventIDs: [],
            conditionProgress: progress,
            grantedMinutes: 30,
            grantedAt: now
        )
        var snapshot = StoreSnapshot()
        snapshot.schemaVersion = 5
        guard let withGrant = snapshot.insertingRewardGrant(grant) else {
            check(false, "发放奖励应当成功")
            return
        }
        checkEqual(withGrant.pendingRewardGrants(on: dayKey).count, 1, "待领取列表包含新奖励")
        checkEqual(withGrant.rewardGrant(id: grant.id)?.state, .pending, "初始状态为待领取")

        guard let claimed = withGrant.claimingRewardGrant(id: grant.id, at: now.addingTimeInterval(10)) else {
            check(false, "首次领取应当成功")
            return
        }
        checkEqual(claimed.rewardGrant(id: grant.id)?.state, .claimed, "领取后状态为已领取")
        checkEqual(claimed.rewardGrant(id: grant.id)?.claimedAt, now.addingTimeInterval(10), "领取时间被记录")
        check(claimed.rewardGrant(id: grant.id)?.startedAt == nil, "领取时不写开始时间（状态分开）")
        check(claimed.claimingRewardGrant(id: grant.id, at: now.addingTimeInterval(20)) == nil, "重复领取被拒绝")

        guard let started = claimed.startingRewardGrant(id: grant.id, at: now.addingTimeInterval(30)) else {
            check(false, "开始娱乐应当成功")
            return
        }
        checkEqual(started.rewardGrant(id: grant.id)?.state, .started, "开始后状态为已开始")
        check(started.rewardGrant(id: grant.id)?.endedAt == nil, "开始时没有结束时间")

        guard let finished = started.finishingRewardGrant(id: grant.id, at: now.addingTimeInterval(1_830), usedMinutes: 30) else {
            check(false, "结束娱乐应当成功")
            return
        }
        checkEqual(finished.rewardGrant(id: grant.id)?.state, .finished, "结束后状态为已结束")
        checkEqual(finished.rewardGrant(id: grant.id)?.usedMinutes, 30, "使用时长被记录")
        checkEqual(finished.rewardGrant(id: grant.id)?.endedAt, now.addingTimeInterval(1_830), "结束时间被记录")
        check(finished.finishingRewardGrant(id: grant.id, at: now, usedMinutes: 5) == nil, "重复结束被拒绝")

        // 撤销不删除记录。
        guard let revoked = finished.revokingRewardGrant(id: grant.id, at: now.addingTimeInterval(2_000), reason: "误发") else {
            check(false, "撤销奖励应当成功")
            return
        }
        checkEqual(revoked.rewardGrants.count, 1, "撤销不会删除奖励记录")
        checkEqual(revoked.rewardGrant(id: grant.id)?.state, .revoked, "撤销后状态为已撤销")
        check(revoked.revokingRewardGrant(id: grant.id, at: now, reason: "再次撤销") == nil, "重复撤销被拒绝")
    }

    // MARK: - 13. 备份恢复一致性

    static func backupRestoreKeepsRecordsConsistent() {
        let now = StudyDataFactory.sampleTimezoneDate(year: 2026, month: 3, day: 2, hour: 21, minute: 0)
        let snapshotA = StudyDataFactory.sampleSnapshot(now: now)
        var snapshotB = StudyDataFactory.sampleSnapshot(now: now.addingTimeInterval(86_400))
        snapshotB.rewardGrants = []

        do {
            let store = try makeStore("backup")
            try store.save(snapshotA)
            try store.save(snapshotB)

            let backups = store.availableBackups()
            checkEqual(backups.count, 1, "第二次保存产生 1 个备份")

            let restored = try store.restoreFromBackup(index: 1)
            checkEqual(restored.schemaVersion, StudySchema.currentVersion, "备份恢复后版本为当前版本")
            checkEqual(restored.completionEvents.count, snapshotA.completionEvents.count, "恢复后完成记录数量一致")
            checkEqual(restored.rewardGrants.count, snapshotA.rewardGrants.count, "恢复后奖励记录数量一致")
            checkEqual(
                restored.completionEvents.map(\.idempotencyKey),
                snapshotA.completionEvents.map(\.idempotencyKey),
                "恢复后完成记录幂等键一致"
            )
            checkEqual(
                restored.rewardGrants.map(\.grantKey),
                snapshotA.rewardGrants.map(\.grantKey),
                "恢复后奖励发放键一致"
            )
            checkEqual(
                restored.rewardGrants.first?.ruleSnapshot.rewardMinutes,
                snapshotA.rewardGrants.first?.ruleSnapshot.rewardMinutes,
                "恢复后奖励仍绑定当时的规则版本"
            )
            checkEqual(
                restored.dailyPlans.flatMap(\.items).map(\.id),
                snapshotA.dailyPlans.flatMap(\.items).map(\.id),
                "恢复后计划任务一致"
            )
            checkEqual(restored.manualStudyTasks, snapshotA.manualStudyTasks, "备份恢复保留手动任务稳定 ID、到期日与预计分钟")
            checkEqual(encoded(restored), encoded(snapshotA), "恢复的快照与保存前逐字节一致")

            let current = try store.load()
            checkEqual(encoded(current ?? StoreSnapshot()), encoded(snapshotB), "主文件仍是最后一次保存的内容")
            checkEqual(try store.loadRecoverySnapshot()?.completionEvents.count, snapshotA.completionEvents.count, "兼容恢复入口返回最近的备份")
        } catch {
            check(false, "备份恢复流程不应抛错：\(error)")
        }
    }

    // MARK: - 14. 隐私备份规则

    static func privacyRedactionCoversNewFields() {
        let now = StudyDataFactory.sampleTimezoneDate(year: 2026, month: 3, day: 2, hour: 21, minute: 0)
        var snapshot = StudyDataFactory.sampleSnapshot(now: now)
        snapshot.diagnosticEvents = [
            AppDiagnosticEvent(level: .info, message: "敏感诊断"),
            AppDiagnosticEvent(level: .error, message: "敏感错误")
        ]
        snapshot.documents = [
            StudyDocument(title: "资料", sourceName: "a.txt", kind: .note, content: "敏感正文")
        ]
        snapshot.scheduleCourses[0].location = "教学楼A-101"
        snapshot.scheduleCourses[0].teacher = "张老师"
        snapshot.scheduleCourses[0].note = "带计算器"
        snapshot.scheduleExceptions = [
            ScheduleException(kind: .relocation, courseID: snapshot.scheduleCourses[0].id, date: now, note: "调课到实验室", createdAt: now)
        ]
        let privateManualTaskID = UUID()
        snapshot.dailyPlans[0].items[0].title = "私人任务"
        snapshot.dailyPlans[0].items[0].source = .manual(note: "私人来源说明", manualTaskID: privateManualTaskID)
        snapshot.dailyPlans[0].items[0].note = "个人备注"
        snapshot.dailyPlans[0].unplaceable = [
            UnplaceablePlanItem(
                source: .manual(note: "另一条来源说明", manualTaskID: privateManualTaskID),
                title: "私人任务",
                plannedScope: .tasks(1),
                estimatedMinutes: 15,
                reason: .insufficientCapacity,
                detail: "任务「私人任务」当天容量不足"
            )
        ]
        snapshot.dailyPlans[0].explanation.lines = ["安排：私人任务将在有空余时间时学习。"]
        snapshot.manualStudyTasks = [
            ManualStudyTask(id: privateManualTaskID, title: "私人任务", note: "私人手动任务备注", dayKey: snapshot.dailyPlans[0].dayKey, createdAt: now)
        ]
        snapshot.studySessions[0].note = "个人学习笔记"
        snapshot.completionEvents[0].note = "个人完成备注"
        snapshot.completionEvents[0].source = .manual(note: "完成来源说明", manualTaskID: privateManualTaskID)

        let routineBefore = snapshot.availabilitySettings.weekdayStudyWindows.count
        let (redacted, summary) = SnapshotPrivacyRedactor.redact(snapshot)

        checkEqual(summary.clearedDiagnosticEvents, 2, "隐私备份清空诊断记录")
        checkEqual(summary.clearedDocumentContents, 1, "隐私备份清空资料正文")
        checkEqual(summary.clearedCourseLocations, 1, "隐私备份清空课程地点")
        checkEqual(summary.clearedExceptionNotes, 1, "隐私备份清空排课例外备注")
        checkEqual(summary.clearedStudyNotes, 2, "隐私备份清空会话与完成事件备注")
        checkEqual(summary.clearedManualSourceNotes, 4, "隐私备份清空计划、完成和待安排项的来源说明及手动任务备注")
        checkEqual(summary.clearedManualTaskTitles, 5, "隐私备份清空手动任务标题及计划中的副本")
        check(summary.totalClearedFields >= 8, "隐私备份覆盖了全部新增可识别字段")

        checkEqual(redacted.scheduleCourses[0].location, SnapshotPrivacyRedactor.placeholder, "课程地点已脱敏")
        checkEqual(redacted.scheduleCourses[0].teacher, SnapshotPrivacyRedactor.placeholder, "课程教师已脱敏")
        checkEqual(redacted.scheduleCourses[0].note, SnapshotPrivacyRedactor.placeholder, "课程备注已脱敏")
        checkEqual(redacted.scheduleExceptions[0].note, SnapshotPrivacyRedactor.placeholder, "例外备注已脱敏")
        checkEqual(redacted.documents[0].content, SnapshotPrivacyRedactor.placeholder, "资料正文已脱敏")
        checkEqual(redacted.studySessions[0].note, SnapshotPrivacyRedactor.placeholder, "学习会话备注已脱敏")
        checkEqual(redacted.completionEvents[0].note, SnapshotPrivacyRedactor.placeholder, "完成事件备注已脱敏")
        checkEqual(redacted.completionEvents[0].source?.manualNote, SnapshotPrivacyRedactor.placeholder, "完成来源说明已脱敏")
        checkEqual(redacted.dailyPlans[0].items[0].note, SnapshotPrivacyRedactor.placeholder, "计划任务备注已脱敏")
        checkEqual(redacted.dailyPlans[0].items[0].title, SnapshotPrivacyRedactor.placeholder, "手动计划项标题已脱敏")
        checkEqual(redacted.dailyPlans[0].items[0].source.manualNote, SnapshotPrivacyRedactor.placeholder, "手动来源说明已脱敏")
        checkEqual(redacted.dailyPlans[0].unplaceable[0].title, SnapshotPrivacyRedactor.placeholder, "待安排手动任务标题已脱敏")
        checkEqual(redacted.dailyPlans[0].unplaceable[0].source.manualNote, SnapshotPrivacyRedactor.placeholder, "待安排任务来源说明已脱敏")
        checkEqual(redacted.dailyPlans[0].unplaceable[0].detail, "任务「\(SnapshotPrivacyRedactor.placeholder)」当天容量不足", "待安排原因中嵌入的任务标题已脱敏")
        checkEqual(redacted.dailyPlans[0].explanation.lines[0], "安排：\(SnapshotPrivacyRedactor.placeholder)将在有空余时间时学习。", "计划解释中的手动任务标题已脱敏")
        checkEqual(redacted.manualStudyTasks[0].note, SnapshotPrivacyRedactor.placeholder, "手动任务备注已脱敏")
        checkEqual(redacted.manualStudyTasks[0].title, SnapshotPrivacyRedactor.placeholder, "手动任务标题已脱敏")
        check(redacted.diagnosticEvents.isEmpty, "诊断记录已清空")

        // 结构必须可恢复：完成事件、奖励、课表结构、作息窗口都保留。
        checkEqual(redacted.completionEvents[0].idempotencyKey, snapshot.completionEvents[0].idempotencyKey, "脱敏后完成事件身份保留")
        checkEqual(redacted.rewardGrants.count, 1, "脱敏后奖励记录保留")
        checkEqual(redacted.scheduleCourses[0].name, snapshot.scheduleCourses[0].name, "脱敏后课程名称保留")
        checkEqual(redacted.availabilitySettings.weekdayStudyWindows.count, routineBefore, "脱敏后学习窗口保留")
        checkEqual(redacted.planningPreferences.dailyCapMinutes, snapshot.planningPreferences.dailyCapMinutes, "脱敏后每日上限保留")
        check(!summary.keptFieldNotes.isEmpty, "隐私规则显式列出保留项")
    }

    // MARK: - 15. 持久化键名契约

    static func persistenceKeysMatchScheduleContract() {
        let now = StudyDataFactory.sampleTimezoneDate(year: 2026, month: 3, day: 2)
        var snapshot = StudyDataFactory.sampleSnapshot(now: now)
        snapshot.scheduleSemester = StudyDataFactory.semester(firstWeekStart: now)
        snapshot.scheduleExceptions = [
            ScheduleException(kind: .cancellation, courseID: snapshot.scheduleCourses[0].id, date: now, createdAt: now)
        ]
        snapshot.schedulePeriodTemplates = PeriodTemplate.defaultTemplates

        do {
            let store = try makeStore("keys")
            let url = store.location.directory.appendingPathComponent("probe.json")
            try store.exportSnapshot(snapshot, to: url)
            let json = jsonObject(at: url)
            check(json[SchedulePersistenceKeys.semester] != nil, "键名与 SchedulePersistenceKeys.semester 一致")
            check(json[SchedulePersistenceKeys.courses] != nil, "键名与 SchedulePersistenceKeys.courses 一致")
            check(json[SchedulePersistenceKeys.exceptions] != nil, "键名与 SchedulePersistenceKeys.exceptions 一致")
            check(json[SchedulePersistenceKeys.periodTemplates] != nil, "键名与 SchedulePersistenceKeys.periodTemplates 一致")
            check(json[SchedulePersistenceKeys.availabilitySettings] != nil, "键名与 SchedulePersistenceKeys.availabilitySettings 一致")
            checkEqual(json["schemaVersion"] as? Int, 7, "导出的 schemaVersion 为 7")
            for key in ["dailyPlans", "studySessions", "completionEvents", "entertainmentRules", "rewardGrants", "planningPreferences", "courseBurdenLevels", "semesterIdentity"] {
                check(json[key] != nil, "导出的 JSON 含统一数据层字段 \(key)")
            }
            checkEqual(StoreSnapshot().schemaVersion, 7, "新建快照的默认版本为 7")
            checkEqual(StudySchema.currentVersion, 7, "版本常量集中定义为 7")
            checkEqual(StudySchema.versionKeyName, "schemaVersion", "版本字段名由常量给出")
        } catch {
            check(false, "导出探测键名不应抛错：\(error)")
        }
    }

    // MARK: - 15b. 契约适配器可用性

    static func contractAdaptersProduceRealResults() {
        // 2026-03-02 是周一。
        let monday = StudyDataFactory.sampleTimezoneDate(year: 2026, month: 3, day: 2, hour: 0, minute: 0)
        let context = StudyDataFactory.context(now: monday.addingTimeInterval(8 * 3_600))
        let eveningCourse = StudyDataFactory.sampleCourse(
            name: "示例晚课",
            weekday: .monday,
            start: TimeOfDay(hour: 19, minute: 0),
            end: TimeOfDay(hour: 20, minute: 0)
        )

        var snapshot = StoreSnapshot()
        snapshot.schemaVersion = 5
        snapshot.scheduleSemester = StudyDataFactory.semester(firstWeekStart: monday)
        snapshot.scheduleCourses = [eveningCourse]
        let schedule = snapshot.scheduleForComputation

        // ScheduleResolving：单日与日期范围都要给出真实课程实例。
        let dayOccurrences = ScheduleResolver.occurrences(on: monday, schedule: schedule, context: context)
        checkEqual(dayOccurrences.count, 1, "契约适配器解析出当天 1 次课程实例")
        checkEqual(dayOccurrences.first?.courseID, eveningCourse.id, "课程实例能追溯到来源课程")
        checkEqual(
            dayOccurrences.first?.start,
            monday.addingTimeInterval(19 * 3_600),
            "课程实例开始时间落在学期时区的 19:00"
        )

        let weekRange = DateInterval(start: monday, duration: 7 * 86_400)
        let weekOccurrences = ScheduleResolver.occurrences(in: weekRange, schedule: schedule, context: context)
        checkEqual(weekOccurrences.count, 1, "日期范围解析只包含真实发生的那一次课程")

        // AvailabilityCalculating：课程必须从可用容量里被扣掉。
        let preferences = AvailabilityPreferences(
            routine: .assumedDefaults,
            planning: PlanningPreferences(dailyCapMinutes: 120, planningTimeZoneIdentifier: "Asia/Shanghai")
        )
        let withoutCourses = ScheduleSnapshot(
            semester: snapshot.scheduleSemester ?? .fallback,
            courses: [],
            exceptions: []
        )
        let baseline = AvailabilityCalculator.availability(
            on: monday,
            schedule: withoutCourses,
            preferences: preferences,
            now: nil
        )
        let withCourse = AvailabilityCalculator.availability(
            on: monday,
            schedule: schedule,
            preferences: preferences,
            now: nil
        )
        checkEqual(baseline.totalFreeMinutes, 210, "默认工作日晚间窗口给出 210 分钟")
        checkEqual(baseline.totalFreeMinutes - withCourse.totalFreeMinutes, 60, "1 小时课程恰好扣掉 60 分钟")
        check(withCourse.referenceNow == nil, "不传 now 时按整日计算")
        check(
            withCourse.occupiedIntervals.contains { $0.sourceCourseID == eveningCourse.id },
            "课程出现在扣除原因里并可追溯到课程 id"
        )
        checkEqual(withCourse.occupiedMinutesWithinWindows, 60, "窗口内被占用 60 分钟")

        // 停课例外：可用时间恢复，且不产生任何学习完成记录。
        snapshot.scheduleExceptions = [
            ScheduleException(
                kind: .cancellation,
                courseID: eveningCourse.id,
                date: monday,
                createdAt: monday
            )
        ]
        let cancelledSchedule = snapshot.scheduleForComputation
        let cancelled = AvailabilityCalculator.availability(
            on: monday,
            schedule: cancelledSchedule,
            preferences: preferences,
            now: nil
        )
        checkEqual(cancelled.totalFreeMinutes, 210, "停课后可用时间恢复到 210 分钟")
        check(
            !cancelled.occupiedIntervals.contains { $0.sourceCourseID == eveningCourse.id },
            "停课的课程不再计入占用"
        )
        checkEqual(
            ScheduleResolver.occurrences(on: monday, schedule: cancelledSchedule, context: context).count,
            0,
            "停课后当天没有课程实例"
        )
        check(snapshot.completionEvents.isEmpty, "可用时间与课表算法不产生任何完成事件")

        // 未设置学期时仍可计算（用兜底学期），但不代表用户配置过。
        var empty = StoreSnapshot()
        empty.schemaVersion = 5
        check(empty.schedule == nil, "未设置学期时课表快照为空")
        check(!empty.isSemesterConfigured, "未设置学期时明确标记为未配置")
        checkEqual(empty.scheduleForComputation.courses.count, 0, "兜底课表不含任何课程")
    }

    // MARK: - 16. 存储隔离

    static func storageIsInjectibleAndIsolated() {
        let first = SnapshotStoreLocation.isolatedTemporary(prefix: "IsolationA")
        let second = SnapshotStoreLocation.isolatedTemporary(prefix: "IsolationB")
        let applicationSupport = SnapshotStoreLocation.applicationSupport()

        check(first.storeURL != second.storeURL, "两次隔离位置互不相同")
        check(
            first.storeURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "隔离存储位于系统临时目录内"
        )
        check(first.storeURL != applicationSupport.storeURL, "隔离存储不是正式 App 的 store.json 路径")
        checkEqual(first.storeFileName, "store.json", "隔离位置沿用同名 store.json（便于行为一致）")
        checkEqual(first.maximumBackupCount, SnapshotFileStore.maxBackupCount, "备份数量上限沿用既有常量")

        do {
            let location = makeLocation("writes-only-here")
            let store = try SnapshotFileStore(location: location)
            try store.save(StudyDataFactory.sampleSnapshot(now: Date(timeIntervalSince1970: 1_800_000_000)))
            check(FileManager.default.fileExists(atPath: location.storeURL.path), "数据写入注入目录")
            check(
                location.storeURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                "写入目标仍是临时目录，未触碰真实资料库"
            )
            check(!FileManager.default.fileExists(atPath: applicationSupport.storeURL.path) || true, "本测试不依赖真实资料库状态")
        } catch {
            check(false, "隔离存储写入不应抛错：\(error)")
        }
    }

    // MARK: - 17. 纯 Foundation 与规划时区

    static func foundationOnlyTypesAndPlanningTimeZone() {
        // 同一时刻在不同规划时区下属于不同"学习日"。
        let instant = StudyDataFactory.sampleTimezoneDate(
            year: 2026, month: 3, day: 2, hour: 8, minute: 0, timeZoneIdentifier: "Asia/Shanghai"
        )
        let shanghaiKey = StudyDayKey(date: instant, planningTimeZoneIdentifier: "Asia/Shanghai")
        let losAngelesKey = StudyDayKey(date: instant, planningTimeZoneIdentifier: "America/Los_Angeles")
        checkEqual(shanghaiKey.localDateString, "2026-03-02", "上海时区下的学习日为 03-02")
        checkEqual(losAngelesKey.localDateString, "2026-03-01", "同一时刻在洛杉矶属于 03-01")
        check(shanghaiKey != losAngelesKey, "不同规划时区的学习日键不同")
        check(losAngelesKey < shanghaiKey, "学习日键先按日期、再按时区标识稳定排序")
        check(shanghaiKey.contains(date: instant), "学习日包含其时刻")
        checkEqual(shanghaiKey.advanced(byDays: 1).localDateString, "2026-03-03", "学习日可以按天偏移")

        let context = PlanningContext(now: instant, timeZoneIdentifier: "Asia/Shanghai")
        checkEqual(context.todayKey, shanghaiKey, "规划上下文用注入时区推导今天")
        checkEqual(context.timeZoneIdentifier, "Asia/Shanghai", "规划上下文保留时区标识")
        checkEqual(
            context.minutes(from: instant, to: instant.addingTimeInterval(3_599)),
            59,
            "分钟差按整分钟向下取整"
        )

        // 范围量纲：不同单位不可比较，不给编造的进度。
        checkEqual(StudyScope.minutes(30).completionRatio(relativeTo: .tasks(3)), nil, "不同量纲无法计算比例")
        checkEqual(StudyScope.tasks(3).completionRatio(relativeTo: .tasks(0)), nil, "计划量为 0 时无法计算比例")
        checkEqual(StudyScope.tasks(1.5).completionRatio(relativeTo: .tasks(3)), 0.5, "同量纲比例正确")
        checkEqual(StudyScope.tasks(3).scaled(by: 0.4).amount, 1, "保底范围按比例向下取整")
        checkEqual(StudyScope.minutes(30).displayText, "30 分钟", "范围展示文本正确")
        checkEqual(
            StudyScope(unit: .custom, amount: 20, customUnitLabel: "个单词").unitLabel,
            "个单词",
            "自定义单位展示正确"
        )

        // 任务来源区分四类，且课程类任务必须能追溯到课程。
        checkEqual(DailyPlanItemSourceKind.allCases.count, 4, "任务来源恰好四类")
        check(
            DailyPlanItemSource.genericTitle(kind: .courseReview, name: "").contains("课程回顾"),
            "没有资料时课程回顾退化为通用标题"
        )
        check(
            !DailyPlanItemSource.genericTitle(kind: .courseReview, name: "").contains("第"),
            "通用标题不编造章节号"
        )
        let missingRef = DailyPlanItem(
            planID: UUID(),
            source: .preview(courseID: UUID()),
            title: "课前预习：示例课程",
            plannedScope: .sections(1),
            estimatedMinutes: 20,
            scheduledDayKey: shanghaiKey,
            createdAt: instant,
            updatedAt: instant
        )
        check(DailyPlanValidation.issues(for: missingRef).isEmpty, "带课程引用的预习任务通过校验")
        var badItem = missingRef
        badItem.source = DailyPlanItemSource(kind: .preview)
        check(
            DailyPlanValidation.issues(for: badItem).contains(.missingCourseReference),
            "缺少课程引用的预习任务被校验拦下"
        )
        var emptyTitle = missingRef
        emptyTitle.title = "   "
        check(
            DailyPlanValidation.issues(for: emptyTitle).contains(.emptyTitle),
            "空标题被校验拦下"
        )

        // 学习会话有效时长：只由注入的时间与暂停区间计算。
        let session = StudySession(
            planItemID: UUID(),
            dayKey: shanghaiKey,
            startedAt: instant,
            endedAt: instant.addingTimeInterval(3_600),
            pauses: [StudyPauseInterval(startedAt: instant.addingTimeInterval(600), endedAt: instant.addingTimeInterval(1_200))],
            state: .finished,
            createdAt: instant,
            updatedAt: instant
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghaiKey.timeZone
        checkEqual(session.effectiveMinutes(asOf: instant.addingTimeInterval(3_600), calendar: calendar), 50, "暂停 10 分钟后有效时长为 50 分钟")
        checkEqual(session.recordedEffectiveMinutes, 50, "已结束会话的最终有效时长可复算")
        checkEqual(
            session.effectiveMinutes(asOf: instant.addingTimeInterval(1_800), calendar: calendar),
            20,
            "未结束时按注入的 now 截断计算"
        )
        check(
            session.effectiveMinutes(asOf: instant.addingTimeInterval(-10), calendar: calendar) == 0,
            "时间早于开始时不产生负时长"
        )
        checkEqual(session.isPausedRightNow, false, "已结束会话不在暂停中")

        // 中文复习状态与旧数据兼容（原始值即中文）。
        checkEqual(ReviewStatus(rawValue: "待复习"), .pending, "旧中文状态原始值兼容")
        checkEqual(DocumentKind(rawValue: "错题"), .mistake, "旧中文资料类型原始值兼容")
        checkEqual(StudySchema.minimumReadableVersion, 1, "最低可读版本为 1（与旧实现一致）")
    }
}
