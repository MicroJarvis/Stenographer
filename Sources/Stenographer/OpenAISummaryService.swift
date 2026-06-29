import Foundation
import Security

enum OpenAISummaryError: LocalizedError {
    case notConfigured
    case invalidBaseURL
    case requestFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "请先在“引擎”里设置 OpenAI Base URL 和 API Key。"
        case .invalidBaseURL:
            "OpenAI Base URL 格式不正确。"
        case .requestFailed(let message):
            message
        case .emptyResponse:
            "OpenAI 没有返回可用的整理内容。"
        }
    }
}

private enum OpenAISummaryEndpoint {
    case responses(URL)
    case chatCompletions(URL)

    var url: URL {
        switch self {
        case .responses(let url), .chatCompletions(let url):
            url
        }
    }

    var label: String {
        switch self {
        case .responses:
            "Responses"
        case .chatCompletions:
            "Chat Completions"
        }
    }
}

private struct OpenAISummaryHTTPError: Error {
    var statusCode: Int
    var endpoint: OpenAISummaryEndpoint
    var message: String
}

@MainActor
final class OpenAISummaryService: ObservableObject {
    @Published var baseURL: String
    @Published var modelName: String
    @Published var apiKeyDraft: String
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "未配置"

    private let defaults = UserDefaults.standard
    private let baseURLKey = "Stenographer.OpenAI.baseURL"
    private let modelNameKey = "Stenographer.OpenAI.modelName"
    private let keychainService = "Stenographer.OpenAISummary"
    private let legacyBaseURLKey = "VoiceTransform.OpenAI.baseURL"
    private let legacyModelNameKey = "VoiceTransform.OpenAI.modelName"
    private let legacyKeychainService = "VoiceTransform.OpenAISummary"
    private let keychainAccount = "apiKey"

    init() {
        let migratedBaseURL = defaults.string(forKey: baseURLKey) ?? defaults.string(forKey: legacyBaseURLKey)
        let migratedModelName = defaults.string(forKey: modelNameKey) ?? defaults.string(forKey: legacyModelNameKey)
        let migratedAPIKey = KeychainStore.read(service: keychainService, account: keychainAccount)
            ?? KeychainStore.read(service: legacyKeychainService, account: keychainAccount)

        baseURL = migratedBaseURL ?? "https://api.openai.com/v1"
        modelName = migratedModelName ?? "gpt-5.5"
        apiKeyDraft = migratedAPIKey ?? ""
        if defaults.string(forKey: baseURLKey) == nil, migratedBaseURL != nil {
            defaults.set(baseURL, forKey: baseURLKey)
        }
        if defaults.string(forKey: modelNameKey) == nil, migratedModelName != nil {
            defaults.set(modelName, forKey: modelNameKey)
        }
        if KeychainStore.read(service: keychainService, account: keychainAccount) == nil,
           let migratedAPIKey,
           !migratedAPIKey.isEmpty {
            KeychainStore.write(migratedAPIKey, service: keychainService, account: keychainAccount)
        }
        statusText = apiKeyDraft.isEmpty ? "未配置" : "就绪"
    }

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveSettings() {
        baseURL = sanitizedBaseURLString(baseURL)
        modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKeyDraft = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        defaults.set(baseURL, forKey: baseURLKey)
        defaults.set(modelName, forKey: modelNameKey)
        if apiKeyDraft.isEmpty {
            KeychainStore.delete(service: keychainService, account: keychainAccount)
            statusText = "未配置"
        } else {
            KeychainStore.write(apiKeyDraft, service: keychainService, account: keychainAccount)
            statusText = "就绪"
        }
    }

