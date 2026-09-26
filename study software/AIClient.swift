import Foundation

struct AIClient {
    let configuration: AIConnectionConfiguration
    let apiKey: String
    let pricing: AIUsagePricing
    private let adapter: any AIProviderAdapter
    private let transport: AIHTTPTransport
    var maxRetryCount: Int = 3
    var baseRetryDelaySeconds: Double = 2
    var requestTimeoutSeconds: Double = 90
    var answerMaxTokens: Int = 4_000

    init(
        configuration: AIConnectionConfiguration,
        apiKey: String,
        pricing: AIUsagePricing,
        session: URLSession = .shared,
        underlyingTransport: (any AIHTTPTransporting)? = nil
    ) throws {
        try AIConnectionConfiguration.validate(configuration, apiKey: apiKey)
        self.configuration = configuration
        self.apiKey = apiKey
        self.pricing = pricing
        self.adapter = AIProviderAdapters.adapter(for: configuration.protocolKind)
        self.transport = AIHTTPTransport(underlying: underlyingTransport ?? URLSessionAITransport(session: session))
    }

    private let personalContextCharacterLimit = 30_000
    private let studyStateCharacterLimit = 12_000
    private let chatHistoryCharacterLimit = 24_000
    private let chatHistoryMessageLimit = 24
    private let chatSummaryCharacterLimit = 8_000
    private nonisolated static let chatMemoryJSONSchema = """
    {
      "userGoals": ["用户目标、考试目标、时间节点"],
      "learningLevels": ["用户当前水平、薄弱科目、已掌握内容"],
      "preferences": ["学习偏好、回答风格、每日可用时间、工具偏好"],
      "plannedWork": ["已经讨论或确认过的规划、阶段安排、下一步任务"],
      "questionsNotToRepeat": ["用户已经回答过的问题，或 AI 不应反复追问的信息"]
    }
    """
    private nonisolated static let analysisJSONSchema = """
    {
      "summary": "整体概括",
      "knowledgePoints": [{"title":"知识点","subject":"学科或领域","summary":"解释","mastery":0.0}],
      "mistakes": [{"question":"题目或错误内容","correctAnswer":"正确答案","errorReason":"错因","relatedKnowledgeTitles":["知识点"]}],
      "reviewItems": [{"title":"复习任务","dueInDays":1,"relatedKnowledgeTitle":"知识点","relatedMistakeTitle":"题目或错误内容"}]
    }
    """
    private nonisolated static let aiPlanJSONSchema = """
    {
      "isPlan": true,
      "title": "规划标题",
      "summary": "规划摘要",
      "knowledgePoints": [{"title":"知识点","subject":"学科或领域","summary":"说明","mastery":0.4}],
      "mistakes": [{"question":"可选错题或薄弱项","correctAnswer":"待补充","errorReason":"错因或薄弱原因","relatedKnowledgeTitles":["知识点"]}],
      "reviewItems": [{"title":"复习任务","dueInDays":0,"priority":3,"relatedKnowledgeTitle":"知识点","relatedMistakeTitle":"题目或错误内容"}]
    }
    """

    /// Performs the smallest real completion request so the settings screen can
    /// distinguish endpoint, authentication, and model errors before a study task starts.
    func testConnection() async throws {
        _ = try await chat(
            messages: [
                AIMessage(role: "system", content: "你是连接测试助手。"),
                AIMessage(role: "user", content: "只回复 OK。")
            ],
            businessDefaultTokens: AIOutputBudget.connectionTest
        )
    }

    func analyze(content: String, kind: DocumentKind) async throws -> AIAnalysisResult {
        let prompt = """
        你是一个严格的学习错题分析助手。请分析下面的\(kind.rawValue)，只返回 JSON，不要 Markdown。
        JSON 结构必须是：
        \(Self.analysisJSONSchema)
        mastery 表示掌握程度，0 到 1，越低代表越薄弱。dueInDays 建议使用 0、1、3、7、14。

        内容：
        \(content)
        """
        let decoded = try await requestJSON(
            prompt: prompt,
            responseType: AIAnalysisPayload.self,
            repairSchema: Self.analysisJSONSchema,
            businessDefaultTokens: AIOutputBudget.documentAnalysis
        )
        return AIAnalysisResult(payload: decoded.value, usage: decoded.usage)
    }

