import Foundation

struct AIConnectionConfiguration: Equatable {
    var baseURL: String
    var model: String
    var protocolKind: AIProtocolKind
    var authMode: AIAuthMode
    var chatTokenParameter: AIChatTokenParameter
    var anthropicOutputTokenLimit: Int?
    var temperature: Double?
    var useNativeJSONMode: Bool

    var credentialScope: String {
        let canonicalURL = (try? AIEndpointBuilder.baseComponents(baseURL).url?.absoluteString) ?? baseURL
        return "\(protocolKind.rawValue)|\(authMode.rawValue)|\(canonicalURL)"
    }

    static func validate(_ configuration: AIConnectionConfiguration, apiKey: String) throws {
        try validateStructure(configuration)
        if configuration.authMode == .providerKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AIError.missingAPIKey
        }
    }

    static func validateStructure(_ configuration: AIConnectionConfiguration) throws {
        _ = try AIEndpointBuilder.baseComponents(configuration.baseURL)
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.invalidConfiguration("模型 ID 不能为空。")
        }
        try validateParameters(configuration)
    }

    /// Incomplete connections may be saved for offline use; actual requests still
    /// require validate(_:apiKey:). Reject malformed values that were supplied.
    static func validateForSaving(_ configuration: AIConnectionConfiguration) throws {
        if !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try AIEndpointBuilder.baseComponents(configuration.baseURL)
        }
        try validateParameters(configuration)
    }

    private static func validateParameters(_ configuration: AIConnectionConfiguration) throws {
        if let temperature = configuration.temperature, !(0...2).contains(temperature) {
            throw AIError.invalidConfiguration("temperature 必须在 0 到 2 之间，或留空使用服务默认值。")
        }
        if let limit = configuration.anthropicOutputTokenLimit,
           configuration.protocolKind == .anthropicMessages,
           limit < 1 {
            throw AIError.invalidConfiguration("Anthropic Messages 要求 max_tokens 大于 0。")
        }
    }
}

extension AIConnectionConfiguration {
    init(settings: AppSettings) {
        self.init(
            baseURL: settings.baseURL,
            model: settings.model,
            protocolKind: settings.protocolKind,
            authMode: settings.authMode,
            chatTokenParameter: settings.chatTokenParameter,
            anthropicOutputTokenLimit: settings.anthropicOutputTokenLimit,
            temperature: settings.temperature,
            useNativeJSONMode: settings.useNativeJSONMode
        )
    }
}

struct AIMessage: Codable, Equatable {
    var role: String
    var content: String
}

struct AIRequestOptions {
    var maxOutputTokens: Int?
    var structuredOutputRequested: Bool
}

enum AIOutputBudget {
    nonisolated static let connectionTest = 64
    nonisolated static let documentAnalysis = 4_096
    nonisolated static let planDraft = 4_096
    nonisolated static let memoryCompression = 2_048
    nonisolated static let unclassifiedRequest = 1_024

    /// Anthropic requires a limit; a configured cap takes precedence over the
    /// operation's default. Other adapters use the operation's budget directly.
    static func anthropicLimit(configuration: AIConnectionConfiguration, businessDefault: Int?) -> Int {
        return configuration.anthropicOutputTokenLimit ?? businessDefault ?? unclassifiedRequest
    }
}

struct AICompletion {
    var text: String
    var usage: AIUsage?
    var refusal: String?
}

protocol AIProviderAdapter {
    var protocolKind: AIProtocolKind { get }
    func makeRequest(
        configuration: AIConnectionConfiguration,
        apiKey: String,
        messages: [AIMessage],
        options: AIRequestOptions,
        timeout: TimeInterval
    ) throws -> URLRequest
    func parseResponse(_ data: Data) throws -> AICompletion
}

