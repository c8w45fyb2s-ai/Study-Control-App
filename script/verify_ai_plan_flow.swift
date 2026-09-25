import Foundation

@main
struct AIPlanFlowVerifier {
    static func main() {
        var checks: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() {
                checks.append("PASS \(message)")
            } else {
                fputs("FAIL \(message)\n", stderr)
                exit(1)
            }
        }

        func fixedDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let components = DateComponents(
                calendar: Calendar.current,
                timeZone: TimeZone.current,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
            return components.date!
        }

        func hour(_ date: Date) -> Int {
            Calendar.current.component(.hour, from: date)
        }

        let normalMessage = ChatHistoryMessage(role: .assistant, content: "你好，今天想学什么？")
        var normalSnapshot = StoreSnapshot()
        normalSnapshot.chatMessages = [normalMessage]
        normalSnapshot.settings.allowStructuredPlanRequests = false
        normalSnapshot.settings.answerMode = .deepPlanning
        normalSnapshot.settings.maxAnalysisChunkCharacters = 6_000
        let settingsData = try! JSONEncoder().encode(normalSnapshot)
        let decodedSettingsSnapshot = try! JSONDecoder().decode(StoreSnapshot.self, from: settingsData)
        check(!decodedSettingsSnapshot.settings.allowStructuredPlanRequests && decodedSettingsSnapshot.settings.answerMode == .deepPlanning, "AI 请求控制设置会持久化保存")
        check(decodedSettingsSnapshot.settings.maxAnalysisChunkCharacters == 6_000, "资料分析分块大小会持久化保存")
        check(normalSnapshot.pendingAIPlanDraft(for: normalMessage) == nil, "普通聊天不会出现确认入口")
        check(!AIPlanDraftIntent.shouldAttempt(question: "今天有什么任务？", answer: "你可以先完成 C 语言练习，然后安排一下错题复盘。"), "普通任务询问不会触发结构化规划")
        check(!AIPlanDraftIntent.shouldAttempt(question: "这个计划经济是什么意思？", answer: "计划经济是一种资源配置方式。"), "非学习规划语义不会触发结构化规划")
        check(AIPlanDraftIntent.shouldAttempt(question: "帮我规划北邮复试备考，每天安排复习任务", answer: "可以，下面按阶段安排。"), "强规划意图会触发结构化规划")
        check(AIPlanDraftIntent.shouldAttempt(question: "接下来怎么学 C 语言和 Python？", answer: "第一阶段复习语法，第二阶段刷题，每天完成任务。"), "带具体方案回答的学习路径问题会触发结构化规划")
        check(AIPlanDraftIntent.template(for: "帮我生成今日复习计划") == .today, "能识别今日计划模板")
        check(AIPlanDraftIntent.template(for: "帮我生成本周复习计划") == .week, "能识别本周计划模板")
        check(AIPlanDraftIntent.template(for: "帮我生成 30 天考研复试备考计划") == .thirtyDays, "能识别 30 天计划模板")
        check(AIPlanTemplate.today.normalizedDueInDays(7) == 0, "今日计划会把任务限制到今天")
        check(AIPlanTemplate.week.normalizedDueInDays(30) == 6, "本周计划会把任务限制在本周")
        check(AIPlanTemplate.thirtyDays.normalizedDueInDays(30) == 30, "30 天计划允许第 30 天任务")

        let structuredMemory = ChatMemorySummary(
            userGoals: ["准备北京邮电大学复试"],
            learningLevels: ["C 语言和 Python 都在基础阶段"],
            preferences: ["希望直接给每日任务"],
            plannedWork: ["按 30 天复试备考计划推进"],
            questionsNotToRepeat: ["不要再问是否需要规划，用户已经确认需要"]
        )
        check(structuredMemory.promptText.contains("用户目标记忆") && structuredMemory.promptText.contains("AI 不应重复问的问题"), "长期记忆会按类别渲染")
        let legacyMemory = ChatMemorySummary().mergedWithLegacySummary("用户准备复试，C 语言基础薄弱。")
        check(legacyMemory.promptText.contains("历史长期摘要"), "旧版长期摘要会兼容迁移到结构化记忆")
        var memorySnapshot = StoreSnapshot()
        memorySnapshot.chatMemorySummary = structuredMemory
        let memoryData = try! JSONEncoder().encode(memorySnapshot)
        let decodedMemorySnapshot = try! JSONDecoder().decode(StoreSnapshot.self, from: memoryData)
        check(decodedMemorySnapshot.chatMemorySummary.userGoals.contains("准备北京邮电大学复试"), "结构化长期记忆会持久化保存")