    func answer(
        question: String,
        context: String,
        studyState: String,
        chatHistory: [ChatHistoryMessage],
        compressedContextSummary: String,
        answerMode: AIAnswerMode
    ) async throws -> AIAnswerResult {
        let personalContext = context.isEmpty ? "没有从用户个人资料中检索到直接相关内容。" : String(context.prefix(personalContextCharacterLimit))
        let studyStateContext = studyState.isEmpty ? "暂未形成学习状态摘要。" : String(studyState.prefix(studyStateCharacterLimit))
        let longTermContext = compressedContextSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "暂无压缩后的长期记忆。"
            : String(compressedContextSummary.prefix(chatSummaryCharacterLimit))
        let historyMessages = makeHistoryMessages(from: chatHistory)

        var messages: [AIMessage] = [
            AIMessage(role: "system", content: """
            你是用户的私人学习搭子，也是这个学习软件里的 AI 工作台。你要自然、简洁、耐心，像真人老师一样承接上下文。

            工作方式：
            1. 优先读懂近期对话，不要把“都 有”“按刚才那个来”等承接语当成新话题。
            2. 下面会给你“长期对话摘要”“学习状态摘要”和“检索到的个人资料”。它们来自本地对话、资料、错题、知识点、复习任务和草稿。
            3. 如果用户要求规划、每日安排、复习任务或备考路径，基于学习状态给出可执行方案：今天做什么、接下来几天怎么排、用什么标准检查完成。
            4. 目前你只能在对话里生成规划建议；不要声称已经自动写入软件数据，除非用户明确使用了已接入的创建/修改功能。
            5. 不要编造用户资料中没有出现的事实。缺信息时先用已有信息推进，再用一两个关键问题补齐。
            6. 使用检索资料中的具体事实时，在相关句子后轻量标注来源，例如 [资料 1]、[资料 2]；不要给常识性建议乱加引用。
            7. 不要机械套用“结论/步骤/建议”等固定模板；复杂任务才分段。回答要有温度，避免像报告或系统提示。

            当前回答模式：\(answerMode.label)。
            - 普通答疑：回答更短，优先解决当前问题；不要展开过长规划。
            - 深度规划：可以更系统地分阶段、排任务、引用个人资料。
            """),
            AIMessage(role: "user", content: """
            长期记忆：
            \(longTermContext)

            学习状态摘要：
            \(studyStateContext)

            检索到的个人资料：
            \(personalContext)
            """)
        ]

        messages.append(contentsOf: historyMessages)
        messages.append(AIMessage(role: "user", content: String(question.prefix(8_000))))

        let result = try await chat(
            messages: messages,
            businessDefaultTokens: min(answerMaxTokens, answerMode.maxAnswerTokens)
        )
        return AIAnswerResult(answer: result.text, usage: result.usage)
    }

