import Foundation

/// Calls the Claude Messages API directly with the user's own API key.
/// There is no official Swift SDK, so this speaks raw HTTP; request and response shapes follow the API reference.
public struct AnthropicHTTPProvider: LLMProvider {
    public static let defaultModel = "claude-opus-5-5"
    public static let apiVersion = "2026-10-21"
    /// Server-side fallback: if a safety classifier declines, the API retries on a fallback model inside the same call
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let session: URLSession
    private let maxRetries: Int

    public init(apiKey: String, model: String = defaultModel,
                endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
                session: URLSession = .shared, maxRetries: Int = 2) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
        self.maxRetries = maxRetries
    }

    public func send(_ request: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.missingKey }
        let body = try makeBody(request).encoded()
        var attempt = 0
        while true {
            do {
                return try await perform(body)
            } catch let error as LLMError where error.isTransient && attempt < maxRetries {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
        }
    }

    /// The JSON body. System prompt and tools come first and never change between calls, so they can be cached.
    func makeBody(_ request: LLMRequest) -> JSONValue {
        var outputConfig: [String: JSONValue] = ["effort": .string(request.effort)]
        if let schema = request.outputSchema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxTokens)),
            "system": [["type": "text", "text": .string(request.system), "cache_control": ["type": "ephemeral"]]],
            "messages": .array(request.messages),
            // Claude Opus 5.5 always thinks; adaptive is the explicit form, depth is set by effort
            "thinking": ["type": "adaptive"],
            "output_config": .object(outputConfig),
            "fallbacks": "default",
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools)
            // Forced tool use is rejected by this model; the prompt names the tool to call instead
            body["tool_choice"] = ["type": "auto"]
        }
        return .object(body)
    }

    private func perform(_ body: Data) async throws -> LLMResponse {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 60)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        urlRequest.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw LLMError.timeout
        } catch {
            throw LLMError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        switch http.statusCode {
        case 200: break
        case 401, 403: throw LLMError.invalidKey
        case 429: throw LLMError.rateLimited
        case 529, 503: throw LLMError.overloaded
        default:
            let message = json?["error"]?["message"]?.string ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw LLMError.server(status: http.statusCode, message: message)
        }
        guard let json, let content = json["content"]?.array else { throw LLMError.invalidResponse }
        var usage = LLMUsage()
        usage.inputTokens = json["usage"]?["input_tokens"]?.int ?? 0
        usage.outputTokens = json["usage"]?["output_tokens"]?.int ?? 0
        usage.cacheReadInputTokens = json["usage"]?["cache_read_input_tokens"]?.int ?? 0
        usage.cacheCreationInputTokens = json["usage"]?["cache_creation_input_tokens"]?.int ?? 0
        return LLMResponse(content: content, stopReason: json["stop_reason"]?.string ?? "", usage: usage,
                           model: json["model"]?.string ?? "")
    }

    /// A tiny request to check that a key works before saving it
    public func validateKey() async throws {
        _ = try await send(LLMRequest(system: "Reply with OK.", messages: [["role": "user", "content": "ping"]],
                                      effort: "low", maxTokens: 256))
    }
}