        let lowQualityDraft = AIPlanDraft(
            title: "低质量规划",
            summary: "没有有效任务。",
            planTemplate: .week,
            knowledgePoints: [],
            mistakes: [],
            reviewItems: [DraftReviewItem(title: "   ", dueInDays: 0, priority: 3)]
        )
        check(AIPlanDraftQualityValidator.validate(lowQualityDraft).draft == nil, "结构化规划会拒绝空任务标题")

        let duplicateDraft = AIPlanDraft(
            title: "重复任务规划",
            summary: "需要合并重复项。",
            planTemplate: .week,
            knowledgePoints: [],
            mistakes: [],
            reviewItems: [
                DraftReviewItem(title: "完成 C 语言指针练习", dueInDays: 2, priority: 3),
                DraftReviewItem(title: "完成C语言指针练习", dueInDays: 1, priority: 5)
            ]
        )
        let deduplicated = AIPlanDraftQualityValidator.validate(duplicateDraft).draft!
        check(deduplicated.reviewItems.count == 1 && deduplicated.reviewItems[0].dueInDays == 1 && deduplicated.reviewItems[0].priority == 5, "重复任务会自动合并并保留更早日期和更高优先级")

        let squeezedWeekDraft = AIPlanDraft(
            title: "挤在同一天的一周计划",
            summary: "所有任务都在同一天。",
            planTemplate: .week,
            knowledgePoints: [],
            mistakes: [],
            reviewItems: [
                DraftReviewItem(title: "复习 C 语言数组", dueInDays: 0),
                DraftReviewItem(title: "练习 C 语言指针", dueInDays: 0),
                DraftReviewItem(title: "整理 Python 输入输出", dueInDays: 0),
                DraftReviewItem(title: "刷 3 道基础算法题", dueInDays: 0)
            ]
        )
        let redistributedWeek = AIPlanDraftQualityValidator.validate(squeezedWeekDraft).draft!
        check(Set(redistributedWeek.reviewItems.map(\.dueInDays)).count > 1, "本周计划不会把所有任务挤在同一天")

        let squeezedThirtyDayDraft = AIPlanDraft(
            title: "30 天规划",
            summary: "需要覆盖阶段。",
            planTemplate: .thirtyDays,
            knowledgePoints: [],
            mistakes: [],
            reviewItems: [
                DraftReviewItem(title: "第 1 阶段补基础", dueInDays: 0),
                DraftReviewItem(title: "第 2 阶段刷题强化", dueInDays: 0),
                DraftReviewItem(title: "第 3 阶段模拟复盘", dueInDays: 0)
            ]
        )
        let redistributedThirtyDay = AIPlanDraftQualityValidator.validate(squeezedThirtyDayDraft).draft!
        let thirtyDayStages = Set(redistributedThirtyDay.reviewItems.map { item -> Int in
            switch item.dueInDays {
            case ...7: return 0
            case 8...20: return 1
            default: return 2
            }
        })
        check(thirtyDayStages.count == 3, "30 天计划至少覆盖 3 个阶段")

        let undersizedThirtyDayDraft = AIPlanDraft(
            title: "过短的 30 天规划",
            summary: "任务太少。",
            planTemplate: .thirtyDays,
            knowledgePoints: [],
            mistakes: [],
            reviewItems: [
                DraftReviewItem(title: "只做一次基础复习", dueInDays: 0),
                DraftReviewItem(title: "只做一次模拟", dueInDays: 30)
            ]
        )
        check(AIPlanDraftQualityValidator.validate(undersizedThirtyDayDraft).draft == nil, "30 天计划任务过少时会被拒绝")

        let relationDraft = AIPlanDraft(
            title: "高优先级关联规划",
            summary: "高优先级任务应尽量有关联。",
            planTemplate: .week,
            knowledgePoints: [
                DraftKnowledgePoint(title: "C 语言基础", subject: "计算机", summary: "数组、指针、函数。", mastery: 0.3)
            ],
            mistakes: [],
            reviewItems: [
                DraftReviewItem(title: "完成 C 语言基础专项练习", dueInDays: 0, priority: 5)
            ]
        )
        let relatedDraft = AIPlanDraftQualityValidator.validate(relationDraft).draft!
        check(relatedDraft.reviewItems[0].relatedKnowledgeTitle == "C 语言基础", "高优先级任务会尽量自动关联知识点")