enum AIProviderAdapters {
    static func adapter(for kind: AIProtocolKind) -> any AIProviderAdapter {
        switch kind {
        case .openAIChatCompletions: return OpenAIChatCompletionsAdapter()
        case .openAIResponses: return OpenAIResponsesAdapter()
        case .anthropicMessages: return AnthropicMessagesAdapter()
        case .geminiGenerateContent: return GeminiGenerateContentAdapter()
        }
    }
}

private enum AIEndpointBuilder {
    static func baseComponents(_ value: String) throws -> URLComponents {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw AIError.invalidConfiguration("Base URL 必须是有效的 http 或 https API 根地址。")
        }

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let lowerPath = path.lowercased()
        for endpoint in ["/chat/completions", "/responses", "/messages"] where lowerPath.hasSuffix(endpoint) {
            path = String(path.dropLast(endpoint.count))
            break
        }
        if let modelsRange = lowerPath.range(of: "/models/") {
            let suffix = lowerPath[modelsRange.lowerBound...]
            if suffix.contains(":generatecontent") {
                path = String(path[..<modelsRange.lowerBound])
            }
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components
    }

    static func url(configuration: AIConnectionConfiguration, suffix: String) throws -> URL {
        var components = try baseComponents(configuration.baseURL)
        let prefix = components.percentEncodedPath
        let encodedSuffix = suffix.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        components.percentEncodedPath = prefix + "/" + encodedSuffix
        guard let url = components.url else { throw AIError.invalidConfiguration("Base URL 无法组成有效的请求地址。") }
        return url
    }

    static func body(_ object: [String: Any]) throws -> Data {
        do { return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) }
        catch { throw AIError.invalidConfiguration("请求参数无法编码为 JSON。") }
    }

    static func request(url: URL, apiKey: String, authMode: AIAuthMode, kind: AIProtocolKind, timeout: TimeInterval, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard authMode == .providerKey else { return request }
        switch kind {
        case .openAIChatCompletions, .openAIResponses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiGenerateContent:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }
}

private struct OpenAIChatCompletionsAdapter: AIProviderAdapter {
    let protocolKind = AIProtocolKind.openAIChatCompletions

    func makeRequest(configuration: AIConnectionConfiguration, apiKey: String, messages: [AIMessage], options: AIRequestOptions, timeout: TimeInterval) throws -> URLRequest {
        let url = try AIEndpointBuilder.url(configuration: configuration, suffix: "chat/completions")
        var body: [String: Any] = ["model": configuration.model, "messages": messages.map { ["role": $0.role, "content": $0.content] }]
        if let temperature = configuration.temperature { body["temperature"] = temperature }
        if let limit = options.maxOutputTokens {
            switch configuration.chatTokenParameter {
            case .maxTokens: body["max_tokens"] = limit
            case .maxCompletionTokens: body["max_completion_tokens"] = limit
            case .omit: break
            }
        }
        if options.structuredOutputRequested && configuration.useNativeJSONMode {
            body["response_format"] = ["type": "json_object"]
        }
        return AIEndpointBuilder.request(url: url, apiKey: apiKey, authMode: configuration.authMode, kind: protocolKind, timeout: timeout, body: try AIEndpointBuilder.body(body))
    }

    func parseResponse(_ data: Data) throws -> AICompletion {
        let root = try jsonObject(data)
        guard let choices = root["choices"] as? [[String: Any]], let choice = choices.first,
              let message = choice["message"] as? [String: Any] else { throw AIError.responseParseFailed("Chat Completions 响应缺少 choices.message。") }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { return AICompletion(text: refusal, usage: parseOpenAIUsage(root["usage"]), refusal: refusal) }
        let text = extractText(message["content"])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
        if choice["finish_reason"] as? String == "length" { throw AIError.truncatedResponse }
        return AICompletion(text: text, usage: parseOpenAIUsage(root["usage"]), refusal: nil)
    }
}

private struct OpenAIResponsesAdapter: AIProviderAdapter {
    let protocolKind = AIProtocolKind.openAIResponses

