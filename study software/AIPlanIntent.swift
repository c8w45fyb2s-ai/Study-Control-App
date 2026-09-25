import Foundation

enum AIPlanTemplate: String, Codable {
    case today
    case week
    case thirtyDays
    case general

    var label: String {
        switch self {
        case .today: return "今日计划"
        case .week: return "本周计划"
        case .thirtyDays: return "30 天计划"
        case .general: return "通用计划"
        }
    }

    var maxDueInDays: Int {
        switch self {
        case .today: return 0
        case .week: return 6
        case .thirtyDays: return 30
        case .general: return 365
        }
    }

    var suggestedDueInDays: String {
        switch self {
        case .today: return "只使用 0；所有任务都应是今天可执行的小任务。"
        case .week: return "使用 0 到 6；覆盖今天、本周中段和周末，不要超过 6。"
        case .thirtyDays: return "使用 0 到 30；按第 1 周、第 2 周、第 3 周、第 4 周和第 30 天附近分布。"
        case .general: return "优先使用 0、1、2、3、7、14、30；长期规划可使用更远日期。"
        }
    }

    var structureGuidance: String {
        switch self {
        case .today:
            return "输出 3 到 6 个任务，粒度要小到今天能完成，避免阶段性空话。"
        case .week:
            return "输出 5 到 9 个任务，覆盖本周每天或关键日期，适合一周复习推进。"
        case .thirtyDays:
            return "输出 10 到 18 个任务，按周/阶段安排，兼顾基础、强化、复盘和阶段检查，适合考研复试等中长期备考。"
        case .general:
            return "根据用户问题选择合适粒度；如果是考研复试、备考冲刺等长期目标，优先按 30 天计划组织。"
        }
    }

    func normalizedDueInDays(_ days: Int) -> Int {
        min(max(days, 0), maxDueInDays)
    }
}

enum AIPlanDraftIntent {
    static func shouldAttempt(question: String, answer: String) -> Bool {
        let normalizedQuestion = normalize(question)
        guard !normalizedQuestion.isEmpty else { return false }

        let directIntentPhrases = [
            "帮我规划", "帮忙规划", "替我规划", "给我规划", "规划一下",
            "帮我制定", "帮忙制定", "给我制定", "制定计划", "制定规划",
            "生成计划", "生成规划", "做个计划", "做一份计划", "列个计划",
            "安排复习", "复习安排", "复习计划", "制定复习方案", "复习方案",
            "每日任务", "每天任务", "每日复习", "每天复习",
            "学习计划", "学习规划", "学习路径", "备考计划", "备考规划",
            "备考路线", "今日计划", "今天计划", "本周计划", "一周计划",
            "30天计划", "三十天计划", "周计划", "月计划", "日计划", "冲刺计划",
            "接下来怎么学", "后面怎么学", "下一步怎么学",
            "make a plan", "study plan", "review plan", "revision plan",
            "generate a plan", "create a plan", "make a schedule",
            "daily tasks", "study schedule", "roadmap"
        ]

        if directIntentPhrases.contains(where: { normalizedQuestion.contains(normalize($0)) }) {
            return true
        }

        var score = 0
        let asksForHelp = containsAny(normalizedQuestion, ["帮我", "帮忙", "替我", "给我", "为我", "想要", "需要", "求", "please"])
        let creationVerb = containsAny(normalizedQuestion, ["制定", "生成", "设计", "安排", "规划", "列", "做", "create", "make", "build", "generate"])
        let planningObject = containsAny(normalizedQuestion, ["规划", "计划", "方案", "安排", "路线", "路径", "时间表", "日程", "进度表", "任务", "plan", "schedule", "roadmap"])
        let studyDomain = containsAny(normalizedQuestion, ["复习", "学习", "备考", "刷题", "考试", "考研", "机试", "课程", "知识点", "review", "study", "exam"])
        let cadence = containsAny(normalizedQuestion, ["每日", "每天", "每周", "周计划", "月计划", "阶段", "今天", "明天", "daily", "weekly", "phase"])

        if asksForHelp && planningObject { score += 3 }
        if creationVerb && planningObject { score += 3 }
        if studyDomain && planningObject { score += 2 }
        if studyDomain && cadence { score += 2 }
        if asksForHelp && studyDomain && creationVerb { score += 1 }

        if looksLikeOrdinaryQuestion(normalizedQuestion) && score < 5 {
            return false
        }

        if score >= 5 {
            return true
        }

        return score >= 3 && answerLooksLikeConcretePlan(answer)
    }

    static func template(for question: String, answer: String = "") -> AIPlanTemplate {
        let text = normalize(question + "\n" + answer)

        if containsAny(text, [
            "30天", "三十天", "一个月", "1个月", "月计划", "30-day", "30day",
            "longterm", "long-term", "长期规划", "长期计划", "阶段规划",
            "考研复试规划", "复试备考规划"
        ]) {
            return .thirtyDays
        }

        if containsAny(text, ["本周", "这周", "一周", "7天", "七天", "周计划", "weekly", "weekplan"]) {
            return .week
        }

        if containsAny(text, ["今日计划", "今天计划", "今天复习", "今日复习", "今日任务", "今天任务", "日计划", "today", "dailyplan"]) {
            return .today
        }

        if containsAny(text, ["复试", "考研", "备考冲刺", "冲刺计划"]) {
            return .thirtyDays
        }

        return .general
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    private static func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains { text.contains($0) }
    }

    private static func looksLikeOrdinaryQuestion(_ text: String) -> Bool {
        containsAny(text, [
            "是什么", "为什么", "怎么理解", "解释一下", "讲一下", "区别",
            "报错", "代码", "语法", "什么意思", "有没有", "是否", "能不能"
        ])
    }

    private static func answerLooksLikeConcretePlan(_ answer: String) -> Bool {
        let normalizedAnswer = normalize(answer)
        let hasPlanStructure = containsAny(normalizedAnswer, ["第一阶段", "第二阶段", "第1阶段", "第2阶段", "今天", "明天", "每日", "每天", "周计划", "任务"])
        let hasStudyAction = containsAny(normalizedAnswer, ["复习", "学习", "刷题", "完成", "整理", "背诵", "练习", "掌握"])
        return hasPlanStructure && hasStudyAction
    }
}
