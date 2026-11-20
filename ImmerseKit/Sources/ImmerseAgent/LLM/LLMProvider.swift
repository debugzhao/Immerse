import Foundation

/// One Messages API request. The caller owns the tool loop (see `AgentLoop`).
public struct LLMRequest: Sendable {
    public var system: String
    /// Raw `messages` array entries ({"role": ..., "content": ...})
    public var messages: [JSONValue]
    /// Tool definitions; empty for single-shot structured calls
    public var tools: [JSONValue]
    /// `output_config.effort`: "low" for capture, "medium" for planning
    public var effort: String
    public var maxTokens: Int
    /// When set, the reply is constrained to this JSON Schema (`output_config.format`)
    public var outputSchema: JSONValue?

    public init(system: String, messages: [JSONValue], tools: [JSONValue] = [], effort: String = "medium",
                maxTokens: Int = 16_000, outputSchema: JSONValue? = nil) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.effort = effort
        self.maxTokens = maxTokens
        self.outputSchema = outputSchema
    }
}

public struct LLMUsage: Codable, Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadInputTokens = 0
    public var cacheCreationInputTokens = 0

    public init() {}

    public static func + (lhs: LLMUsage, rhs: LLMUsage) -> LLMUsage {
        var sum = LLMUsage()
        sum.inputTokens = lhs.inputTokens + rhs.inputTokens
        sum.outputTokens = lhs.outputTokens + rhs.outputTokens
        sum.cacheReadInputTokens = lhs.cacheReadInputTokens + rhs.cacheReadInputTokens
        sum.cacheCreationInputTokens = lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens
        return sum
    }
}

public struct LLMResponse: Sendable {
    /// Raw content blocks, sent back unchanged as the assistant turn
    public var content: [JSONValue]
    /// end_turn / tool_use / max_tokens / refusal / pause_turn
    public var stopReason: String
    public var usage: LLMUsage
    public var model: String

    public init(content: [JSONValue], stopReason: String, usage: LLMUsage = LLMUsage(), model: String = "") {
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
        self.model = model
    }

    /// All text blocks joined
    public var text: String {
        content.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
    }

    public var toolUses: [(id: String, name: String, input: JSONValue)] {
        content.compactMap { block in
            guard block["type"]?.string == "tool_use", let id = block["id"]?.string, let name = block["name"]?.string else { return nil }
            return (id, name, block["input"] ?? [:])
        }
    }
}

public enum LLMError: Error, Equatable, LocalizedError {
    case missingKey
    case invalidKey
    case rateLimited
    case overloaded
    case server(status: Int, message: String)
    case network(String)
    case refusal
    case truncated
    case invalidResponse
    case timeout

    public var errorDescription: String? {
        switch self {
        case .missingKey: "还没有填写 API Key"
        case .invalidKey: "API Key 无效，请在设置里重新填写"
        case .rateLimited: "请求太频繁，稍后再试"
        case .overloaded: "服务繁忙，稍后再试"
        case .server(let status, let message): "服务出错（\(status)）：\(message)"
        case .network(let message): "网络错误：\(message)"
        case .refusal: "模型拒绝了这个请求"
        case .truncated: "回复太长被截断了"
        case .invalidResponse: "无法理解模型的回复"
        case .timeout: "请求超时"
        }
    }

    /// Worth retrying the same request after a short wait
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .network, .timeout: true
        case .server(let status, _): status >= 500
        default: false
        }
    }
}

/// One Messages API round trip. Implementations: `AnthropicHTTPProvider` (direct, user's key), tests' mocks,
/// and later a proxy-backed provider (§11 option A).
public protocol LLMProvider: Sendable {
    func send(_ request: LLMRequest) async throws -> LLMResponse
}