    func makeRequest(configuration: AIConnectionConfiguration, apiKey: String, messages: [AIMessage], options: AIRequestOptions, timeout: TimeInterval) throws -> URLRequest {
        let url = try AIEndpointBuilder.url(configuration: configuration, suffix: "responses")
        var body: [String: Any] = [
            "model": configuration.model,
            "input": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if let limit = options.maxOutputTokens { body["max_output_tokens"] = limit }
        if let temperature = configuration.temperature { body["temperature"] = temperature }
        if options.structuredOutputRequested && configuration.useNativeJSONMode {
            body["text"] = ["format": ["type": "json_object"]]
        }
        return AIEndpointBuilder.request(url: url, apiKey: apiKey, authMode: configuration.authMode, kind: protocolKind, timeout: timeout, body: try AIEndpointBuilder.body(body))
    }

    func parseResponse(_ data: Data) throws -> AICompletion {
        let root = try jsonObject(data)
        if let status = root["status"] as? String, status == "incomplete" { throw AIError.truncatedResponse }
        let output = root["output"] as? [[String: Any]] ?? []
        var texts: [String] = []
        var refusal: String?
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for block in content {
                let type = block["type"] as? String
                if type == "output_text", let text = block["text"] as? String { texts.append(text) }
                if type == "refusal", let text = block["refusal"] as? String { refusal = text }
            }
        }
        let text = texts.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || refusal != nil else { throw AIError.emptyResponse }
        return AICompletion(text: refusal ?? text, usage: parseOpenAIUsage(root["usage"]), refusal: refusal)
    }
}

private struct AnthropicMessagesAdapter: AIProviderAdapter {
    let protocolKind = AIProtocolKind.anthropicMessages

    func makeRequest(configuration: AIConnectionConfiguration, apiKey: String, messages: [AIMessage], options: AIRequestOptions, timeout: TimeInterval) throws -> URLRequest {
        let url = try AIEndpointBuilder.url(configuration: configuration, suffix: "messages")
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let conversation = messages.filter { $0.role != "system" }.map { ["role": $0.role == "assistant" ? "assistant" : "user", "content": $0.content] }
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": conversation,
            "max_tokens": AIOutputBudget.anthropicLimit(configuration: configuration, businessDefault: options.maxOutputTokens)
        ]
        if !system.isEmpty { body["system"] = system }
        if let temperature = configuration.temperature { body["temperature"] = temperature }
        return AIEndpointBuilder.request(url: url, apiKey: apiKey, authMode: configuration.authMode, kind: protocolKind, timeout: timeout, body: try AIEndpointBuilder.body(body))
    }

    func parseResponse(_ data: Data) throws -> AICompletion {
        let root = try jsonObject(data)
        let blocks = root["content"] as? [[String: Any]] ?? []
        var texts: [String] = []
        var refusal: String?
        for block in blocks {
            if block["type"] as? String == "text", let text = block["text"] as? String { texts.append(text) }
            if block["type"] as? String == "refusal", let text = block["text"] as? String { refusal = text }
        }
        let stopReason = root["stop_reason"] as? String
        let text = texts.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || refusal != nil else { throw AIError.emptyResponse }
        if stopReason == "max_tokens" { throw AIError.truncatedResponse }
        let usage = (root["usage"] as? [String: Any]).map {
            AIUsage(inputTokens: integer($0["input_tokens"]), outputTokens: integer($0["output_tokens"]))
        }
        return AICompletion(text: refusal ?? text, usage: usage, refusal: refusal ?? (stopReason == "refusal" ? text : nil))
    }
}

private struct GeminiGenerateContentAdapter: AIProviderAdapter {
    let protocolKind = AIProtocolKind.geminiGenerateContent