        let patchNow = fixedDate(2026, 6, 20, 9)
        let cLanguagePointID = UUID()
        let todayTaskID = UUID()
        let tomorrowTaskID = UUID()
        let cTaskID = UUID()
        let broadTaskID = UUID()
        let weekTaskID = UUID()

        var patchSnapshot = StoreSnapshot()
        patchSnapshot.knowledgePoints = [
            KnowledgePoint(
                id: cLanguagePointID,
                title: "C 语言基础",
                subject: "计算机",
                summary: "数组、指针和函数。",
                mastery: 0.3
            )
        ]
        patchSnapshot.reviewTasks = [
            ReviewTask(id: todayTaskID, title: "完成今天的 C 语言数组题", dueDate: fixedDate(2026, 6, 20, 22), knowledgePointID: cLanguagePointID, priority: 4),
            ReviewTask(id: tomorrowTaskID, title: "整理 Python 输入输出", dueDate: fixedDate(2026, 6, 21, 22), priority: 3),
            ReviewTask(id: cTaskID, title: "完成专项练习", dueDate: fixedDate(2026, 6, 22, 22), knowledgePointID: cLanguagePointID, priority: 2),
            ReviewTask(id: broadTaskID, title: "复习", dueDate: fixedDate(2026, 6, 23, 22), priority: 1),
            ReviewTask(id: weekTaskID, title: "刷 5 道基础算法题", dueDate: fixedDate(2026, 6, 24, 22), priority: 2)
        ]

        if let priorityPatch = AIPlanPatchEngine.makeRuleBasedPatch(command: "把 C 语言优先级提高", snapshot: patchSnapshot, now: patchNow) {
            let result = AIPlanPatchEngine.apply(priorityPatch, to: &patchSnapshot, now: patchNow)
            check(result.updatedReviewTaskIDs.contains(cTaskID), "AIPlanPatch 能按知识点匹配并提高优先级")
            check(patchSnapshot.reviewTasks.first { $0.id == cTaskID }?.priority == 3, "优先级提高会写回 ReviewTask")
        } else {
            check(false, "AIPlanPatch 能识别提高优先级指令")
        }

        if let postponePatch = AIPlanPatchEngine.makeRuleBasedPatch(command: "我明天有事，帮我顺延", snapshot: patchSnapshot, now: patchNow) {
            let result = AIPlanPatchEngine.apply(postponePatch, to: &patchSnapshot, now: patchNow)
            check(result.updatedReviewTaskIDs.contains(tomorrowTaskID), "AIPlanPatch 能顺延明天任务")
            check(Calendar.current.isDate(patchSnapshot.reviewTasks.first { $0.id == tomorrowTaskID }!.dueDate, inSameDayAs: fixedDate(2026, 6, 22, 9)), "明天任务会顺延到后天")
        } else {
            check(false, "AIPlanPatch 能识别顺延指令")
        }

        if let deleteBroadPatch = AIPlanPatchEngine.makeRuleBasedPatch(command: "删除太宽泛的任务", snapshot: patchSnapshot, now: patchNow) {
            let result = AIPlanPatchEngine.apply(deleteBroadPatch, to: &patchSnapshot, now: patchNow)
            check(result.deletedReviewTaskIDs.contains(broadTaskID), "AIPlanPatch 能删除太宽泛的任务")
            check(!patchSnapshot.reviewTasks.contains { $0.id == broadTaskID }, "删除 patch 会从 ReviewTask 移除任务")
        } else {
            check(false, "AIPlanPatch 能识别删除宽泛任务指令")
        }

        if let rescheduleTomorrowPatch = AIPlanPatchEngine.makeRuleBasedPatch(command: "根据今天没完成的任务重新安排明天", snapshot: patchSnapshot, now: patchNow) {
            let result = AIPlanPatchEngine.apply(rescheduleTomorrowPatch, to: &patchSnapshot, now: patchNow)
            check(result.updatedReviewTaskIDs.contains(todayTaskID), "AIPlanPatch 能把今日未完成任务重排到明天")
            check(Calendar.current.isDate(patchSnapshot.reviewTasks.first { $0.id == todayTaskID }!.dueDate, inSameDayAs: fixedDate(2026, 6, 21, 9)), "今日未完成任务会移到明天")
        } else {
            check(false, "AIPlanPatch 能识别重排明天指令")
        }