    func summarize(meeting: Meeting, entries: [TranscriptEntry], speakerNames: [UUID: String]) async throws -> [SummaryPoint] {
        saveSettings()
        guard isConfigured else {
            throw OpenAISummaryError.notConfigured
        }
        let endpoints = summaryEndpointCandidates()
        guard !endpoints.isEmpty else {
            throw OpenAISummaryError.invalidBaseURL
        }

        isRunning = true
        statusText = "OpenAI 整理中"
        defer { isRunning = false }

        let transcript = Self.transcriptText(from: entries, speakerNames: speakerNames)
        let prompt = Self.prompt(meeting: meeting, transcript: transcript)
        var lastHTTPError: OpenAISummaryHTTPError?

        do {
            for endpoint in endpoints {
                do {
                    let content = try await sendSummaryRequest(endpoint: endpoint, prompt: prompt)
                    let summary = try Self.summaryPoints(from: content)
                    statusText = "已整理"
                    return summary
                } catch let error as OpenAISummaryHTTPError {
                    lastHTTPError = error
                    if shouldTryNextEndpoint(after: error, current: endpoint, endpoints: endpoints) {
                        continue
                    }
                    throw Self.summaryError(from: error)
                }
            }

            if let lastHTTPError {
                throw Self.summaryError(from: lastHTTPError)
            }
            throw OpenAISummaryError.emptyResponse
        } catch let error as OpenAISummaryError {
            statusText = "整理失败"
            throw error
        } catch {
            statusText = "整理失败"
            throw OpenAISummaryError.requestFailed(error.localizedDescription)
        }
    }