    func makeRequest(configuration: AIConnectionConfiguration, apiKey: String, messages: [AIMessage], options: AIRequestOptions, timeout: TimeInterval) throws -> URLRequest {
        let url = try AIEndpointBuilder.url(configuration: configuration, suffix: "models/\(configuration.model):generateContent")
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let contents: [[String: Any]] = messages.filter { $0.role != "system" }.map { message in
            ["role": message.role == "assistant" ? "model" : "user", "parts": [["text": message.content]]]
        }
        var body: [String: Any] = ["contents": contents]
        if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        var generation: [String: Any] = [:]
        if let limit = options.maxOutputTokens { generation["maxOutputTokens"] = limit }
        if let temperature = configuration.temperature { generation["temperature"] = temperature }
        if options.structuredOutputRequested && configuration.useNativeJSONMode { generation["responseMimeType"] = "application/json" }
        if !generation.isEmpty { body["generationConfig"] = generation }
        return AIEndpointBuilder.request(url: url, apiKey: apiKey, authMode: configuration.authMode, kind: protocolKind, timeout: timeout, body: try AIEndpointBuilder.body(body))
    }

    func parseResponse(_ data: Data) throws -> AICompletion {
        let root = try jsonObject(data)
        if let reason = (root["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            let message = "请求被 Gemini 安全策略拦截（\(reason)）。"
            return AICompletion(text: message, usage: parseGeminiUsage(root["usageMetadata"]), refusal: message)
        }
        let candidates = root["candidates"] as? [[String: Any]] ?? []
        guard let candidate = candidates.first else { throw AIError.emptyResponse }
        let finishReason = candidate["finishReason"] as? String
        if finishReason == "MAX_TOKENS" { throw AIError.truncatedResponse }
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        if let refusal = candidate["finishMessage"] as? String, finishReason == "SAFETY" { return AICompletion(text: refusal, usage: parseGeminiUsage(root["usageMetadata"]), refusal: refusal) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIError.emptyResponse }
        return AICompletion(text: text, usage: parseGeminiUsage(root["usageMetadata"]), refusal: nil)
    }
}

protocol AIHTTPTransporting {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAITransport: AIHTTPTransporting {
    var session: URLSession = .shared
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.networkFailure }
        return (data, http)
    }
}

struct AIHTTPTransport {
    var underlying: any AIHTTPTransporting
    var baseRetryDelaySeconds: Double = 1

    func data(for request: URLRequest, maxRetryCount: Int) async throws -> (Data, HTTPURLResponse) {
        let retryLimit = max(0, maxRetryCount)
        var lastRetryStatus = 0
        for attempt in 0...retryLimit {
            try Task.checkCancellation()
            do {
                let (data, response) = try await underlying.data(for: request)
                if response.statusCode == 429 || (500...599).contains(response.statusCode) {
                    lastRetryStatus = response.statusCode
                    guard attempt < retryLimit else {
                        throw response.statusCode == 429 ? AIError.rateLimited : AIError.httpFailure(status: response.statusCode)
                    }
                    let delay = retryDelay(response: response, attempt: attempt)
                    // Do not retry early when the server asks for a longer wait. Surface the
                    // rate limit instead of silently violating Retry-After or sleeping indefinitely.
                    guard delay <= 30 else {
                        throw response.statusCode == 429 ? AIError.rateLimited : AIError.httpFailure(status: response.statusCode)
                    }
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                guard (200..<300).contains(response.statusCode) else {
                    throw classifyHTTPError(status: response.statusCode, data: data)
                }
                return (data, response)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AIError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard attempt < retryLimit, isRecoverableNetworkError(error) else {
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut { throw AIError.timeout }
                    throw AIError.networkFailure
                }
                try await Task.sleep(for: .seconds(min(baseRetryDelaySeconds * pow(2, Double(attempt)), 15)))
            }
        }
        throw AIError.httpFailure(status: lastRetryStatus)
    }

    private func retryDelay(response: HTTPURLResponse, attempt: Int) -> Double {
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Double(raw) { return max(0, seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSinceNow) }
        }
        return baseRetryDelaySeconds * pow(2, Double(attempt))
    }

    private func isRecoverableNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet].contains(nsError.code)
    }
}