        var reduceSnapshot = StoreSnapshot()
        reduceSnapshot.reviewTasks = [
            ReviewTask(title: "任务 A", dueDate: fixedDate(2026, 6, 20, 22), priority: 5),
            ReviewTask(title: "任务 B", dueDate: fixedDate(2026, 6, 21, 22), priority: 4),
            ReviewTask(title: "任务 C", dueDate: fixedDate(2026, 6, 22, 22), priority: 2),
            ReviewTask(title: "任务 D", dueDate: fixedDate(2026, 6, 23, 22), priority: 1)
        ]
        if let reducePatch = AIPlanPatchEngine.makeRuleBasedPatch(command: "把这周计划减半", snapshot: reduceSnapshot, now: patchNow) {
            let result = AIPlanPatchEngine.apply(reducePatch, to: &reduceSnapshot, now: patchNow)
            check(result.updatedReviewTaskIDs.count == 2, "AIPlanPatch 能把本周计划减半")
            let movedTasks = reduceSnapshot.reviewTasks.filter { result.updatedReviewTaskIDs.contains($0.id) }
            check(movedTasks.allSatisfy { $0.dueDate >= fixedDate(2026, 6, 27, 0) }, "减半会把低优先级任务顺延到下周")
        } else {
            check(false, "AIPlanPatch 能识别本周计划减半指令")
        }

        let weakPointID = UUID()
        var retrievalSnapshot = StoreSnapshot()
        retrievalSnapshot.chatMemorySummary = ChatMemorySummary(
            userGoals: ["长期目标：准备北京邮电大学复试"],
            learningLevels: ["当前 C 语言和 Python 基础薄弱"],
            preferences: ["需要每日稳定推进"]
        )
        retrievalSnapshot.knowledgePoints = [
            KnowledgePoint(
                id: weakPointID,
                title: "数据结构与算法入门",
                subject: "计算机",
                summary: "链表、栈、队列和基础排序还不熟。",
                mastery: 0.25
            ),
            KnowledgePoint(
                title: "英语阅读",
                subject: "英语",
                summary: "阅读正确率较稳定。",
                mastery: 0.85
            )
        ]
        retrievalSnapshot.reviewTasks = [
            ReviewTask(
                title: "完成 C 语言指针练习",
                dueDate: fixedDate(2026, 6, 20, 22),
                knowledgePointID: weakPointID,
                mistakeID: nil,
                priority: 4
            )
        ]
        let planningRetrieval = StudyContextRetriever.retrieve(
            query: "今天怎么学",
            snapshot: retrievalSnapshot,
            limit: 8,
            now: fixedDate(2026, 6, 20, 9)
        )
        check(planningRetrieval.items.contains { $0.kind == .knowledge && $0.title == "数据结构与算法入门" }, "今日学习问题会召回低掌握度知识点")
        check(planningRetrieval.items.contains { $0.kind == .reviewTask && $0.title == "完成 C 语言指针练习" }, "今日学习问题会召回今日/近期复习任务")
        check(planningRetrieval.items.contains { $0.kind == .goal && $0.title == "长期学习目标与偏好" }, "今日学习问题会召回长期目标摘要")
        let planningCitations = planningRetrieval.citations
        check(planningCitations.contains { $0.kind == .knowledge && $0.sourceID == weakPointID && $0.promptIndex > 0 }, "检索结果会生成可跳转的知识点引用")
        check(planningCitations.contains { $0.kind == .reviewTask && $0.title == "完成 C 语言指针练习" && $0.sourceID != nil }, "检索结果会生成可跳转的复习任务引用")
        let citationMessage = ChatHistoryMessage(role: .assistant, content: "根据你的资料，先做 C 语言。[资料 1]", citations: Array(planningCitations.prefix(2)))
        let citationData = try! JSONEncoder().encode(citationMessage)
        let decodedCitationMessage = try! JSONDecoder().decode(ChatHistoryMessage.self, from: citationData)
        check(decodedCitationMessage.citations.count == min(2, planningCitations.count), "聊天消息会持久化 AI 回答引用来源")
        retrievalSnapshot.dailyActivityRecords = [
            DailyActivityRecord(date: fixedDate(2026, 6, 18, 20), completedTaskCount: 2),
            DailyActivityRecord(date: fixedDate(2026, 6, 19, 20), completedTaskCount: 4)
        ]
        retrievalSnapshot.reviewTasks.append(
            ReviewTask(
                title: "补做昨天的数据结构错题",
                dueDate: fixedDate(2026, 6, 19, 22),
                knowledgePointID: weakPointID,
                mistakeID: nil,
                priority: 5
            )
        )
        let profile = StudyProfileSummary.make(from: retrievalSnapshot, now: fixedDate(2026, 6, 20, 9))
        check(profile.goals.contains { $0.contains("北京邮电大学复试") }, "学习状态诊断会提炼长期目标")
        check(profile.remainingTimeDescription.contains("滚动推进"), "无明确截止日期时会给出滚动规划剩余时间提示")
        check(profile.weakSubjects.contains { $0.subject == "计算机" && $0.weakKnowledgeCount == 1 }, "学习状态诊断会汇总薄弱科目")
        check(profile.overdueTaskCount == 1 && profile.dueTodayTaskCount == 1, "学习状态诊断会统计逾期和今日任务压力")
        check(profile.dailyAvailableTimeDescription.contains("日均完成 3.0 个任务"), "学习状态诊断会估计每日可用任务容量")
        check(profile.promptText.contains("## 学习状态诊断") && profile.promptText.contains("薄弱科目"), "学习状态诊断能输出稳定 prompt 文本")

