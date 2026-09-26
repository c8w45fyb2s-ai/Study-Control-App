import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("AI protocol verification failed: \(message)") }
}

private func config(
    _ kind: AIProtocolKind,
    baseURL: String,
    model: String = "test-model",
    auth: AIAuthMode = .providerKey,
    tokenParameter: AIChatTokenParameter = .maxTokens,
    outputLimit: Int? = 128,
    temperature: Double? = nil,
    jsonMode: Bool = false
) -> AIConnectionConfiguration {
    AIConnectionConfiguration(
        baseURL: baseURL,
        model: model,
        protocolKind: kind,
        authMode: auth,
        chatTokenParameter: tokenParameter,
        anthropicOutputTokenLimit: outputLimit,
        temperature: temperature,
        useNativeJSONMode: jsonMode
    )
}

private func body(_ request: URLRequest) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
}

private func httpResponse(_ request: URLRequest, status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

private func response(_ request: URLRequest, _ json: String, status: Int = 200, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
    (Data(json.utf8), httpResponse(request, status: status, headers: headers))
}

private actor QueueMockTransport: AIHTTPTransporting {
    private var queued: [(status: Int, headers: [String: String], body: String)]
    private var requestLog: [URLRequest] = []

    init(_ queued: [(Int, [String: String], String)]) { self.queued = queued.map { ($0.0, $0.1, $0.2) } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestLog.append(request)
        guard !queued.isEmpty else { throw URLError(.badServerResponse) }
        let next = queued.removeFirst()
        return response(request, next.body, status: next.status, headers: next.headers)
    }

    func count() -> Int { requestLog.count }
    func requests() -> [URLRequest] { requestLog }
}

@main
private struct VerifyAIProtocols {
    static func main() async throws {
        try verifyOpenAIChatCompletions()
        try verifyResponses()
        try verifyAnthropic()
        try await verifyAnthropicOutputBudgets()
        try verifyAnthropicBudgetMigration()
        try verifyGemini()
        try verifyValidationAndScopes()
        try verifyIncompleteSettingsCanBeSaved()
        try await verifyRefusalDoesNotRepair()
        try await verifyNativeProtocolRefusals()
        try await verifyRefusalStopsPlanAndMemoryJSON()
        try await verifyRepairRefusalUsage()
        try await verifyJSONRepairAndUsage()
        try await verifyRetryAndCancellation()
        print("AI protocol verification passed")
    }

    private static func verifyNativeProtocolRefusals() async throws {
        let fixtures: [(AIProtocolKind, String)] = [
            (.openAIResponses, #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"拒绝说明"}]}],"usage":{"input_tokens":9,"output_tokens":4}}"#),
            (.anthropicMessages, #"{"content":[{"type":"text","text":"拒绝说明"}],"stop_reason":"refusal","usage":{"input_tokens":9,"output_tokens":4}}"#),
            (.geminiGenerateContent, #"{"promptFeedback":{"blockReason":"SAFETY"},"usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":4}}"#)
        ]
        for (kind, response) in fixtures {
            let mock = QueueMockTransport([(200, [:], response)])
            let client = try AIClient(
                configuration: config(kind, baseURL: "https://mock.example/v1"),
                apiKey: "mock-key",
                pricing: AIUsagePricing(inputPerMillion: 1, outputPerMillion: 2),
                underlyingTransport: mock
            )
            do {
                _ = try await client.analyze(content: "sample", kind: .note)
                fatalError("\(kind) refusal must stop analysis")
            } catch let refusal as AIModelRefusal {
                expect(!refusal.message.isEmpty && refusal.usage?.totalTokens == 13, "\(kind) retains refusal text and usage")
            }
            let count = await mock.count()
            expect(count == 1, "\(kind) refusal never starts JSON repair")
        }
    }

    private static func verifyIncompleteSettingsCanBeSaved() throws {
        for (url, model) in [("", ""), ("https://api.example.com/v1", ""), ("https://api.example.com/v1", "test-model")] {
            let configuration = config(.openAIChatCompletions, baseURL: url, model: model)
            try AIConnectionConfiguration.validateForSaving(configuration)
            expectThrows({
                if model.isEmpty, case .invalidConfiguration = $0 { return true }
                if !model.isEmpty, case .missingAPIKey = $0 { return true }
                return false
            }, "saved incomplete connection cannot start an authenticated request") {
                try AIConnectionConfiguration.validate(configuration, apiKey: "")
            }
        }
        expectThrows({ if case .invalidConfiguration = $0 { return true }; return false }, "saving still rejects malformed nonempty URLs") {
            try AIConnectionConfiguration.validateForSaving(config(.openAIChatCompletions, baseURL: "not a URL"))
        }
        expectThrows({ if case .invalidConfiguration = $0 { return true }; return false }, "saving still rejects invalid temperature") {
            try AIConnectionConfiguration.validateForSaving(config(.openAIChatCompletions, baseURL: "", model: "", temperature: -1))
        }
    }

    private static func verifyOpenAIChatCompletions() throws {
        let settings = config(.openAIChatCompletions, baseURL: "https://compat.example/gateway/v1/chat/completions/", tokenParameter: .maxCompletionTokens)
        let adapter = AIProviderAdapters.adapter(for: .openAIChatCompletions)
        let request = try adapter.makeRequest(configuration: settings, apiKey: "test-key", messages: [AIMessage(role: "system", content: "system"), AIMessage(role: "user", content: "hi")], options: AIRequestOptions(maxOutputTokens: 321, structuredOutputRequested: false), timeout: 7)
        expect(request.url?.absoluteString == "https://compat.example/gateway/v1/chat/completions", "Chat Completions path preserves prefix and normalizes a full endpoint")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Chat Completions Bearer authentication")
        expect(request.timeoutInterval == 7, "custom timeout applied")
        let requestBody = try body(request)
        expect(requestBody["max_completion_tokens"] as? Int == 321, "new Chat Completions token field")
        expect(requestBody["max_tokens"] == nil && requestBody["temperature"] == nil, "unsupported or unset parameters omitted")
        let messages = requestBody["messages"] as? [[String: String]] ?? []
        expect(messages.map { $0["role"] ?? "" } == ["system", "user"], "system and user roles retained")
        let omitLimitConfig = config(.openAIChatCompletions, baseURL: "https://compat.example/v1", tokenParameter: .omit)
        let omitLimitRequest = try adapter.makeRequest(configuration: omitLimitConfig, apiKey: "key", messages: [AIMessage(role: "user", content: "hi")], options: AIRequestOptions(maxOutputTokens: 200, structuredOutputRequested: false), timeout: 90)
        let omitLimitBody = try body(omitLimitRequest)
        expect(omitLimitBody["max_tokens"] == nil && omitLimitBody["max_completion_tokens"] == nil, "configured token parameter can be omitted")

        let completion = try adapter.parseResponse(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":[{"type":"text","text":"hello"},{"type":"image"}]}}],"usage":{"prompt_tokens":4,"completion_tokens":6}}"#.utf8))
        expect(completion.text == "hello" && completion.usage?.inputTokens == 4 && completion.usage?.outputTokens == 6, "Chat text-block extraction and usage")
        let missingUsage = try adapter.parseResponse(Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"ok"}}]}"#.utf8))
        expect(missingUsage.text == "ok" && missingUsage.usage == nil, "missing usage supported")
        let legacyDeepSeekRoot = try adapter.makeRequest(configuration: config(.openAIChatCompletions, baseURL: "https://api.deepseek.com"), apiKey: "key", messages: [AIMessage(role: "user", content: "ping")], options: AIRequestOptions(maxOutputTokens: nil, structuredOutputRequested: false), timeout: 90)
        expect(legacyDeepSeekRoot.url?.absoluteString == "https://api.deepseek.com/chat/completions", "versionless API root is not silently rewritten")
        expectThrows({ if case .truncatedResponse = $0 { return true }; return false }, "Chat length finish reason") {
            _ = try adapter.parseResponse(Data(#"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#.utf8))
        }
    }

    private static func verifyResponses() throws {
        let settings = config(.openAIResponses, baseURL: "https://responses.example/proxy/v1/", jsonMode: true)
        let adapter = AIProviderAdapters.adapter(for: .openAIResponses)
        let request = try adapter.makeRequest(configuration: settings, apiKey: "response-key", messages: [AIMessage(role: "system", content: "rules"), AIMessage(role: "assistant", content: "past"), AIMessage(role: "user", content: "question")], options: AIRequestOptions(maxOutputTokens: 500, structuredOutputRequested: true), timeout: 90)
        expect(request.url?.absoluteString == "https://responses.example/proxy/v1/responses", "Responses endpoint")
        expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer response-key", "Responses Bearer authentication")
        let requestBody = try body(request)
        expect(requestBody["max_output_tokens"] as? Int == 500, "Responses output token parameter")
        expect((requestBody["text"] as? [String: Any])? ["format"] != nil, "Responses JSON mode is opt-in")
        expect((requestBody["input"] as? [[String: Any]])?.count == 3, "Responses system, assistant and user mapping")
        let completion = try adapter.parseResponse(Data(#"{"status":"completed","output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"A"},{"type":"output_text","text":"B"}]}],"usage":{"input_tokens":8,"output_tokens":9}}"#.utf8))
        expect(completion.text == "AB" && completion.usage?.inputTokens == 8 && completion.usage?.outputTokens == 9, "Responses aggregate output_text blocks and usage")
        expectThrows({ if case .truncatedResponse = $0 { return true }; return false }, "Responses incomplete output") {
            _ = try adapter.parseResponse(Data(#"{"status":"incomplete","output":[]}"#.utf8))
        }
        expectThrows({ if case .emptyResponse = $0 { return true }; return false }, "Responses empty output") {
            _ = try adapter.parseResponse(Data(#"{"status":"completed","output":[{"type":"reasoning"}]}"#.utf8))
        }
    }

    private static func verifyAnthropic() throws {
        let settings = config(.anthropicMessages, baseURL: "https://anthropic.example/prefix/v1/messages", outputLimit: 777)
        let adapter = AIProviderAdapters.adapter(for: .anthropicMessages)
        let request = try adapter.makeRequest(configuration: settings, apiKey: "anthropic-key", messages: [AIMessage(role: "system", content: "system rules"), AIMessage(role: "user", content: "hello"), AIMessage(role: "assistant", content: "prior")], options: AIRequestOptions(maxOutputTokens: nil, structuredOutputRequested: true), timeout: 90)
        expect(request.url?.absoluteString == "https://anthropic.example/prefix/v1/messages", "Anthropic full endpoint normalization")
        expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-key", "Anthropic x-api-key authentication")
        expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic version header")
        let requestBody = try body(request)
        expect(requestBody["system"] as? String == "system rules", "Anthropic top-level system field")
        expect(requestBody["max_tokens"] as? Int == 777, "Anthropic required output token parameter")
        expect((requestBody["messages"] as? [[String: Any]])?.count == 2, "Anthropic system excluded from messages")
        expect(requestBody["temperature"] == nil && requestBody["response_format"] == nil, "unsupported Anthropic options omitted")
        let completion = try adapter.parseResponse(Data(#"{"content":[{"type":"text","text":"one"},{"type":"image","source":{}},{"type":"text","text":"two"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":3}}"#.utf8))
        expect(completion.text == "onetwo" && completion.usage?.totalTokens == 5, "Anthropic text block extraction and usage")
        expectThrows({ if case .truncatedResponse = $0 { return true }; return false }, "Anthropic max_tokens truncation") {
            _ = try adapter.parseResponse(Data(#"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#.utf8))
        }
    }

    private static func verifyAnthropicOutputBudgets() async throws {
        let completion = #"{"content":[{"type":"text","text":"budget-ok"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1}}"#

        for (configuredLimit, expected) in [(16_000, 16_000), (512, 512)] {
            let mock = QueueMockTransport([(200, [:], completion)])
            let client = try AIClient(
                configuration: config(.anthropicMessages, baseURL: "https://api.anthropic.com/v1", outputLimit: configuredLimit),
                apiKey: "anthropic-key",
                pricing: AIUsagePricing(inputPerMillion: 0, outputPerMillion: 0),
                underlyingTransport: mock
            )
            _ = try await client.answer(
                question: "解释函数。",
                context: "",
                studyState: "",
                chatHistory: [],
                compressedContextSummary: "",
                answerMode: .normal
            )
            let requests = await mock.requests()
            let requestBudget = try body(requests[0])["max_tokens"] as? Int
            expect(requestBudget == expected, "Anthropic answer uses configured maximum output budget \(expected)")
        }

        let defaultMock = QueueMockTransport([(200, [:], completion)])
        let defaultClient = try AIClient(
            configuration: config(.anthropicMessages, baseURL: "https://api.anthropic.com/v1", outputLimit: nil),
            apiKey: "anthropic-key",
            pricing: AIUsagePricing(inputPerMillion: 0, outputPerMillion: 0),
            underlyingTransport: defaultMock
        )
        _ = try await defaultClient.answer(
            question: "解释函数。",
            context: "",
            studyState: "",
            chatHistory: [],
            compressedContextSummary: "",
            answerMode: .normal
        )
        let defaultRequests = await defaultMock.requests()
        let defaultBudget = try body(defaultRequests[0])["max_tokens"] as? Int
        expect(defaultBudget == 2_400, "Anthropic answer uses its business default when no custom cap is configured")

        let truncatedMock = QueueMockTransport([(
            200,
            [:],
            #"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens","usage":{"input_tokens":2,"output_tokens":512}}"#
        )])
        let truncatedClient = try AIClient(
            configuration: config(.anthropicMessages, baseURL: "https://api.anthropic.com/v1", outputLimit: 512),
            apiKey: "anthropic-key",
            pricing: AIUsagePricing(inputPerMillion: 0, outputPerMillion: 0),
            underlyingTransport: truncatedMock
        )
        do {
            _ = try await truncatedClient.answer(
                question: "解释函数。",
                context: "",
                studyState: "",
                chatHistory: [],
                compressedContextSummary: "",
                answerMode: .normal
            )
            fatalError("AI protocol verification failed: truncated Anthropic answer unexpectedly succeeded")
        } catch let error as AIError {
            guard case .outputBudgetReached(let limit, let settingName) = error else {
                fatalError("AI protocol verification failed: expected configured Anthropic budget in truncation error, got \(error)")
            }
            expect(limit == 512 && settingName.contains("Anthropic 最大输出预算"), "Anthropic truncation points to the actual configured budget")
        }

        let analysisJSON = #"{"summary":"summary","knowledgePoints":[],"mistakes":[],"reviewItems":[]}"#
        let planJSON = #"{}"#
        let memoryJSON = #"{"userGoals":[],"learningLevels":[],"preferences":[],"plannedWork":[],"questionsNotToRepeat":[]}"#
        let structuredCases: [(String, String)] = [
            ("analysis", analysisJSON),
            ("plan", planJSON),
            ("memory", memoryJSON)
        ]
        for (operation, text) in structuredCases {
            let mock = QueueMockTransport([(200, [:], anthropicTextResponse(text))])
            let client = try AIClient(
                configuration: config(.anthropicMessages, baseURL: "https://api.anthropic.com/v1", outputLimit: 16_000),
                apiKey: "anthropic-key",
                pricing: AIUsagePricing(inputPerMillion: 0, outputPerMillion: 0),
                underlyingTransport: mock
            )
            switch operation {
            case "analysis": _ = try await client.analyze(content: "测试资料", kind: .note)
            case "plan":
                _ = try await client.makeAIPlanDraft(question: "规划", answer: "复习函数", context: "", studyState: "", planTemplate: .general)
            default:
                _ = try await client.compressChatContext(existingMemory: ChatMemorySummary(), messages: [ChatHistoryMessage(role: .user, content: "旧对话")], studyState: "")
            }
            let requests = await mock.requests()
            let requestBudget = try body(requests[0])["max_tokens"] as? Int
            expect(requestBudget == 16_000, "Anthropic \(operation) uses the same configured output budget")
        }

        let repairMock = QueueMockTransport([
            (200, [:], anthropicTextResponse("not json")),
            (200, [:], anthropicTextResponse(analysisJSON))
        ])
        let repairClient = try AIClient(
            configuration: config(.anthropicMessages, baseURL: "https://api.anthropic.com/v1", outputLimit: 16_000),
            apiKey: "anthropic-key",
            pricing: AIUsagePricing(inputPerMillion: 0, outputPerMillion: 0),
            underlyingTransport: repairMock
        )
        _ = try await repairClient.analyze(content: "测试资料", kind: .note)
        let repairRequests = await repairMock.requests()
        let repairBudgets = try repairRequests.map { try body($0)["max_tokens"] as? Int }
        expect(repairRequests.count == 2, "Anthropic JSON repair sends one follow-up request")
        expect(repairBudgets == [16_000, 16_000], "Anthropic JSON repair uses the same configured output budget")
    }

    private static func anthropicTextResponse(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"content":[{"type":"text","text":"\#(escaped)"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":1}}"#
    }

    private static func verifyAnthropicBudgetMigration() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"baseURL":"https://api.anthropic.com/v1","protocolKind":"anthropicMessages","model":"claude-custom"}"#.utf8))
        expect(legacy.anthropicOutputTokenLimit == nil, "missing Anthropic cap remains unset for business defaults")

        let configured = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"anthropicOutputTokenLimit":16000}"#.utf8))
        expect(configured.anthropicOutputTokenLimit == 16_000, "saved Anthropic cap survives settings decoding")
    }

    private static func verifyGemini() throws {
        let settings = config(.geminiGenerateContent, baseURL: "https://generativelanguage.googleapis.com/proxy/v1beta/", model: "gemini-test-model", auth: .none, temperature: 0.25, jsonMode: true)
        let adapter = AIProviderAdapters.adapter(for: .geminiGenerateContent)
        let request = try adapter.makeRequest(configuration: settings, apiKey: "ignored-key", messages: [AIMessage(role: "system", content: "rules"), AIMessage(role: "assistant", content: "past"), AIMessage(role: "user", content: "hello")], options: AIRequestOptions(maxOutputTokens: 333, structuredOutputRequested: true), timeout: 90)
        expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/proxy/v1beta/models/gemini-test-model%3AgenerateContent", "Gemini generateContent path: \(request.url?.absoluteString ?? "nil")")
        expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil && request.value(forHTTPHeaderField: "Authorization") == nil, "no-auth local Gemini configuration sends no key")
        let requestBody = try body(request)
        expect((requestBody["systemInstruction"] as? [String: Any]) != nil, "Gemini systemInstruction mapping")
        let contents = requestBody["contents"] as? [[String: Any]] ?? []
        expect(contents.map { $0["role"] as? String ?? "" } == ["model", "user"], "Gemini assistant role maps to model")
        let generation = requestBody["generationConfig"] as? [String: Any] ?? [:]
        expect(generation["maxOutputTokens"] as? Int == 333 && generation["temperature"] as? Double == 0.25 && generation["responseMimeType"] as? String == "application/json", "Gemini generationConfig settings")
        let keyedConfiguration = config(.geminiGenerateContent, baseURL: "https://generativelanguage.googleapis.com/v1beta", model: "gemini-test-model")
        let keyedRequest = try adapter.makeRequest(configuration: keyedConfiguration, apiKey: "gemini-key", messages: [AIMessage(role: "user", content: "hello")], options: AIRequestOptions(maxOutputTokens: nil, structuredOutputRequested: false), timeout: 90)
        expect(keyedRequest.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-key", "Gemini API key authentication header")
        let completion = try adapter.parseResponse(Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"a"},{"inlineData":{"data":"ignored"}},{"text":"b"}]}}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":4}}"#.utf8))
        expect(completion.text == "ab" && completion.usage?.inputTokens == 10 && completion.usage?.outputTokens == 4, "Gemini text parts and usage metadata")
        expectThrows({ if case .truncatedResponse = $0 { return true }; return false }, "Gemini MAX_TOKENS truncation") {
            _ = try adapter.parseResponse(Data(#"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"partial"}]}}]}"#.utf8))
        }
    }

    private static func verifyValidationAndScopes() throws {
        expect(AppSettings().model.isEmpty, "new installations do not pin a possibly stale model ID")
        let local = config(.openAIChatCompletions, baseURL: "http://localhost:11434/v1/", auth: .none)
        try AIConnectionConfiguration.validate(local, apiKey: "")
        let localRequest = try AIProviderAdapters.adapter(for: .openAIChatCompletions).makeRequest(configuration: local, apiKey: "", messages: [AIMessage(role: "user", content: "ping")], options: AIRequestOptions(maxOutputTokens: nil, structuredOutputRequested: false), timeout: 30)
        expect(localRequest.value(forHTTPHeaderField: "Authorization") == nil, "local OpenAI-compatible no-auth request")

        var old = AppSettings()
        old.baseURL = "https://my-proxy.example/custom/v1/"
        old.model = "my-model"
        old.allowModelRequests = false
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: ["baseURL": old.baseURL, "model": old.model, "allowModelRequests": false]))
        expect(migrated.protocolKind == .openAIChatCompletions && migrated.servicePreset == .deepSeek, "old settings default to original Chat Completions protocol")
        expect(migrated.legacyCredentialMigrationPending, "old settings permit a one-time legacy credential migration")
        expect(migrated.baseURL == old.baseURL && migrated.model == old.model && !migrated.allowModelRequests, "old settings preserve custom values and privacy flag")

        let first = config(.openAIChatCompletions, baseURL: "https://provider.example/v1")
        let changedAddress = config(.openAIChatCompletions, baseURL: "https://other.example/v1")
        let changedProtocol = config(.openAIResponses, baseURL: "https://provider.example/v1")
        expect(first.credentialScope != changedAddress.credentialScope && first.credentialScope != changedProtocol.credentialScope, "credential scope changes with URL or protocol")
        expect(KeychainStore.scopedAccount(for: first) != KeychainStore.scopedAccount(for: changedAddress), "Keychain account is isolated by service address")
        expect(KeychainStore.scopedAccount(for: first) != KeychainStore.scopedAccount(for: changedProtocol), "Keychain account is isolated by protocol")
        expect(KeychainStore.canReadLegacyCredential(for: config(.openAIChatCompletions, baseURL: "https://custom-legacy.example/v1"), allowLegacyFallback: migrated.legacyCredentialMigrationPending), "old local configuration can migrate its key to its persisted custom address")
        expect(!KeychainStore.canReadLegacyCredential(for: config(.openAIChatCompletions, baseURL: "https://restored.example/v1"), allowLegacyFallback: false), "restored backup cannot rebind the legacy key")
        expect(!KeychainStore.canReadLegacyCredential(for: config(.openAIResponses, baseURL: "https://api.deepseek.com"), allowLegacyFallback: true), "legacy Keychain does not cross protocol")
        expectThrows({ if case .invalidConfiguration = $0 { return true }; return false }, "invalid URL rejected") {
            try AIConnectionConfiguration.validate(config(.openAIChatCompletions, baseURL: "not a URL"), apiKey: "key")
        }
        expectThrows({ if case .missingAPIKey = $0 { return true }; return false }, "key-auth service needs a key") {
            try AIConnectionConfiguration.validate(config(.anthropicMessages, baseURL: "https://api.example.com"), apiKey: "")
        }
    }

    private static func verifyJSONRepairAndUsage() async throws {
        let mock = QueueMockTransport([
            (200, [:], #"{"choices":[{"finish_reason":"stop","message":{"content":"not json"}}],"usage":{"prompt_tokens":5,"completion_tokens":7}}"#),
            (200, [:], #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"summary\":\"fixed\",\"knowledgePoints\":[],\"mistakes\":[],\"reviewItems\":[]}"}}],"usage":{"prompt_tokens":11,"completion_tokens":13}}"#)
        ])
        var settings = AppSettings()
        settings.baseURL = "https://mock.example/v1"
        settings.model = "mock-model"
        settings.inputTokenCostPerMillion = 2
        settings.outputTokenCostPerMillion = 3
        let client = try AIClientFactory.make(settings: settings, apiKey: "mock-key", underlyingTransport: mock)
        let result = try await client.analyze(content: "sample", kind: .note)
        expect(result.payload.summary == "fixed", "malformed JSON repaired once")
        expect(result.usage?.inputTokens == 16 && result.usage?.outputTokens == 20, "usage from JSON repair request is merged")
        let repairRequestCount = await mock.count()
        expect(repairRequestCount == 2, "JSON repair sends exactly one second request")
    }

    private static func verifyRefusalDoesNotRepair() async throws {
        let mock = QueueMockTransport([
            (200, [:], #"{"choices":[{"finish_reason":"stop","message":{"refusal":"拒绝说明","content":null}}],"usage":{"prompt_tokens":9,"completion_tokens":4}}"#)
        ])
        var settings = AppSettings()
        settings.baseURL = "https://mock.example/v1"
        settings.model = "mock-model"
        settings.inputTokenCostPerMillion = 1.25
        settings.outputTokenCostPerMillion = 2.5
        let client = try AIClientFactory.make(settings: settings, apiKey: "mock-key", underlyingTransport: mock)

        do {
            _ = try await client.analyze(content: "sample", kind: .note)
            fatalError("AI protocol verification failed: refusal unexpectedly produced an analysis result")
        } catch let refusal as AIModelRefusal {
            expect(refusal.message == "拒绝说明", "model refusal is retained as a typed error")
            expect(refusal.usage?.inputTokens == 9 && refusal.usage?.outputTokens == 4, "refusal error retains usage")
            expect(refusal.pricing.inputPerMillion == 1.25 && refusal.pricing.outputPerMillion == 2.5, "refusal error retains request pricing")
        } catch {
            fatalError("AI protocol verification failed: unexpected refusal handling error: \(error)")
        }

        let requestCount = await mock.count()
        expect(requestCount == 1, "refusal on the first response does not trigger a JSON repair request")
    }

    private static func verifyRepairRefusalUsage() async throws {
        let mock = QueueMockTransport([
            (200, [:], #"{"choices":[{"finish_reason":"stop","message":{"content":"not json"}}],"usage":{"prompt_tokens":2,"completion_tokens":3}}"#),
            (200, [:], #"{"choices":[{"finish_reason":"stop","message":{"refusal":"拒绝修复","content":null}}],"usage":{"prompt_tokens":7,"completion_tokens":11}}"#)
        ])
        var settings = AppSettings()
        settings.baseURL = "https://mock.example/v1"
        settings.model = "mock-model"
        let client = try AIClientFactory.make(settings: settings, apiKey: "mock-key", underlyingTransport: mock)

        do {
            _ = try await client.analyze(content: "sample", kind: .note)
            fatalError("AI protocol verification failed: repair refusal unexpectedly produced an analysis result")
        } catch let refusal as AIModelRefusal {
            expect(refusal.message == "拒绝修复", "repair refusal is surfaced directly")
            expect(refusal.usage?.inputTokens == 9 && refusal.usage?.outputTokens == 14, "usage from initial JSON and refused repair requests is combined")
        } catch {
            fatalError("AI protocol verification failed: unexpected repair refusal error: \(error)")
        }

        let requestCount = await mock.count()
        expect(requestCount == 2, "a refused JSON repair does not start a third request")
    }

    private static func verifyRefusalStopsPlanAndMemoryJSON() async throws {
        let refusalBody = #"{"choices":[{"finish_reason":"stop","message":{"refusal":"此请求被拒绝","content":null}}],"usage":{"prompt_tokens":3,"completion_tokens":2}}"#
        let planMock = QueueMockTransport([(200, [:], refusalBody)])
        var settings = AppSettings()
        settings.baseURL = "https://mock.example/v1"
        settings.model = "mock-model"
        let planClient = try AIClientFactory.make(settings: settings, apiKey: "mock-key", underlyingTransport: planMock)

        do {
            _ = try await planClient.makeAIPlanDraft(
                question: "帮我制定学习计划",
                answer: "学习计划如下",
                context: "",
                studyState: "",
                planTemplate: .general
            )
            fatalError("AI protocol verification failed: refused plan request unexpectedly returned a draft")
        } catch is AIModelRefusal {
            expect(true, "plan refusal stops structured decoding before repair")
        }
        let planRequestCount = await planMock.count()
        expect(planRequestCount == 1, "refused plan generation does not issue a JSON repair request")

        let memoryMock = QueueMockTransport([(200, [:], refusalBody)])
        let memoryClient = try AIClientFactory.make(settings: settings, apiKey: "mock-key", underlyingTransport: memoryMock)
        do {
            _ = try await memoryClient.compressChatContext(
                existingMemory: ChatMemorySummary(),
                messages: [ChatHistoryMessage(role: .user, content: "旧对话")],
                studyState: ""
            )
            fatalError("AI protocol verification failed: refused memory request unexpectedly returned a summary")
        } catch is AIModelRefusal {
            expect(true, "memory refusal stops structured decoding before repair")
        }
        let memoryRequestCount = await memoryMock.count()
        expect(memoryRequestCount == 1, "refused memory compression does not issue a JSON repair request")
    }

    private static func verifyRetryAndCancellation() async throws {
        let request = URLRequest(url: URL(string: "https://mock.example/v1/chat/completions")!)
        let retryMock = QueueMockTransport([
            (503, ["Retry-After": "0"], "{}"),
            (429, ["Retry-After": "0"], "{}"),
            (200, [:], #"{"ok":true}"#)
        ])
        let transport = AIHTTPTransport(underlying: retryMock, baseRetryDelaySeconds: 0)
        let (data, _) = try await transport.data(for: request, maxRetryCount: 2)
        let retryRequestCount = await retryMock.count()
        expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"# && retryRequestCount == 3, "bounded retries include 429 and 5xx")

        let limitMock = QueueMockTransport([(503, [:], "{}"), (503, [:], "{}"), (503, [:], "{}"), (200, [:], "{}")])
        do {
            _ = try await AIHTTPTransport(underlying: limitMock, baseRetryDelaySeconds: 0).data(for: request, maxRetryCount: 2)
            fatalError("retry limit should fail")
        } catch let error as AIError {
            if case .httpFailure(status: 503) = error {} else { fatalError("unexpected retry-limit error: \(error)") }
        }
        let limitedRequestCount = await limitMock.count()
        expect(limitedRequestCount == 3, "retry count is bounded")

        let cancelMock = QueueMockTransport([(429, ["Retry-After": "30"], "{}"), (200, [:], "{}")])
        let cancelTransport = AIHTTPTransport(underlying: cancelMock)
        let task = Task { try await cancelTransport.data(for: request, maxRetryCount: 3) }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do {
            _ = try await task.value
            fatalError("cancelled request should not retry")
        } catch is CancellationError {
        } catch {
            fatalError("unexpected cancellation error: \(error)")
        }
        let cancelledRequestCount = await cancelMock.count()
        expect(cancelledRequestCount == 1, "cancellation stops before another retry")

        let authMock = QueueMockTransport([(401, [:], #"{"error":{"message":"api_key=secret"}}"#)])
        do {
            _ = try await AIHTTPTransport(underlying: authMock).data(for: request, maxRetryCount: 0)
            fatalError("401 should fail")
        } catch let error as AIError {
            if case .authenticationFailed = error {
                expect(!error.localizedDescription.contains("secret"), "provider error does not echo credentials")
            } else { fatalError("unexpected 401 error: \(error)") }
        }

        let parameterMock = QueueMockTransport([(400, [:], #"{"error":{"message":"model parameter is incompatible"}}"#)])
        do {
            _ = try await AIHTTPTransport(underlying: parameterMock).data(for: request, maxRetryCount: 0)
            fatalError("400 parameter error should fail")
        } catch let error as AIError {
            if case .incompatibleParameters = error {} else { fatalError("400 with model text was misclassified: \(error)") }
        }

        let modelMock = QueueMockTransport([(404, [:], #"{"error":{"code":"model_not_found"}}"#)])
        do {
            _ = try await AIHTTPTransport(underlying: modelMock).data(for: request, maxRetryCount: 0)
            fatalError("missing model should fail")
        } catch let error as AIError {
            if case .modelUnavailable = error {} else { fatalError("unexpected model error: \(error)") }
        }

        let endpointMock = QueueMockTransport([(404, [:], #"{"error":{"message":"route not found"}}"#)])
        do {
            _ = try await AIHTTPTransport(underlying: endpointMock).data(for: request, maxRetryCount: 0)
            fatalError("missing endpoint should fail")
        } catch let error as AIError {
            if case .endpointNotFound = error {} else { fatalError("unexpected endpoint error: \(error)") }
        }
    }

    private static func expectThrows(_ predicate: (AIError) -> Bool, _ message: String, operation: () throws -> Void) {
        do {
            try operation()
            fatalError("AI protocol verification failed: expected error for \(message)")
        } catch let error as AIError {
            expect(predicate(error), "wrong error for \(message): \(error)")
        } catch {
            fatalError("wrong error type for \(message): \(error)")
        }
    }
}