    func makeAIPlanDraft(
        question: String,
        answer: String,
        context: String,
        studyState: String,
        planTemplate: AIPlanTemplate
    ) async throws -> AIPlanResult {
        let prompt = """
        你是学习软件的 AI 规划结构化助手。请判断这轮对话是否已经给出了可落地的学习规划、复习方案、每日任务或备考安排。

        只返回 JSON，不要 Markdown。JSON 结构必须是：
        \(Self.aiPlanJSONSchema)

        规则：
        1. 如果这轮回答不是具体规划，或任务少到不足以导入复习计划，请返回：
           {"isPlan": false, "title": "", "summary": "", "knowledgePoints": [], "mistakes": [], "reviewItems": []}
        2. 如果是具体规划，isPlan 必须为 true，reviewItems 至少 1 条。
        3. dueInDays 表示从今天开始几天后到期，今天为 0，明天为 1；优先使用 0、1、2、3、7、14、30。
        4. priority 范围 0 到 5，5 最高；缺少把握时使用 3。
        5. relatedKnowledgeTitle 必须尽量匹配 knowledgePoints 中的 title；没有对应知识点时可以为空。
        6. 如果某个任务是“重做某错题/复盘某薄弱项”，relatedMistakeTitle 必须尽量匹配 mistakes 中的 question；没有对应错题时可以为空。
        7. mistakes 是可选项，只在回答明确提到错题/薄弱项/易错点时填写。
        8. 不要编造用户资料中不存在的背景；可以把回答中已经给出的任务结构化。
        9. 当前计划模板是「\(planTemplate.label)」：\(planTemplate.structureGuidance)
        10. dueInDays 要符合模板范围：\(planTemplate.suggestedDueInDays)
        11. 任务标题不能为空，不要输出“复习”“学习”“刷题”这类过泛标题，要写成可执行动作。
        12. 除「今日计划」外，不要把所有任务都挤在同一个 dueInDays；要按节奏分布。
        13. 30 天计划必须至少覆盖 3 个阶段：基础铺垫、强化推进、复盘/模拟检查。
        14. priority >= 4 的任务必须尽量填写 relatedKnowledgeTitle 或 relatedMistakeTitle。
        15. 不要输出重复任务；同一任务只保留一次，必要时用不同 dueInDays 表示递进。
        16. 如果学习状态中有“已设置考试目标”或“规划硬约束”，必须围绕最近考试目标安排任务：任务 dueInDays 不得超过该目标倒计时，科目覆盖要匹配目标科目。
        17. 每日任务量要匹配用户每日可用时间；时间少时少排高价值任务，时间多时安排学习、练习、复盘和模拟检查的组合。
        18. 靠近考试日期时，优先安排查漏补缺、错题回炉、限时模拟和复盘，不要新增大量泛泛基础学习任务。

        当前学习状态：
        \(String(studyState.prefix(studyStateCharacterLimit)))

        检索到的个人资料：
        \(String(context.prefix(personalContextCharacterLimit)))

        用户问题：
        \(String(question.prefix(4_000)))

        AI 自然语言回答：
        \(String(answer.prefix(12_000)))
        """

        let decoded = try await requestJSON(
            prompt: prompt,
            responseType: AIPlanPayload.self,
            repairSchema: Self.aiPlanJSONSchema,
            businessDefaultTokens: AIOutputBudget.planDraft
        )
        return AIPlanResult(payload: decoded.value, usage: decoded.usage)
    }

    func compressChatContext(
        existingMemory: ChatMemorySummary,
        messages: [ChatHistoryMessage],
        studyState: String
    ) async throws -> AISummaryResult {
        guard !messages.isEmpty else {
            return AISummaryResult(summary: existingMemory.promptText, memory: existingMemory, usage: nil)
        }

        let memoryText = existingMemory.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let studyStateContext = String(studyState.prefix(studyStateCharacterLimit))
        let conversation = messages.map { message in
            let role = message.role == .user ? "用户" : "学习助手"
            let time = message.createdAt.formatted(date: .abbreviated, time: .shortened)
            return "[\(time)] \(role)：\(String(message.content.prefix(1_200)))"
        }.joined(separator: "\n\n")

        let prompt = """
        你是学习软件的长期记忆压缩器。请把已有记忆和新增旧对话合并成结构化记忆，只返回 JSON，不要 Markdown。

        JSON 结构必须是：
        \(Self.chatMemoryJSONSchema)

        规则：
        1. userGoals：保留备考目标、目标学校/考试、时间压力、长期目标。
        2. learningLevels：保留用户当前水平、薄弱科目、已掌握/未掌握内容。
        3. preferences：保留回答偏好、学习节奏、每日可用时间、工具/语言偏好。
        4. plannedWork：保留已经讨论过的计划、阶段安排、确认过或正在推进的任务。
        5. questionsNotToRepeat：保留用户已经回答过、AI 不应重复追问的问题或明确纠正的信息。
        6. 每类最多 12 条，每条不超过 80 字；合并重复项；不要编造事实。
        7. 可以丢弃寒暄、重复表达、没有学习价值的措辞。

        已有长期记忆：
        \(memoryText.isEmpty ? "暂无。" : String(memoryText.prefix(chatSummaryCharacterLimit)))

        当前学习状态摘要：
        \(studyStateContext)

        新增旧对话：
        \(conversation)
        """

        let decoded = try await requestJSON(
            prompt: prompt,
            responseType: ChatMemorySummary.self,
            repairSchema: Self.chatMemoryJSONSchema,
            businessDefaultTokens: AIOutputBudget.memoryCompression
        )

        let memory = decoded.value
        return AISummaryResult(
            summary: String(memory.promptText.prefix(chatSummaryCharacterLimit)),
            memory: memory,
            usage: decoded.usage
        )
    }