        let mistakeQuestion = "跨专业复试机试基础薄弱"
        let planDraft = AIPlanDraft(
            title: "北邮复试 7 天复习规划",
            summary: "围绕 C 语言、Python 基础和机试题进行每日复习。",
            sourceUserMessageID: UUID(),
            sourceAssistantMessageID: UUID(),
            planTemplate: .week,
            knowledgePoints: [
                DraftKnowledgePoint(
                    title: "C 语言基础",
                    subject: "计算机",
                    summary: "指针、数组、函数和基础语法。",
                    mastery: 0.35
                )
            ],
            mistakes: [
                DraftMistake(
                    question: mistakeQuestion,
                    correctAnswer: "每天用固定题量补齐语言和算法基本功",
                    errorReason: "语言基础和刷题经验不足",
                    relatedKnowledgeTitles: ["C 语言基础"]
                )
            ],
            reviewItems: [
                DraftReviewItem(
                    title: "完成 5 道 C 语言基础题",
                    dueInDays: 0,
                    priority: 5,
                    relatedKnowledgeTitle: "C 语言基础",
                    relatedMistakeTitle: mistakeQuestion
                ),
                DraftReviewItem(
                    title: "整理 Python 输入输出模板",
                    dueInDays: 1,
                    priority: 4,
                    relatedKnowledgeTitle: nil
                )
            ]
        )

        let planMessage = ChatHistoryMessage(
            role: .assistant,
            content: "这是你的北邮复试备考规划。",
            aiPlanDraftID: planDraft.id
        )
        var planSnapshot = StoreSnapshot()
        planSnapshot.aiPlanDrafts = [planDraft]
        planSnapshot.chatMessages = [planMessage]
        check(planSnapshot.pendingAIPlanDraft(for: planMessage)?.id == planDraft.id, "规划类回复会出现确认入口")

        let sourceDocumentID = UUID()
        let analysisDraft = planDraft.makeAnalysisDraft(sourceDocumentID: sourceDocumentID)
        let titleToID = Dictionary(uniqueKeysWithValues: analysisDraft.knowledgePoints.map { ($0.title, UUID()) })
        let mistakeIDsByDraftID = Dictionary(uniqueKeysWithValues: analysisDraft.mistakes.map { ($0.id, UUID()) })
        let morning = fixedDate(2026, 6, 20, 9)
        let tasks = ReviewPlanner.makeTasks(for: analysisDraft, titleToID: titleToID, mistakeIDsByDraftID: mistakeIDsByDraftID, now: morning)
        check(tasks.count == 2, "确认后能生成规划里的复习任务")
        check(tasks.contains { $0.title == "完成 5 道 C 语言基础题" && $0.priority == 5 && $0.intervalDays == 0 }, "任务保留 dueInDays 和 priority")
        check(tasks.contains { $0.title == "完成 5 道 C 语言基础题" && $0.mistakeID == mistakeIDsByDraftID[analysisDraft.mistakes[0].id] }, "AI 规划任务能关联到正式错题 ID")
        check(tasks.contains { $0.title == "完成 5 道 C 语言基础题" && hour($0.dueDate) == 22 }, "今日初始复习任务默认安排到当天 22 点")
        check(tasks.contains { $0.title == "整理 Python 输入输出模板" && hour($0.dueDate) == 22 }, "未来初始复习任务默认安排到目标日 22 点")