enum AIError: LocalizedError {
    case missingAPIKey
    case invalidConfiguration(String)
    case authenticationFailed
    case endpointNotFound
    case modelUnavailable
    case incompatibleParameters
    case rateLimited
    case timeout
    case networkFailure
    case httpFailure(status: Int)
    case responseParseFailed(String)
    case emptyResponse
    case truncatedResponse
    case outputBudgetReached(limit: Int, settingName: String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请填写当前 AI 服务的 API Key，或明确选择无需鉴权。"
        case .invalidConfiguration(let message): return message
        case .authenticationFailed: return "当前 AI 服务鉴权失败，请检查 API Key 和服务地址。"
        case .endpointNotFound: return "当前 AI 服务找不到该接口，请检查协议和 API 根地址。"
        case .modelUnavailable: return "当前 AI 服务无法使用此模型 ID；请检查模型名和账户权限。"
        case .incompatibleParameters: return "服务拒绝了请求参数；可检查输出 token 参数、temperature 或结构化输出设置。"
        case .rateLimited: return "当前 AI 服务限流，请稍后重试。"
        case .timeout: return "连接当前 AI 服务超时。"
        case .networkFailure: return "无法连接当前 AI 服务，请检查网络和地址。"
        case .httpFailure(let status): return "当前 AI 服务返回 HTTP \(status)。"
        case .responseParseFailed(let reason): return "无法解析当前 AI 服务的响应：\(reason)"
        case .emptyResponse: return "当前 AI 服务没有返回可用文本。"
        case .truncatedResponse: return "当前 AI 服务的输出达到 token 上限，内容可能不完整；请提高上限后重试。"
        case .outputBudgetReached(let limit, let settingName):
            return "响应达到实际输出预算 \(limit) token（\(settingName)）。可提高此预算后重试；这只是最大值，模型也可能提前结束。"
        case .invalidJSON(let reason): return "当前 AI 服务返回的结构化结果无法解析：\(reason)"
        }
    }
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    do {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.responseParseFailed("响应顶层不是 JSON 对象。") }
        return object
    } catch let error as AIError { throw error }
    catch { throw AIError.responseParseFailed("响应不是有效 JSON。") }
}

private func extractText(_ value: Any?) -> String {
    if let text = value as? String { return text }
    if let blocks = value as? [[String: Any]] {
        return blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String, ["text", "output_text"].contains(type) else { return nil }
            return block["text"] as? String
        }.joined()
    }
    return ""
}

private func integer(_ value: Any?) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return 0
}

private func parseOpenAIUsage(_ value: Any?) -> AIUsage? {
    guard let usage = value as? [String: Any] else { return nil }
    let input = usage["prompt_tokens"] ?? usage["input_tokens"]
    let output = usage["completion_tokens"] ?? usage["output_tokens"]
    guard input != nil || output != nil else { return nil }
    return AIUsage(inputTokens: integer(input), outputTokens: integer(output))
}

private func parseGeminiUsage(_ value: Any?) -> AIUsage? {
    guard let usage = value as? [String: Any], usage["promptTokenCount"] != nil || usage["candidatesTokenCount"] != nil else { return nil }
    return AIUsage(inputTokens: integer(usage["promptTokenCount"]), outputTokens: integer(usage["candidatesTokenCount"]))
}

private func classifyHTTPError(status: Int, data: Data) -> AIError {
    if status == 401 || status == 403 { return .authenticationFailed }
    if status == 429 { return .rateLimited }
    let code: String? = {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = body["error"] as? [String: Any] else { return nil }
        return (error["code"] as? String ?? error["type"] as? String)?.lowercased()
    }()
    if status == 404 {
        return ["model_not_found", "model_not_available", "invalid_model"].contains(code ?? "") ? .modelUnavailable : .endpointNotFound
    }
    if status == 400 || status == 422 {
        if ["model_not_found", "model_not_available", "invalid_model"].contains(code ?? "") { return .modelUnavailable }
        return .incompatibleParameters
    }
    return .httpFailure(status: status)
}