    private func makeHistoryMessages(from chatHistory: [ChatHistoryMessage]) -> [AIMessage] {
        let recentMessages = chatHistory.suffix(chatHistoryMessageLimit)
        var remainingCharacters = chatHistoryCharacterLimit
        var boundedMessages: [AIMessage] = []

        for message in recentMessages.reversed() {
            guard remainingCharacters > 0 else { break }
            let content = String(message.content.prefix(remainingCharacters))
            remainingCharacters -= content.count
            boundedMessages.insert(
                AIMessage(role: message.role == .user ? "user" : "assistant", content: content),
                at: 0
            )
        }

        return boundedMessages
    }

    private func requestJSON<T: Decodable>(
        prompt: String,
        responseType: T.Type,
        repairSchema: String = AIClient.analysisJSONSchema,
        businessDefaultTokens: Int = AIOutputBudget.documentAnalysis
    ) async throws -> AIDecodedResult<T> {
        let result = try await chat(messages: [
            AIMessage(role: "system", content: "你只返回可以直接 JSONDecoder 解码的 JSON。"),
            AIMessage(role: "user", content: prompt)
        ], businessDefaultTokens: businessDefaultTokens, structuredOutputRequested: true)
        do {
            return AIDecodedResult(value: try decodeJSON(result.text, responseType: responseType), usage: result.usage)
        } catch {
            let repaired: AICompletion
            do {
                repaired = try await chat(messages: [
                    AIMessage(role: "system", content: "你是 JSON 修复器。只返回一个可以被 JSONDecoder 解码的 JSON 对象，不要 Markdown，不要解释。"),
                    AIMessage(role: "user", content: """
                    请把下面内容修复成符合要求的 JSON。必须保留原意，缺失字段请用合理默认值补齐。

                    JSON 结构：
                    \(repairSchema)

                    原始内容：
                    \(result.text)
                    """)
                ], businessDefaultTokens: businessDefaultTokens, structuredOutputRequested: true)
            } catch let refusal as AIModelRefusal {
                throw AIModelRefusal(
                    message: refusal.message,
                    usage: combineUsage(result.usage, refusal.usage),
                    pricing: refusal.pricing
                )
            }

            do {
                return AIDecodedResult(
                    value: try decodeJSON(repaired.text, responseType: responseType),
                    usage: combineUsage(result.usage, repaired.usage)
                )
            } catch {
                throw AIError.invalidJSON(error.localizedDescription)
            }
        }
    }