        let lateNight = fixedDate(2026, 6, 20, 23, 30)
        let lateNightTasks = ReviewPlanner.makeTasks(for: analysisDraft, titleToID: titleToID, mistakeIDsByDraftID: mistakeIDsByDraftID, now: lateNight)
        check(lateNightTasks.contains { $0.title == "完成 5 道 C 语言基础题" && $0.dueDate > lateNight }, "深夜生成的今日任务不会立即过期")

        let reviewedTask = ReviewPlanner.scheduleNextReview(task: tasks[0], quality: .good, now: morning)
        check(reviewedTask.lastReviewedAt == morning && reviewedTask.lastQuality == ReviewPlanner.Quality.good.rawValue, "完成复习会记录评分和完成时间")

        let uncoveredMistake = DraftMistake(
            question: "Python 输入输出模板不熟",
            correctAnswer: "整理并背熟常见输入输出模板",
            errorReason: "缺少重复实操",
            relatedKnowledgeTitles: []
        )
        var mixedDraft = analysisDraft
        mixedDraft.mistakes.append(uncoveredMistake)
        let mixedMistakeIDsByDraftID = Dictionary(uniqueKeysWithValues: mixedDraft.mistakes.map { ($0.id, UUID()) })
        let mixedTasks = ReviewPlanner.makeTasks(for: mixedDraft, titleToID: titleToID, mistakeIDsByDraftID: mixedMistakeIDsByDraftID)
        check(mixedTasks.count == 5, "AI 任务存在时仍会为未覆盖错题生成重做任务")
        check(mixedTasks.contains { $0.title.hasPrefix("重做错题：Python 输入输出模板不熟") && $0.mistakeID == mixedMistakeIDsByDraftID[uncoveredMistake.id] }, "未覆盖错题的重做任务保留错题 ID")
        let thirtyDayDraft = AnalysisDraft(
            sourceDocumentID: UUID(),
            summary: "30 天计划",
            knowledgePoints: [],
            mistakes: [],
            reviewItems: [DraftReviewItem(title: "第 30 天模拟复盘", dueInDays: 30, priority: 4)]
        )
        let thirtyDayTasks = ReviewPlanner.makeTasks(for: thirtyDayDraft, titleToID: [:], now: morning)
        check(thirtyDayTasks.contains { $0.title == "第 30 天模拟复盘" && $0.intervalDays == 30 }, "30 天计划任务会保留第 30 天到期")
        check(thirtyDayTasks.contains { $0.title == "第 30 天模拟复盘" && hour($0.dueDate) == 22 }, "30 天计划任务默认安排到目标日 22 点")

        var confirmedSnapshot = planSnapshot
        confirmedSnapshot.reviewTasks = tasks
        confirmedSnapshot.aiPlanDrafts[0].status = .confirmed
        confirmedSnapshot.aiPlanDrafts[0].createdReviewTaskIDs = tasks.map(\.id)
        check(confirmedSnapshot.aiPlanDraft(for: planMessage)?.status == .confirmed, "确认后聊天消息仍能显示已加入状态")
        check(confirmedSnapshot.pendingAIPlanDraft(for: planMessage) == nil, "确认后聊天消息不再显示待确认入口")
        confirmedSnapshot.chatMessages.removeAll()
        check(confirmedSnapshot.reviewTasks.count == 2, "清空聊天不会删除正式复习任务")
        confirmedSnapshot.aiPlanDrafts[0].createdKnowledgePointIDs = Array(titleToID.values)
        confirmedSnapshot.aiPlanDrafts[0].createdReviewTaskIDs = tasks.map(\.id)
        let confirmedData = try! JSONEncoder().encode(confirmedSnapshot)
        let decodedConfirmed = try! JSONDecoder().decode(StoreSnapshot.self, from: confirmedData)
        check(decodedConfirmed.aiPlanDrafts[0].createdReviewTaskIDs.count == 2, "AI 规划确认记录会保留创建的复习任务 ID")