    private func sendSummaryRequest(endpoint: OpenAISummaryEndpoint, prompt: String) async throws -> String {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKeyDraft)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(endpoint: endpoint, prompt: prompt))
        statusText = "OpenAI 整理中 · \(endpoint.label)"

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            let message = Self.errorMessage(from: data) ?? "OpenAI 整理失败，HTTP \(statusCode)。"
            throw OpenAISummaryHTTPError(statusCode: statusCode, endpoint: endpoint, message: message)
        }

        switch endpoint {
        case .responses:
            return try Self.responseContent(from: data)
        case .chatCompletions:
            return try Self.messageContent(from: data)
        }
    }

    private func requestBody(endpoint: OpenAISummaryEndpoint, prompt: String) -> [String: Any] {
        switch endpoint {
        case .responses:
            return [
                "model": modelName,
                "instructions": "你是一个严谨的中文会议纪要助手。只输出合法 JSON，不要输出 Markdown。",
                "input": prompt,
                "text": [
                    "format": [
                        "type": "json_object"
                    ]
                ]
            ]
        case .chatCompletions:
            return [
                "model": modelName,
                "messages": [
                    [
                        "role": "system",
                        "content": "你是一个严谨的中文会议纪要助手。只输出合法 JSON，不要输出 Markdown。"
                    ],
                    [
                        "role": "user",
                        "content": prompt
                    ]
                ],
                "response_format": [
                    "type": "json_object"
                ]
            ]
        }
    }

    private func summaryEndpointCandidates() -> [OpenAISummaryEndpoint] {
        let trimmed = sanitizedBaseURLString(baseURL)
        guard let components = URLComponents(string: trimmed) else { return [] }
        let pathParts = components.path
            .split(separator: "/")
            .map(String.init)
        let lowerPathParts = pathParts.map { $0.lowercased() }

        if lowerPathParts.suffix(1) == ["responses"] {
            return components.url.map { [.responses($0)] } ?? []
        }
        if lowerPathParts.suffix(2) == ["chat", "completions"] {
            return components.url.map { [.chatCompletions($0)] } ?? []
        }

        var candidates: [OpenAISummaryEndpoint] = []
        if lowerPathParts.last == "v1" {
            candidates.append(.responses(url(from: components, appending: ["responses"])))
            candidates.append(.chatCompletions(url(from: components, appending: ["chat", "completions"])))
        } else {
            candidates.append(.responses(url(from: components, appending: ["v1", "responses"])))
            candidates.append(.chatCompletions(url(from: components, appending: ["v1", "chat", "completions"])))
            candidates.append(.responses(url(from: components, appending: ["responses"])))
            candidates.append(.chatCompletions(url(from: components, appending: ["chat", "completions"])))
        }
        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = candidate.url.absoluteString
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func url(from components: URLComponents, appending pathParts: [String]) -> URL {
        var updated = components
        let existingPath = updated.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = ([existingPath] + pathParts)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        updated.path = "/" + joinedPath
        return updated.url ?? URL(string: sanitizedBaseURLString(baseURL))!
    }

    private func shouldTryNextEndpoint(
        after error: OpenAISummaryHTTPError,
        current: OpenAISummaryEndpoint,
        endpoints: [OpenAISummaryEndpoint]
    ) -> Bool {
        guard current.url != endpoints.last?.url else { return false }
        return error.statusCode == 404 || error.statusCode == 405
    }

    private static func summaryError(from error: OpenAISummaryHTTPError) -> OpenAISummaryError {
        let path = error.endpoint.url.path.isEmpty ? "/" : error.endpoint.url.path
        return .requestFailed("\(error.message)\n接口：\(error.endpoint.label) \(path)")
    }

    private func sanitizedBaseURLString(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func transcriptText(from entries: [TranscriptEntry], speakerNames: [UUID: String]) -> String {
        entries.map { entry in
            let speaker = speakerNames[entry.speakerID] ?? "未知说话人"
            let text = entry.translation.isEmpty ? entry.original : entry.translation
            return "[\(entry.time)] \(speaker)：\(text)"
        }
        .joined(separator: "\n")
        .prefixString(16_000)
    }

    private static func prompt(meeting: Meeting, transcript: String) -> String {
        """
        请基于下面的会议转写生成中文会议纪要。

        会议标题：\(meeting.title)
        会议时长：\(meeting.duration)

        要求：
        1. 总结整场会议的主题、主要结论、关键分歧和后续动作。
        2. 尽量按说话人归纳观点。
        3. 不要编造转写中没有的信息。
        4. 输出严格 JSON，格式为：
        {"summary":[{"speaker":"会议结论","title":"主题概览","detail":"..."},{"speaker":"说话人或事项","title":"...","detail":"..."}]}

        会议转写：
        \(transcript)
        """
    }

    private static func messageContent(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenAISummaryError.emptyResponse
        }
        return content
    }

    private static func responseContent(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAISummaryError.emptyResponse
        }

        if let outputText = object["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        if let output = object["output"] as? [[String: Any]] {
            let texts = output.flatMap { item -> [String] in
                guard let content = item["content"] as? [[String: Any]] else { return [] }
                return content.compactMap { part in
                    if let text = part["text"] as? String {
                        return text
                    }
                    if let text = part["output_text"] as? String {
                        return text
                    }
                    return nil
                }
            }
            let content = texts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !content.isEmpty {
                return content
            }
        }

        throw OpenAISummaryError.emptyResponse
    }

    private static func summaryPoints(from content: String) throws -> [SummaryPoint] {
        let jsonText = extractJSONObject(from: content) ?? content
        guard let data = jsonText.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["summary"] as? [[String: Any]] else {
            return [
                SummaryPoint(
                    id: UUID(),
                    speaker: "会议结论",
                    title: "OpenAI 整理结果",
                    detail: content.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            ]
        }

        let points = items.compactMap { item -> SummaryPoint? in
            guard let detail = item["detail"] as? String,
                  !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SummaryPoint(
                id: UUID(),
                speaker: (item["speaker"] as? String)?.nilIfBlank ?? "会议结论",
                title: (item["title"] as? String)?.nilIfBlank ?? "整理要点",
                detail: detail
            )
        }
        if points.isEmpty {
            throw OpenAISummaryError.emptyResponse
        }
        return points
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8)
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        return String(text[start...end])
    }
}

private enum KeychainStore {
    static func read(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        let query = baseQuery(service: service, account: account)
        let attributes = [kSecValueData as String: data]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func prefixString(_ count: Int) -> String {
        guard self.count > count else { return self }
        return String(prefix(count))
    }
}