    private func chat(
        messages: [AIMessage],
        businessDefaultTokens: Int? = nil,
        structuredOutputRequested: Bool = false
    ) async throws -> AICompletion {
        let request = try adapter.makeRequest(
            configuration: configuration,
            apiKey: apiKey,
            messages: messages,
            options: AIRequestOptions(maxOutputTokens: businessDefaultTokens, structuredOutputRequested: structuredOutputRequested),
            timeout: requestTimeoutSeconds
        )
        var transport = self.transport
        transport.baseRetryDelaySeconds = baseRetryDelaySeconds
        let (data, _) = try await transport.data(for: request, maxRetryCount: maxRetryCount)
        let completion: AICompletion
        do {
            completion = try adapter.parseResponse(data)
        } catch AIError.truncatedResponse {
            if configuration.protocolKind == .anthropicMessages {
                throw AIError.outputBudgetReached(
                    limit: AIOutputBudget.anthropicLimit(configuration: configuration, businessDefault: businessDefaultTokens),
                    settingName: "设置 > 模型连接 > Anthropic 最大输出预算"
                )
            }
            throw AIError.truncatedResponse
        }
        if let refusal = completion.refusal?.trimmingCharacters(in: .whitespacesAndNewlines), !refusal.isEmpty {
            throw AIModelRefusal(message: refusal, usage: completion.usage, pricing: pricing)
        }
        return completion
    }

    private func decodeJSON<T: Decodable>(_ text: String, responseType: T.Type) throws -> T {
        let json = try extractJSONObject(from: text)
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func extractJSONObject(from text: String) throws -> String {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "```")
            .replacingOccurrences(of: "```JSON", with: "```")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("```"), cleaned.hasSuffix("```") {
            let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            let inner = lines.dropFirst().dropLast().joined(separator: "\n")
            return try extractJSONObject(from: inner)
        }

        guard let start = cleaned.firstIndex(of: "{") else {
            throw AIError.invalidJSON("没有找到 JSON 对象开头。")
        }

        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in cleaned[start...].indices {
            let character = cleaned[index]

            if isEscaped {
                isEscaped = false
                continue
            }

            if character == "\\" {
                isEscaped = true
                continue
            }

            if character == "\"" {
                isInsideString.toggle()
                continue
            }

            guard !isInsideString else { continue }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(cleaned[start...index])
                }
            }
        }

        throw AIError.invalidJSON("JSON 对象没有完整闭合。")
    }

    private func combineUsage(_ first: AIUsage?, _ second: AIUsage?) -> AIUsage? {
        guard first != nil || second != nil else { return nil }
        return AIUsage(
            inputTokens: (first?.inputTokens ?? 0) + (second?.inputTokens ?? 0),
            outputTokens: (first?.outputTokens ?? 0) + (second?.outputTokens ?? 0)
        )
    }
}

struct AIAnalysisResult {
    var payload: AIAnalysisPayload
    var usage: AIUsage?
}

struct AIAnswerResult {
    var answer: String
    var usage: AIUsage?
}

struct AISummaryResult {
    var summary: String
    var memory: ChatMemorySummary
    var usage: AIUsage?
}

struct AIPlanResult {
    var payload: AIPlanPayload
    var usage: AIUsage?
}

private struct AIDecodedResult<T> {
    var value: T
    var usage: AIUsage?
}

struct AIUsagePricing {
    var inputPerMillion: Double
    var outputPerMillion: Double
}

struct AIModelRefusal: LocalizedError {
    var message: String
    var usage: AIUsage?
    var pricing: AIUsagePricing

    var errorDescription: String? { "当前 AI 服务拒绝了请求：\(message)" }
}

enum AIClientFactory {
    static func make(settings: AppSettings, apiKey: String, session: URLSession = .shared, underlyingTransport: (any AIHTTPTransporting)? = nil) throws -> AIClient {
        let configuration = AIConnectionConfiguration(settings: settings)
        let pricing = AIUsagePricing(
            inputPerMillion: settings.inputTokenCostPerMillion,
            outputPerMillion: settings.outputTokenCostPerMillion
        )
        return try AIClient(configuration: configuration, apiKey: apiKey, pricing: pricing, session: session, underlyingTransport: underlyingTransport)
    }
}