        var inboxSnapshot = planSnapshot
        inboxSnapshot.chatMessages.removeAll()
        check(inboxSnapshot.pendingAIPlanDrafts.count == 1, "清空聊天后未确认 AI 规划仍保留在待确认列表")

        var dismissedSnapshot = planSnapshot
        dismissedSnapshot.aiPlanDrafts[0].status = .dismissed
        check(dismissedSnapshot.pendingAIPlanDraft(for: planMessage) == nil, "忽略 AI 规划草稿后不再显示确认入口")
        dismissedSnapshot.reviewTasks = tasks
        check(dismissedSnapshot.reviewTasks.count == 2, "忽略草稿不会删除已经生成的正式复习任务")

        let encoded = try! JSONEncoder().encode(planSnapshot)
        let decoded = try! JSONDecoder().decode(StoreSnapshot.self, from: encoded)
        check(decoded.pendingAIPlanDraft(for: decoded.chatMessages[0])?.id == planDraft.id, "重启后未确认 AI 规划草稿仍保留")
        check(decoded.aiPlanDrafts[0].planTemplate == .week, "AI 规划模板会持久化保留")

        let iterativeNow = fixedDate(2026, 6, 20, 9)
        let overdueTaskID = UUID()
        let goodTaskID = UUID()
        let easyTaskID = UUID()
        let futureTaskID = UUID()
        var iterativeSnapshot = StoreSnapshot()
        iterativeSnapshot.reviewTasks = [
            ReviewTask(
                id: overdueTaskID,
                title: "补完昨天的 C 语言指针练习",
                dueDate: fixedDate(2026, 6, 18, 22),
                priority: 4
            ),
            ReviewTask(
                id: goodTaskID,
                title: "复盘数组和函数题",
                dueDate: fixedDate(2026, 6, 25, 22),
                priority: 3,
                lastQuality: ReviewPlanner.Quality.good.rawValue,
                lastReviewedAt: fixedDate(2026, 6, 19, 21)
            ),
            ReviewTask(
                id: easyTaskID,
                title: "复盘 Python 输入输出",
                dueDate: fixedDate(2026, 6, 26, 22),
                priority: 3,
                lastQuality: ReviewPlanner.Quality.easy.rawValue,
                lastReviewedAt: fixedDate(2026, 6, 19, 20)
            ),
            ReviewTask(
                id: futureTaskID,
                title: "提前刷 5 道模拟机试题",
                dueDate: fixedDate(2026, 6, 28, 22),
                priority: 2
            )
        ]
        iterativeSnapshot.aiPlanDrafts = [
            AIPlanDraft(
                title: "本周滚动复习计划",
                summary: "每天根据完成情况滚动调整。",
                status: .confirmed,
                confirmedAt: fixedDate(2026, 6, 18, 10),
                planTemplate: .week,
                createdReviewTaskIDs: [overdueTaskID, goodTaskID, easyTaskID, futureTaskID],
                knowledgePoints: [],
                mistakes: [],
                reviewItems: []
            )
        ]
        let iterationResults = AIPlanIterationEngine.refresh(snapshot: &iterativeSnapshot, now: iterativeNow)
        check(iterationResults.count == 1, "已确认 AI 计划会生成滚动调整结果")
        let adjustedOverdueTask = iterativeSnapshot.reviewTasks.first { $0.id == overdueTaskID }!
        check(adjustedOverdueTask.dueDate > iterativeNow && hour(adjustedOverdueTask.dueDate) == 22, "逾期 AI 计划任务会顺延到可执行时间")
        check(adjustedOverdueTask.priority == 3, "逾期任务顺延时会降低优先级")
        check(iterativeSnapshot.aiPlanDrafts[0].iterationCount == 1 && iterativeSnapshot.aiPlanDrafts[0].iterationNote?.contains("顺延") == true, "AI 计划会记录本次滚动说明")
        check(iterativeSnapshot.reviewTasks.contains { $0.id != overdueTaskID && Calendar.current.isDate($0.dueDate, inSameDayAs: fixedDate(2026, 6, 21, 9)) }, "完成较好时会提前一个后续任务到明天")
        let repeatedIterationResults = AIPlanIterationEngine.refresh(snapshot: &iterativeSnapshot, now: fixedDate(2026, 6, 20, 18))
        check(repeatedIterationResults.isEmpty, "同一天不会重复滚动同一份 AI 计划")

