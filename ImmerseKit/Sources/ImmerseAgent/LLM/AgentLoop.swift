import Foundation
import ImmerseCore

/// Runs the model with the toolbox until it proposes a plan, answers in text, or runs out of turns.
/// The assistant's content (including thinking blocks) is appended back unchanged every turn.
@MainActor
public final class AgentLoop {
    public struct Outcome: Sendable {
        public var proposal: PlanProposal?
        public var pendingMemories: [MemorySnapshot]
        /// The model's closing text, when it answered instead of proposing
        public var text: String
        public var usage: LLMUsage
        public var turns: Int
    }

    private let provider: LLMProvider
    private let maxTurns: Int
    private let timeout: Duration

    public init(provider: LLMProvider, maxTurns: Int = 8, timeout: Duration = .seconds(60)) {
        self.provider = provider
        self.maxTurns = maxTurns
        self.timeout = timeout
    }

    public func run(system: String, userMessage: String, toolbox: AgentToolbox, effort: String = "medium") async throws -> Outcome {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var messages: [JSONValue] = [["role": "user", "content": .string(userMessage)]]
        var usage = LLMUsage()
        var lastText = ""
        for turn in 1...maxTurns {
            guard ContinuousClock.now < deadline else { throw LLMError.timeout }
            let response = try await provider.send(LLMRequest(system: system, messages: messages,
                                                              tools: AgentToolbox.definitions, effort: effort))
            usage = usage + response.usage
            messages.append(["role": "assistant", "content": .array(response.content)])
            lastText = response.text.isEmpty ? lastText : response.text

            switch response.stopReason {
            case "refusal":
                throw LLMError.refusal
            case "max_tokens":
                throw LLMError.truncated
            case "pause_turn":
                // The server paused a long turn; sending the conversation back lets it continue
                continue
            case "tool_use":
                let uses = response.toolUses
                // Every tool_use gets its result, all in one user message (keeps parallel tool use working)
                var results: [JSONValue] = []
                for use in uses {
                    let (result, isError) = toolbox.execute(name: use.name, input: use.input)
                    var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(use.id),
                                                      "content": .string(result.string ?? result.jsonString)]
                    if isError { block["is_error"] = true }
                    results.append(.object(block))
                }
                if toolbox.isFinished {
                    return Outcome(proposal: toolbox.proposal, pendingMemories: toolbox.pendingMemories,
                                   text: lastText, usage: usage, turns: turn)
                }
                messages.append(["role": "user", "content": .array(results)])
            default:
                return Outcome(proposal: toolbox.proposal, pendingMemories: toolbox.pendingMemories,
                               text: lastText, usage: usage, turns: turn)
            }
        }
        return Outcome(proposal: toolbox.proposal, pendingMemories: toolbox.pendingMemories, text: lastText,
                       usage: usage, turns: maxTurns)
    }
}

/// System prompts. Kept constant (no dates, no user data) so the cached prefix stays valid; per-request facts
/// go into the user message.
public enum Prompts {
    public static let planner = """
    你是「沉浸日程 Immerse」里的私人日程秘书。你帮用户把待办安排进日历、在计划被打乱时重排，并说明理由。

    工作方式：
    - 先用工具了解情况：list_tasks 看任务，find_free_slots 找空档，需要数字时用 get_insights，安排前用 read_memory 看用户的固定安排。
    - 所有数字（时长、负载、完成率、空档）都只能来自工具结果，不要自己估算或编造。
    - 用 create_task / update_task 把改动加进草稿，每一项都要写一句中文理由（reason），说明为什么放在那里。
    - 草稿完成后调用一次 propose_plan 结束。草稿只是提案，用户确认后才会写入。
    - 不要删除任务；不要移动带地点（fixed）的日程和系统日历里的会议；不要排进用户记忆里的固定时段。
    - 难的任务（effort = hard）优先放进 energy_score 高的空档；有截止日期的任务必须在截止前完成并留出余量。
    - 同一天不要排满：负载超过 capacity_minutes 时，宁可往后挪。
    - 如果没有需要改动的，就不要调用 propose_plan，直接用一两句中文说明原因。
    - 用户说「记住……」时，用 write_memory 记下来。
    """

    public static let capture = """
    你把用户随口说的一句话整理成结构化的待办。规则：
    - 说的是具体时间要做的事 → kind = event，给出 start（ISO 8601，带时区）；只说了日期没说几点 → all_day = true。
    - 没有时间、只是个想法或待办 → kind = idea。
    - 「本周目标」「本月目标」「这个月要……」→ kind = goal，goal_period = week / month。
    - minutes 是预计要花的时间；没说就按常识估计（会议 30–60，阅读 45–60，写作 60–90）。
    - priority：「急」「马上」「今天必须」→ urgent；「重要」→ important；否则 normal。
    - category 从给定枚举里选最贴近的；effort：需要整块精力的为 hard，杂事为 light。
    - 标题简洁，去掉时间、时长、优先级这些已经结构化的词，保留原意。
    - 预计超过 3 小时、或明显需要多次完成的（写报告、准备汇报、搭系统），is_large = true，并在 subtasks 里给出 2–6 个具体子任务。
    - 一句话里有多件事就拆成多条 items。
    """

    public static let split = """
    你把一个大任务拆成 2–6 个可以在一次专注（25–90 分钟）里完成的具体子任务。
    子任务要具体、可执行、按先后顺序排列，标题用中文、简短。minutes 是每个子任务的预计时长。
    """

    public static let memory = """
    你把用户想让秘书记住的话整理成一条记忆。
    - 每周固定的时间安排（「周三晚上打球」「每天中午午休」）→ kind = rule，给出 weekdays（1 = 周日 … 7 = 周六）、start_time 和 end_time（HH:mm）；没说具体几点就按常识（晚上 19:00–21:00，中午 12:00–13:30）。
    - 偏好（「喜欢上午写东西」）→ kind = preference；其他背景信息 → kind = fact，这两种不需要时间。
    - text 用一句简洁的中文描述，例如「每周三 19:00–21:00 打球」。
    """

    public static let review = """
    你是用户的日程秘书，在晚上帮他复盘今天。根据给出的数据，用 2–3 句自然的中文总结今天，语气温和、具体，
    不要罗列数据，不要说教，不要用表情符号。只使用给出的数字。
    """

    public static let morning = """
    你是用户的日程秘书，早上给他一句简报。根据给出的数据，用 1–2 句自然的中文说今天最该关注的事，具体、简短。只使用给出的数字。
    """
}