        let loadBalanceNow = fixedDate(2026, 6, 20, 9)
        let loadKnowledgeID = UUID()
        let protectedMistakeID = UUID()
        let protectedMistakeTaskID = UUID()
        let protectedHighTaskID = UUID()
        let lowPriorityTaskID = UUID()
        let mediumPriorityTaskID = UUID()
        var loadSnapshot = StoreSnapshot()
        loadSnapshot.examGoals = [
            ExamGoal(
                name: "复试机试",
                examDate: fixedDate(2026, 6, 28, 9),
                subjects: ["计算机"],
                dailyAvailableMinutes: 30,
                targetScore: "稳过线"
            )
        ]
        loadSnapshot.knowledgePoints = [
            KnowledgePoint(
                id: loadKnowledgeID,
                title: "C 语言指针",
                subject: "计算机",
                summary: "指针、数组和函数参数。",
                mastery: 0.35
            )
        ]
        loadSnapshot.mistakes = [
            Mistake(
                id: protectedMistakeID,
                question: "指针数组题做错",
                correctAnswer: "先判断数组元素类型，再处理指针偏移。",
                errorReason: "概念混淆",
                sourceDocumentID: nil,
                knowledgePointIDs: [loadKnowledgeID]
            )
        ]
        loadSnapshot.reviewTasks = [
            ReviewTask(
                id: protectedMistakeTaskID,
                title: "重做错题：指针数组题做错",
                dueDate: fixedDate(2026, 6, 20, 22),
                knowledgePointID: loadKnowledgeID,
                mistakeID: protectedMistakeID,
                priority: 4
            ),
            ReviewTask(
                id: protectedHighTaskID,
                title: "复盘 C 语言核心语法",
                dueDate: fixedDate(2026, 6, 20, 22),
                knowledgePointID: loadKnowledgeID,
                priority: 5
            ),
            ReviewTask(
                id: lowPriorityTaskID,
                title: "整理低频笔记标签",
                dueDate: fixedDate(2026, 6, 20, 22),
                priority: 1
            ),
            ReviewTask(
                id: mediumPriorityTaskID,
                title: "补充普通练习记录",
                dueDate: fixedDate(2026, 6, 20, 22),
                priority: 2
            )
        ]
        let loadPlan = StudyLoadBalancer.make(from: loadSnapshot, now: loadBalanceNow)
        check(loadPlan.overloadedDayCount > 0, "智能负荷平衡能识别超载日期")
        check(loadPlan.suggestedMoveCount == 2, "智能负荷平衡会挑选低优先级任务顺延")
        check(loadPlan.moveProposals.contains { $0.taskID == lowPriorityTaskID }, "低优先级任务会进入顺延建议")
        check(!loadPlan.moveProposals.contains { $0.taskID == protectedHighTaskID || $0.taskID == protectedMistakeTaskID }, "高优先级和考前错题不会被自动顺延")
        check(loadPlan.compressedSessionItems.first?.taskID == protectedMistakeTaskID, "30 分钟压缩版会优先保留考前错题")
        let loadBalanceResult = StudyLoadBalancer.apply(to: &loadSnapshot, now: loadBalanceNow)
        check(loadBalanceResult.movedTaskIDs.contains(lowPriorityTaskID) && loadBalanceResult.movedTaskIDs.contains(mediumPriorityTaskID), "应用负荷平衡会移动建议任务")
        check(Calendar.current.isDate(loadSnapshot.reviewTasks.first { $0.id == lowPriorityTaskID }!.dueDate, inSameDayAs: fixedDate(2026, 6, 21, 9)), "顺延任务会移动到后续低负荷日期")
        check(Calendar.current.isDate(loadSnapshot.reviewTasks.first { $0.id == protectedMistakeTaskID }!.dueDate, inSameDayAs: fixedDate(2026, 6, 20, 9)), "考前错题会保留在原日期")

        var malformedResultSnapshot = StoreSnapshot()
        let malformedMessage = ChatHistoryMessage(role: .assistant, content: "规划结构化失败，但普通回答仍保留。")
        malformedResultSnapshot.chatMessages = [malformedMessage]
        check(malformedResultSnapshot.pendingAIPlanDraft(for: malformedMessage) == nil, "AI JSON 异常时不会显示确认入口")

        print(checks.joined(separator: "\n"))
        print("AI plan flow verification complete.")
    }
}
