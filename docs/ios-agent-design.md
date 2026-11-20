# Immerse iOS · 私人日程秘书 设计文档

> 版本：v0.1（草案，待确认）· 日期：2026-11-20
> 范围：iPhone 版 Immerse + 两端共用的 Agent 层。Mac 版的现状见 [TECH_DESIGN.md](TECH_DESIGN.md)

## 0. 结论先行

**iPhone 版用原生 SwiftUI 开发，最低支持 iOS 17，与 Mac 版共用本地 Swift Package `ImmerseKit`。秘书能力分三层：确定性算法负责计算，LLM 负责理解和表达，提案机制负责把关。** 任何改动日程的操作，都先生成一份 `PlanProposal`，以幽灵日程的形式预览，用户确认后作为一次可撤销的事务写入。

| 关键决策 | 选择 | 一句话理由 |
|---|---|---|
| 代码共享 | 本地 Package `ImmerseKit`，分 `ImmerseCore` 和 `ImmerseAgent` 两个 target | 两端只写一次模型、算法和 Agent；Package 里禁止 import AppKit/UIKit，从编译层面隔离平台代码 |
| 数据同步 | SwiftData + CloudKit 私有库，存储放在 App Group 容器 | 免服务器、免账号；小组件、Live Activity、App Intents 都能读同一份数据 |
| 秘书怎么“算” | 空档、过载、截止风险、估时、能量曲线、重排都放在 `ImmerseAgent` 的纯函数里，全部写单测 | 数字可验证、可解释，AI 关闭时大部分功能照样可用 |
| 秘书怎么“想” | Claude API 的 tool use，LLM 只能看到只读工具和“草稿提案”工具 | LLM 无法直接写数据，从机制上保证“先提案，用户拍板” |
| LLM 接入 | `LLMProvider` 协议，iOS 端直接走 HTTP 调用 `POST /v1/messages`（Claude 没有官方 Swift SDK）；**用户自己填 API Key，存在 Keychain 里** | 可替换、零后端；以后要加代理只需新增一个 `ProxyProvider` |
| AI 开关 | **默认开启**；第一次调用模型前需要用户同意一次数据说明 | 开箱就有秘书能力，同时满足审核对第三方 AI 的告知要求 |
| 主动行为 | 预排的本地通知（带 action）+ BGAppRefreshTask 刷新通知内容 + 每天的推送预算 | iOS 不允许 App 常驻后台，审核时也不能靠保活 |
| 交互风格 | 沿用 Mac 版的毛玻璃、Palette 和日程块样式；先设 `UIDesignRequiresCompatibility = YES` | 先保持视觉一致，以后切到 Liquid Glass 只改 `GlassSurface` 一处 |

**能复用的部分比预想的多**：Mac 版已经有 `DailyPlan.freeSlots`（找空档）、`DailyReview`（晚间复盘提醒）、`GoalProgress.isBehind`（目标落后判断）、`NaturalLanguageParser`（规则解析），`TaskStore` 也已经基于 `UndoManager` 支持撤销。秘书的算法大多是在这些代码上扩展，而不是从零写。

---

## 1. 架构

### 1.1 总览

```
┌──────────────────────────── ImmerseiOS (App) ─────────────────────────────┐
│ Tab: 日程 · 规划 · 专注 · 统计       「+」收集面板（文字/语音/粘贴）        │
│ 幽灵预览层 ProposalOverlay          秘书卡片（晨间简报 / 复盘 / 预警）       │
│ iOS 适配：Haptics · fullScreenCover · Speech · PasteButton · EventKit      │
└───────┬───────────────────────────────────────────────────────┬───────────┘
        │                                                       │
┌───────▼──────────┐ ┌──────────────────┐ ┌────────────────────▼──────────┐
│ Widget Extension │ │ Live Activity    │ │ App Intents（Siri / 操作按钮 / │
│ 今天 · 完成/开始 │ │ 专注倒计时+灵动岛 │ │ 小组件按钮 / 快捷指令）        │
└───────┬──────────┘ └────────┬─────────┘ └────────────────────┬──────────┘
        └─────────────────────┼────────────────────────────────┘
                              │ 共享 App Group 容器（SwiftData store）
┌─────────────────────────────▼──── ImmerseKit (Swift Package) ─────────────┐
│ ImmerseAgent                                                              │
│  ├ Tools        list_tasks · find_free_slots · get_insights · propose_plan │
│  ├ Engines      SlotFinder · Scheduler · Reflow · Load · DeadlineRisk ·    │
│  │              Calibration · EnergyCurve · GoalBreakdown · Briefing       │
│  ├ Proposal     PlanProposal · ProposalValidator · ProposalApplier         │
│  ├ Conductor    AgentLoop（tool use 循环）· CaptureParser · NudgeBudget     │
│  └ LLM          LLMProvider 协议 · AnthropicHTTPProvider · RuleOnlyProvider │
│ ImmerseCore                                                               │
│  Models · Repositories · TaskStore · FocusEngine(核心) · Settings ·       │
│  EventLayoutEngine · NaturalLanguageParser · GoalProgress · FocusStats     │
└─────────────────────────────▲─────────────────────────────────────────────┘
                              │
┌─────────────────────────────┴──── Immerse (macOS App) ────────────────────┐
│ 现有界面 + 菜单栏 + 快捷指令勿扰；以后通过 ImmerseAgent 获得同样的秘书能力  │
└───────────────────────────────────────────────────────────────────────────┘
```

### 1.2 分层规则

| 层 | 可以依赖 | 禁止 |
|---|---|---|
| `ImmerseCore` | Foundation、SwiftData、Observation | AppKit/UIKit/SwiftUI、网络 |
| `ImmerseAgent` | `ImmerseCore`、Foundation（URLSession） | AppKit/UIKit/SwiftUI、EventKit（通过协议注入外部日历数据） |
| App / Extension | 以上全部 + 平台框架 | 在视图里直接操作 `@Model` |

平台相关的依赖都通过协议注入，例如 `ExternalCalendarSource`（EventKit）、`FocusNotifying`（通知）、`HapticsPlaying`。这些协议的实现放在各自的 App target 里。

### 1.3 工程（XcodeGen）

```
project.yml
├ ImmerseKit/                 Package.swift（platforms: iOS 17, macOS 14）
│   ├ Sources/ImmerseCore     从 Immerse/Models、Data、Stores 和纯逻辑搬过来（M0 已完成）
│   ├ Sources/ImmerseAgent    M3 再建
│   └ Tests/…                 现有 ImmerseTests 中的纯逻辑测试随代码迁入
├ Immerse/                    macOS target（只保留界面和系统集成）
├ ImmerseiOS/                 iOS app target
├ ImmerseWidgets/             Widget + Live Activity extension
└ ImmerseIntents/             （可选）App Intents extension，没有必要时先放在 app target 里
```

---

## 2. 数据模型

### 2.1 适配 CloudKit 的改动

| 改动 | 原因 |
|---|---|
| 去掉 `TaskItem.id` 和 `FocusSession.id` 上的 `@Attribute(.unique)` | CloudKit 不支持唯一约束 |
| 所有非可选属性都给默认值；`sessions` 改为 `[FocusSession]?` | CloudKit 要求属性可选或有默认值，关系必须可选 |
| 新增 `DedupeService`：启动时和收到 `NSPersistentStoreRemoteChange` 时，按 `id` 合并重复记录，保留 `updatedAt` 最新的一条 | 去掉唯一约束后，两台设备离线时可能产生重复记录 |
| 保留 `priorityRaw` / `statusRaw` / `kindRaw` 这种 rawValue 写法 | 继续绕开 SwiftData 枚举谓词的问题，iOS 17.0–17.3 上同样需要 |
| 引入 `VersionedSchema`：`SchemaV1` = 现状，`SchemaV2` = CloudKit 版 + 新字段；`MigrationPlan` 对 V1→V2 用 custom stage | 去掉唯一约束、修改关系可选性不保证能轻量迁移，custom stage 更稳妥 |
| store 迁到 App Group 容器（iOS）；Mac 版保持原路径，开启 CloudKit | 让 Extension 可以共享数据 |

⚠️ 生产环境的 CloudKit schema 一旦部署，只能新增字段，不能删除或改名。所以 V2 要把秘书需要的字段一次加齐（见 2.2），上线前在 Development 环境充分验证。

### 2.2 新增字段（TaskItem）

| 字段 | 类型 | 用途 |
|---|---|---|
| `deadline` | `Date?` | 截止日倒推、截止风险。与 `end`（日程结束时间）分开 |
| `categoryRaw` | `String?` | 估时校准、能量曲线按类别统计。取值来自固定集合，例如 `deepWork / reading / writing / meeting / admin / learning / exercise / life`；由 LLM 自动归类，用户可以修改，规则模式下用关键词兜底 |
| `effortRaw` | `Int?` | 难度 1–3，“难的任务排进高效时段” |
| `parentID` | `UUID?` | 大任务拆分后，子任务指向父任务 |
| `sourceRaw` | `String?` | 来源：`manual / voice / clipboard / siri / share / agent`，用于统计各入口的使用情况 |
| `proposalID` | `UUID?` | 由哪份提案写入，用于整体撤销和追溯理由 |

### 2.3 新增模型

```swift
/// Explicit or inferred knowledge about the user. Synced via CloudKit.
@Model final class MemoryItem {
    var id: UUID = UUID()
    var text: String = ""                 // "周三晚上打球" — shown to the user as-is
    var kindRaw: String = "rule"          // rule | preference | fact
    var constraintData: Data?             // Encoded MemoryConstraint, e.g. recurring busy block
    var originRaw: String = "explicit"    // explicit | inferred (inferred ones need confirmation)
    var isActive: Bool = true
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
}

/// Recurring busy block, the only machine-readable constraint in v1.
struct MemoryConstraint: Codable, Sendable {
    var weekdays: Set<Int>   // 1 = Sunday … 7 = Saturday (Calendar.weekday)
    var startMinute: Int     // minutes from midnight
    var endMinute: Int
}

/// Settings the user accepted from insights (e.g. estimate multiplier). One logical row; deduped by `key`.
@Model final class ProfileSetting {
    var key: String = ""     // "estimate.reading", "energy.peakHours", …
    var valueData: Data?
    var updatedAt: Date = Date.now
}
```

- **用户画像不单独存储**：能量曲线、估时偏差、日容量都由 `FocusSession` 实时算出来（纯函数，缓存在内存中），只把用户**确认采纳**的结果写入 `ProfileSetting`。这样避免画像和原始数据不一致。
- **`PlanProposal` 不进 CloudKit**：提案是临时的，只在单台设备上有效，以 JSON 文件存在 App Group 里，带过期时间（默认 24 小时）。
- **推送预算和记录**：存在 UserDefaults（App Group suite）里，只在本机有效。

### 2.4 PlanProposal

```swift
struct PlanProposal: Codable, Identifiable, Sendable {
    enum Origin: String, Codable { case capture, schedule, reflow, review, deadline, goal, overload }
    enum Operation: Codable, Hashable {
        case create(TaskSnapshot)
        case move(id: UUID, start: Date, end: Date?)
        case update(TaskSnapshot)          // full snapshot after the change
        case toInbox(id: UUID)             // unschedule
        case delete(id: UUID)              // never produced by LLM in v1; reserved
    }
    struct Item: Codable, Identifiable, Hashable {
        var id: UUID
        var operation: Operation
        var reason: String                 // one sentence, shown under the ghost block
        var isSelected: Bool = true        // user can untick single items
    }
    var id: UUID
    var origin: Origin
    var summary: String                    // "把 5 条想法排进本周的 4 个空档"
    var items: [Item]
    var warnings: [String]                 // from ProposalValidator: conflicts, overload after apply
    var createdAt: Date
    var expiresAt: Date
}
```

**应用流程**：`ProposalValidator` 先校验（时间冲突、过载、目标任务是否存在），再由 `ProposalApplier` 在一个 `UndoManager` 分组里写入所有选中的项（`TaskStore` 已经有 `UndoManager`，加上 `beginUndoGrouping` 即可），撤销名称为“应用秘书提案”。写入的每条记录都会标上 `proposalID`。

---

## 3. 秘书的三层：确定性引擎 · LLM · 提案

### 3.1 分工

| 能力 | 确定性引擎（ImmerseAgent，需单测） | LLM | 不开 AI 时 |
|---|---|---|---|
| 找空档 | `SlotFinder`：扩展 `DailyPlan.freeSlots`，支持多天，叠加记忆约束、EventKit 忙碌时段、缓冲和能量分 | — | ✅ 完整可用 |
| 一键排期 | `Scheduler`：按截止日、优先级、难度和能量分，贪心地把任务分配到空档 | 选择要排哪些、调整顺序、写理由 | ✅ 规则排期，理由用模板生成 |
| 一键重排 | `Reflow`：从中断点开始顺延，挤不下的移到明天，优先保护固定日程 | 写理由（可选） | ✅ |
| 过载预警 | `LoadEstimator`：已排时长 vs 日容量（近 14 天里有专注的日子，按实际专注分钟数取 P75；数据不足 5 天时用 6h） | 表述 | ✅ |
| 截止风险 | `DeadlineRisk`：剩余需要的时长 × 校准系数 vs 截止前的可用空档 | 写补救方案 | ✅ 模板方案 |
| 估时校准 | `Calibration`：按类别计算实际/计划时长的中位数，样本数不少于 5 才给建议 | 表述 | ✅ |
| 能量曲线 | `EnergyCurve`：按小时统计完成率和专注时长占比，平滑后取 Top 时段 | — | ✅ |
| 目标拆解 | `GoalBreakdown`：目标分钟数 ÷ 剩余周数，得出每周次数和单次时长 | 把“读完 2 本书”换算成目标分钟数 | 🟡 需要手动填目标时长 |
| 专注前简报 | `Briefing`：上次专注的时间和结束方式、备注里没勾选的 `- [ ]` | 一句话总结（可选） | ✅ |
| 一句话收集 | `NaturalLanguageParser`（现有）作为兜底 | 结构化输出：标题、时间、时长、优先级、截止日、类别、难度 | 🟡 规则解析 |
| 大任务拆分 | — | 拆成 2–6 个子任务 | ❌ |
| 晚间复盘 | `DailyReview`（现有）+ `Reflow` + `LoadEstimator` | 一段话总结 | ✅ 模板 |
| 显式记忆 | `MemoryConstraint` 生效 | 把“周三晚上打球”解析成约束 | 🟡 用表单手动填 |

**原则**：LLM 拿到的数字都来自 `get_insights` 等工具，提示词里明确要求“不得自行计算或编造数字”。

### 3.2 LLM 接入

```swift
protocol LLMProvider: Sendable {
    /// One Messages API round trip. The caller owns the tool loop.
    func send(_ request: LLMRequest) async throws -> LLMResponse
}
```

| 实现 | 说明 |
|---|---|
| `AnthropicHTTPProvider` | **v1 使用。** 用 URLSession 调用 `https://api.anthropic.com/v1/messages`，请求头带 `x-api-key`（用户的 Key）和 `anthropic-version`。Claude 没有官方 Swift SDK，iOS 端只能直接走 HTTP；请求和响应的结构以 Anthropic 官方 API 文档为准 |
| `ProxyProvider` | 以后可选：同样的请求体，发到自建的轻量代理（§11 的方案 A） |
| `RuleOnlyProvider` | 不联网，只走规则和模板，用于 AI 关闭、离线和单测 |

**请求约定**（Claude Opus 5.5，`claude-opus-5-5`）：

| 项目 | 设置 | 原因 |
|---|---|---|
| thinking | `{type: "adaptive"}` | Opus 5.5 不能关闭 thinking，用 effort 控制深度 |
| effort | 收集解析 `low`；排期和重排 `medium`；复盘和目标拆解 `medium` | Opus 5.5 默认是 `medium`，显式写出来；收集要求快 |
| 工具调用 | `tool_choice: auto`，每个工具 `strict: true` | Opus 5.5 不支持强制 `tool_choice`（any/tool 会返回 400） |
| 结构化结果 | 收集解析、提案理由用 `output_config.format`（JSON Schema） | 不需要工具循环的场景，直接拿结构化 JSON |
| 拒答兜底 | 开启服务端 `fallbacks: "default"`（beta `server-side-fallback-2026-07-01`），并检查 `stop_reason == "refusal"` | 被安全分类器拒绝时自动降级；仍然失败就退回规则模式 |
| 缓存 | system prompt + 工具定义固定不变并放在最前面，加 `cache_control`；“现在时间、今天概况”放在 user 消息里 | 前缀稳定才能命中缓存 |
| 超时 | 单次 30s；工具循环最多 8 轮，单次任务总共 60s | 超时后退回规则模式，并提示“已按规则排好” |

### 3.3 Agent 工具清单

LLM **看不到**任何直接写数据的工具：`create_task` / `update_task` 只会往“草稿提案”里追加操作，`apply_plan` 和 `start_focus` 只给界面和 App Intents 调用。

| 工具 | LLM 可见 | 入参 | 出参 |
|---|---|---|---|
| `list_tasks` | ✅ | `range_start`, `range_end`（ISO 8601，带时区），`kinds?`，`status?` | `[TaskDTO]`：id、标题、开始和结束时间、时长、优先级、状态、类别、难度、截止日、goal_id、parent_id |
| `find_free_slots` | ✅ | `range_start`, `range_end`, `min_minutes?`（默认 30），`respect_energy?` | `[SlotDTO]`：开始、结束、`energy_score`（0–1） |
| `get_insights` | ✅ | `date?`, `kinds[]`：`load / deadline_risk / calibration / energy / goals_behind` | 各引擎的计算结果，例如 `{planned_min, capacity_min, overload_min}` |
| `get_goals` | ✅ | `active_only` | `[GoalDTO + progress]`（复用 `GoalProgress`） |
| `get_focus_stats` | ✅ | `range`, `group_by: day / hour / category` | 汇总后的统计（复用 `FocusStats`） |
| `read_memory` | ✅ | `query?` | `[MemoryDTO]` |
| `create_task` | ✅（写入草稿） | `title, kind, start?, minutes?, priority?, deadline?, category?, effort?, goal_id?, parent_id?, reason` | `{op_id}` |
| `update_task` | ✅（写入草稿） | `id`, 要修改的字段, `reason` | `{op_id}` |
| `propose_plan` | ✅ | `summary` | `{proposal_id, warnings[], load_after}`。把草稿校验后封装成提案，结束循环 |
| `write_memory` | ✅（生成记忆提案） | `text, kind, constraint?` | `{pending_id}`，需要用户确认后才生效 |
| `apply_plan` | ❌ 仅界面 / App Intent | `proposal_id`, `selected_item_ids?` | `{applied}` |
| `start_focus` | ❌ 仅界面 / App Intent | `task_id`, `minutes?` | — |

工具层是一组纯 Swift 函数（`AgentTools`），同时被三个入口复用：LLM 循环、App Intents（Siri、快捷指令）、以后的 MCP Server。每个工具都有单测，覆盖参数校验、时区、空数据和越界的情况。

### 3.3.1 API Key 管理（v1：用户自己填）

| 环节 | 做法 |
|---|---|
| 入口 | 设置 → 秘书 AI → API Key。AI 第一次被触发、但还没有 Key 时，在结果卡片上提示“填写 API Key 开启智能解析”，不弹窗打断 |
| 存储 | Keychain，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。不同步到 iCloud，不写日志；界面上只显示末 4 位。Mac 版以后单独填写 |
| 校验 | 保存时发一个最小请求（`max_tokens` 很小）验证 Key 是否可用：401 提示“Key 无效”，429 / 529 提示“稍后再试”，网络错误时允许先保存 |
| Extension | App Intents 和小组件不调用 LLM，只走规则模式，所以 Key 不需要放进 App Group 共享的 Keychain |
| 失败处理 | 401 → 自动停用 AI，并在秘书卡片上提示重新填写；429 / 5xx → 本次退回规则模式，不重试太多次（最多 2 次） |
| 费用透明 | 设置页显示本月累计 token 用量（从 `response.usage` 统计，只存在本机） |

### 3.4 Agent 循环

```
用户输入 / 定时触发
   → 组装上下文（now、时区、今天概况、active 记忆摘要）
   → AgentLoop：send → 若 stop_reason == tool_use，执行全部 tool_use，
                 并把所有 tool_result 合并成一条 user 消息发回（失败的标 is_error）
              → 直到 end_turn 或调用 propose_plan
   → 检查 refusal / max_tokens → 失败就走 RuleOnlyProvider
   → ProposalOverlay 展示幽灵日程 → 用户确认 → ProposalApplier
```

### 3.5 隐私与数据最小化

- AI 开关**默认开启**，但开启 ≠ 已经在发送数据。实际调用模型需要同时满足三个条件：开关开启、已填 API Key、已同意数据说明。缺任何一个，都只走规则模式，界面上不会报错。
- **数据说明同意**：在用户填写 API Key 的页面上一并展示，说明会发送什么（标题、时间、类别、统计数字）、发给谁（Anthropic）、备注默认不发送。用户点“同意并保存”后才生效，同意记录存在 `SettingsStore`。App Store 审核指南要求，把个人数据发给第三方 AI 之前必须明确告知并取得用户同意，所以即使默认开启，这一步也不能省。
- 设置里可以随时关闭 AI；关闭后立即只走规则模式，Key 仍然保存在 Keychain 中。
- 发给模型的只有标题、时间、类别、优先级和统计数字；**备注正文默认不发送**（专注前简报读取备注是在本地完成的）。只有“大任务拆分”在用户点击时，才会附上该任务的备注。
- 记忆存在本地，并通过 CloudKit 私有库同步，不经过任何第三方服务器。

---

## 4. 秘书行为准则的落地

| 准则 | 实现机制 |
|---|---|
| 先提案，用户拍板 | LLM 只能写入草稿；`ProposalOverlay` 用虚线幽灵块预览，每项可以单独取消勾选；应用后整体可撤销，Toast 里提供“撤销”按钮 |
| 该安静时安静 | `NudgeBudget`：每天主动推送不超过 3 条（可在设置里调 0–5）。专注开始时，取消和专注时段重叠的待发通知，等专注结束后再补发；本地通知设 `interruptionLevel = .passive`，晚间复盘设为 `.active` |
| 说清理由 | `PlanProposal.Item.reason` 是必填项，空字符串会被 Validator 拒绝；规则模式用模板生成理由，例如“排在 9:00，因为这是你本周完成率最高的时段（82%）” |
| 计算交给代码 | 所有数字都来自引擎；system prompt 写明“只使用工具返回的数字” |
| 冷启动和离线 | 数据不足时，引擎返回 `confidence: .low`，界面显示“再用几天会更准”；没有网络、AI 关闭、没填 Key 或没同意数据说明时，`RuleOnlyProvider` 接管 |

**推送优先级**：截止风险 > 晚间复盘 > 晨间简报 > 过载预警 > 估时校准建议。超出预算时，低优先级的不再推送，改为显示在 App 内的秘书卡片上。

---

## 5. 功能设计

> 格式：触发方式 → 交互（文字线框）→ 实现要点 → iOS 17 注意事项

### 5.1 📥 收集

#### ① 一句话变结构化 / ② 大任务自动拆分

- **触发**：「+」按钮、Siri、操作按钮、粘贴、分享。
- **交互**：
  ```
  ┌ 收集 ─────────────────────────────┐
  │ [下周找时间和老王聊预算，挺急的   ] 🎙 │
  │ ─ 识别结果 ──────────────────────── │
  │ 和老王聊预算   ⏱ 30分钟  🔴 紧急      │
  │ 截止 下周五    📂 会议               │
  │ [放进收集箱]   [帮我排进日程 →]       │
  │ 💡 看起来是个大任务？ [拆分]           │
  └──────────────────────────────────┘
  ```
- **实现**：先用规则解析，结果即时显示；如果 AI 可用（开关开启、已填 Key、已同意数据说明），再异步调用 LLM（结构化输出，effort `low`）细化结果，通常不到 2 秒。用户可以直接改每个字段。“拆分”会生成子任务提案（带 `parentID`），子任务默认进收集箱，也可以接着点“排进日程”。
- **大任务判定**（满足任一条件即显示“拆分”提示）：预估时长 ≥ 3h；标题含“写/做/准备/整理 + 报告/方案/总结”这类模式；LLM 返回 `is_large: true`。

#### ③ 语音入口

| 入口 | 实现 |
|---|---|
| App 内按住说话 | `SFSpeechRecognizer(locale: zh-CN)`；当 `supportsOnDeviceRecognition` 为真时，设置 `requiresOnDeviceRecognition = true`；松手后把识别结果填进输入框，走 ① 的流程 |
| Siri | `AppShortcutsProvider`，短语例如“用\(.applicationName)记一下”。`CaptureIntent` 带一个 `String` 参数（用 `requestValueDialog` 追问内容）；`openAppWhenRun = false`，先按规则解析存进收集箱，下次打开 App 时再用 LLM 细化 |
| 操作按钮 | 用户在系统设置里把操作按钮绑定到 `CaptureIntent` 对应的快捷指令；在引导页加一步说明 |

- **权限**：`NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`，在第一次按下麦克风时才申请。
- **iOS 17**：App Shortcuts 可用；Siri 追问参数在 17 上可用，需要真机验证中文短语的识别效果。

#### ④ 剪贴板入口

- **App 内**：收集面板里放一个 `PasteButton`。系统按钮点击时不会触发粘贴授权弹窗。
- **回到前台时的提示**：用 `UIPasteboard.general.detectPatterns(for: [.probableWebURL, .probableWebSearch])` 判断剪贴板里有没有文本或链接。这个 API 只判断类型、不读取内容，所以**不会触发弹窗**。有内容时，在「+」按钮旁边显示一个“📋 粘贴为任务”提示，点击后进入 `PasteButton` 流程。
- **链接**：复用 `LinkTitleResolver` 抓取网页标题作为任务标题，URL 写进备注。
- **Share Extension**：可选，见 §11。

### 5.2 🗓 排期

#### ⑤ 一键排期

- **触发**：规划 Tab 的“排进本周”按钮；收集箱多选后点“排期”；在「+」里输入自然语言，例如“把收集箱排进本周”。
- **交互**：
  ```
  日程 Tab（3 日视图）
  ┆09:00┆ ╭┄┄┄┄┄┄┄┄┄┄┄┄╮              ← 虚线幽灵块
  ┆     ┆ ┆ 写方案初稿  ┆  “上午是你的高效时段”
  ┆     ┆ ╰┄┄┄┄┄┄┄┄┄┄┄┄╯
  ──────────────────────────────────
  秘书提案 · 5 项 · 本周负载 32h/36h  ⚠️ 周三将过载 40 分钟
  [✓ 写方案初稿 周二 9:00] [✓ …]          ← 可横向滑动，每项可取消勾选
  [ 取消 ]                [ 应用 5 项 ]
  ```
- **实现**：AI 关闭时，`Scheduler` 直接生成提案；AI 开启时，LLM 用 `list_tasks`、`find_free_slots`、`get_insights` 收集信息，再用 `create_task` / `update_task` 写入草稿，最后调用 `propose_plan`。幽灵块用 `EventBlockView` 的虚线样式绘制。
- **iOS 17**：提案栏用 `safeAreaInset(edge: .bottom)`；不用 iOS 18 才有的 `onScrollGeometryChange`。

#### ⑥ 按能量曲线排

- `EnergyCurve` 按“星期 × 小时”统计近 4 周的完成率和专注时长占比。没有数据时，默认 9–12 点为高效时段。
- `Scheduler` 打分公式：`score = 能量分 × 难度权重 + 截止紧迫度 + 优先级`；难度为 3 的任务只排进能量分前 30% 的时段。
- 统计 Tab 里显示一张“你的高效时段”热力图（Charts），让用户知道排期依据从哪来。

#### ⑦ 截止日倒推

- **触发**：任务带截止日，且需要多个专注块（预估时长大于单块上限 90 分钟）。
- **实现**：需要的总时长 = 预估时长 × 校准系数；从截止日前一天往回找空档，切成 60–90 分钟的块，留 20% 缓冲，最后一块至少比截止时间早半天。结果作为一份提案。

### 5.3 🛡 守护

#### ⑧ 过载预警

- **触发时机**：晨间简报时；任何会增加当天时长的写入之后（App 内用卡片提示，不推送）；提案应用前（显示在提案栏的警告里）。
- **交互**：“今天排了 9.5h，按你的历史一天大约能完成 6h。建议把这 2 项挪到周四。” 点击后生成一份重排提案。
- **实现**：`LoadEstimator.capacity` 取近 14 天里有专注的日子、按实际专注分钟数的 P75；日程总时长只统计未完成的任务。

#### ⑨ 截止风险预警

- **触发**：每天的晨间刷新；带截止日的任务有变化时。
- **判定**：剩余需要的时长 × 校准系数 > 截止前的可用空档 × 0.8 → 有风险；还能算出预计延期几天。
- **交互**：通知或卡片：“『年终总结』按当前进度会延期 1 天。补救：周三晚上加一个 1.5h 的块，或把『整理照片』挪走。” 每个补救方案对应一份提案。
- **推送**：属于最高优先级，同一个任务每天最多提醒 1 次。

### 5.4 ⏱ 执行

#### ⑩ 专注前简报

- **触发**：点“开始专注”后、倒计时开始前，显示一张简报卡片（不推送）；到点的“开始专注”通知正文里也带一行摘要。
- **交互**：
  ```
  ┌ 开始专注 · 写方案初稿 · 90 分钟 ───┐
  │ 上次：周一 45 分钟，提前结束          │
  │ 备注里还有 2 个待办：                  │
  │  ☐ 补充竞品数据  ☐ 画架构图           │
  │ 这类任务你通常会超时 30%               │
  │ [  开始  ]        [ 改成 2 小时 ]      │
  └──────────────────────────────┘
  ```
- **实现**：完全在本地完成。`Briefing` 读取 `FocusSession` 和备注里的 `- [ ]`；校准提示来自 `Calibration`。

### 5.5 🔁 应变

#### ⑪ 一键重排

- **触发**：放弃专注、专注延长 2 次或以上、有日程时间已过但状态还是 todo、用户手动点“重排今天”。
- **交互**：Toast 提示“后面 3 项要顺延吗？” → 点开后显示幽灵预览 → 应用。
- **实现**：`Reflow` 从中断点开始，按原顺序顺延，跳过固定日程（来自 EventKit 的会议、带 `place` 的线下日程）和记忆约束时段；22:00 前放不下的移到明天的高效时段，并用理由说明。

### 5.6 🪞 复盘

#### ⑫ 晚间复盘

- **触发**：沿用 `DailyReview` 的时间（默认 21:00）发本地通知；点击后打开复盘页。
- **交互**：
  ```
  ┌ 今天 · 完成 4/6 · 专注 5h20m ────────┐
  │ 秘书总结：上午效率很高，下午被会议打断两次… │
  │ 未完成：                                    │
  │  ☑ 写方案初稿 → 明天 9:00                    │
  │  ☑ 回复邮件   → 明天 14:00（杂务块）         │
  │ ⚠️ 明天已有 7h，顺延后会过载 1h               │
  │ [ 应用顺延 ]      [ 放回收集箱 ]              │
  └────────────────────────────────────┘
  ```
- **实现**：`DailyReview.content` + `Reflow`（目标日期是明天）+ `LoadEstimator`。总结的那段话在 AI 开启时由 LLM 生成，否则用模板。

#### ⑬ 估时校准

- **触发**：某个类别累计 ≥ 5 次已结束的专注，且实际/计划时长的中位数偏离超过 25%。在晚间复盘页里显示，不单独推送。
- **交互**：“阅读类任务平均超时 60%，以后默认按 1.6 倍预估？[采纳] [不用]” → 采纳后写入 `ProfileSetting("estimate.reading")`。之后新建这一类任务时，默认时长和截止倒推都会乘上这个系数。
- **说明**：实际时长 = 同一任务所有专注的 `focusedSeconds` 之和；状态为放弃的专注不计入。

### 5.7 🎯 目标

#### ⑭ 目标拆解

- **触发**：新建目标后，提示“帮你拆成每周节奏？”；目标落后时（`GoalProgress.isBehind`）在晨间简报里提示。
- **实现**：LLM 把“本月读完 2 本书”换算成目标分钟数（例如约 600 分钟），用户可以修改；然后 `GoalBreakdown` 算出“每周 3 次 × 50 分钟”，在能量分高的空档生成占位提案，每块都带 `goalID`。

### 5.8 🧠 记忆与连接

#### ⑮ 显式记忆

- **触发**：在「+」里说“记住……”；或者在设置 → 秘书记忆里手动添加。
- **实现**：LLM 解析成 `MemoryConstraint` 后，以提案卡片的形式让用户确认（“每周三 19:00–21:00 不排日程？”）。规则模式下用表单填写（星期、开始和结束时间）。`SlotFinder` 会把所有生效的约束当作忙碌时段。
- **管理页**：列表显示每条记忆，可以开关、编辑、删除，并标出来源（你说的 / 秘书推断的）。v1 版不自动推断记忆。

#### ⑯ 同步系统日历（只读）

- **实现**：iOS 17 上用 `EKEventStore.requestFullAccessToEvents()`（只读也需要完整访问权限，只写权限读不到事件），Info.plist 里写 `NSCalendarsFullAccessUsageDescription`。外部事件以灰色的“外部日程”显示在日历上，不能编辑；`SlotFinder` 把它们当作忙碌时段。
- **权限时机**：第一次点“排进日程”时提示：“允许读取系统日历，排期时会避开你的会议。”
- **Mac 版**：以后可以用同一个 `ExternalCalendarSource` 协议接入，v1 不做。

### 5.9 晨间简报（串联 ⑧ ⑨ ⑭）

- **触发**：每天 8:30（可配置）发本地通知。在 BGAppRefreshTask 和每次 App 进入后台时，用最新数据重新生成第二天的通知正文；系统不保证后台刷新会执行，所以不依赖它，通知照常按时发出。
- **内容**：今天的 3 件要事、外部会议、过载或截止风险、落后的目标；点击后打开当天页面，并附带对应的提案。
- **复用**：Mac 版的“今日规划”（`DailyPlanView`）升级为同一套晨间简报逻辑。

---

## 6. 移动端系统能力

| 能力 | 实现 | 注意 |
|---|---|---|
| Live Activity + 灵动岛 | `ActivityKit`；`ContentState` 包含 `endDate`、`isPaused`、`pausedRemaining`；倒计时用 `Text(timerInterval:)`，由系统渲染，不需要后台刷新 | 暂停、延长、放弃专注时调用 `activity.update`；结束时调用 `end(dismissalPolicy: .after(...))` |
| 可交互小组件 | WidgetKit + `Button(intent:)`（iOS 17）：今天列表里可以直接完成任务或开始专注 | 写入后调用 `WidgetCenter.reloadAllTimelines()`；数据从 App Group 读取 |
| App Intents | `CaptureIntent`、`StartFocusIntent`、`CompleteTaskIntent`、`ScheduleInboxIntent`（只生成提案，打开 App 确认） | 同时给 Siri、快捷指令和小组件用；依赖 `AgentTools` 的同一套实现 |
| 勿扰 | `StartFocusIntent` + 引导用户在快捷指令里搭“设定专注模式 + 开始专注”；Focus Filter（`SetFocusFilterIntent`）让系统专注模式反过来影响 App | iOS 不能在后台静默运行快捷指令 |
| 到点开始专注 | 本地通知，带“开始专注 / 推迟 5 分钟 / 跳过”三个 action | 复用 `AutoFocusAction` 的定义 |
| 防止自动锁屏 | 沉浸模式下设置 `isIdleTimerDisabled = true`，退出时恢复 | |
| 后台 | `scenePhase` 变为 active 时调用 `FocusEngine.tick()`；BGAppRefreshTask 只用来刷新通知内容 | 不能用后台音频保活（审核条款 2.5.4） |

---

## 7. iOS 17 兼容清单

- 不使用 iOS 18 才有的 API：新的 `Tab` 写法、`@Entry`、`onScrollGeometryChange`、`MeshGradient`、新的 `.containerRelativeFrame` 用法等；必须使用时加 `if #available(iOS 18, *)`。
- SwiftData 在 17.0–17.3 上有已知问题（关系写入后不刷新、谓词崩溃等），CI 加一个 iOS 17.0 模拟器跑完整测试。
- 枚举一律用 rawValue 存储和查询（沿用现有做法）。
- `TextKit 1`：Markdown 编辑器在 iOS 上用 `UITextView(usingTextLayoutManager: false)`。
- 在 iOS 26 设备上先设 `UIDesignRequiresCompatibility = YES`；以后切到 Liquid Glass 只改 `GlassSurface`。

---

## 8. 里程碑与验收标准

> 相对你给出的顺序有两处调整：① **EventKit 提前到 M3**，因为不知道用户有哪些会议，排出的提案会大量冲突，第一印象很差；② **LLM 工具层分成两步**，M3 先做排期和重排的核心闭环，M4 再接主动行为。

| 里程碑 | 内容 | 验收标准 |
|---|---|---|
| **M0 拆共享层** | 建 `ImmerseKit`（`ImmerseCore` + 空的 `ImmerseAgent`），把 Models、Data、Stores 和纯逻辑迁过去，Mac 版改为依赖它 | Mac 版功能不变、现有测试全部通过；`ImmerseKit` 测试能在 macOS 和 iOS 模拟器上都跑通；Package 里 grep 不到 `AppKit` / `UIKit` |
| **M1 数据层** | SchemaV1/V2 + MigrationPlan、去掉唯一约束、加新字段和新模型、`DedupeService`、App Group、开启 CloudKit；Mac 版改用 Developer ID 签名 | 旧数据库升级后数据完整（有迁移测试）；两台设备离线编辑同一条记录后能正确合并、没有重复；Mac 与 iPhone 能互相同步 |
| **M2 iOS 核心 UI** | Tab 框架、日视图 / 3 日视图 / 月视图、编辑 sheet、长按拖动加 Haptics、「+」规则收集、专注页和沉浸模式 | iOS 17.0 和最新版模拟器都能完成“新建 → 拖动 → 专注 → 完成”；有关键页面截图；VoiceOver 能读出日程块 |
| **M3 Agent 基础** | `ImmerseAgent` 的引擎（SlotFinder、Scheduler、Reflow、Load）+ 工具层 + `LLMProvider` + API Key 设置页与数据说明同意 + `AgentLoop` + `PlanProposal` 和幽灵预览 + 一句话收集 + 拆分 + 语音和剪贴板入口 + EventKit 只读 | 引擎和工具的单测覆盖率 ≥ 85%；AI 关闭时一键排期和一键重排完全可用；AI 开启时 20 条收集样例的结构化准确率 ≥ 90%（建一个小评测集）；提案能整体撤销 |
| **M4 主动秘书** | 晨间简报、晚间复盘、过载和截止预警、专注前简报、`NudgeBudget`、Live Activity、可交互小组件、App Intents（含 Siri 收集）、到点开始专注的通知 | 连续 3 天真机使用：每天主动推送 ≤ 3 条、专注期间 0 条；锁屏和灵动岛的倒计时与 App 内一致；小组件按钮能直接完成任务 |
| **M5 洞察** | 估时校准、能量曲线和热力图、目标拆解、记忆管理页、截止日倒推 | 用 4 周模拟数据跑单测得到预期的校准系数和高效时段；冷启动时显示“数据不足”；记忆约束生效后，排期 100% 避开对应时段 |
| **M6 上线** | Xcode Cloud、TestFlight、PrivacyInfo.xcprivacy、隐私政策、截图、App 备案、`ITSAppUsesNonExemptEncryption = NO`、提交审核 | 通过 TestFlight 外部测试的 Beta 审核；App Store 审核通过 |

每完成一个里程碑：跑测试 → 在模拟器上截图验证 → 汇报改动和遗留问题 → 等你确认后再进入下一个。

---

### 8.1 M0 实现记录（2026-11-20，分支 `feat/immersekit`）

**结果：✅ 已完成。** `ImmerseKit/`（`ImmerseCore` 模块）已建好，Mac 版改为依赖它，功能没有变化。

| 验收项 | 结果 |
|---|---|
| Mac 版测试全部通过 | ✅ Mac 端 76 个 + 包内 101 个 = 177 个，与迁移前一致，全部通过；App 截图正常 |
| `ImmerseKit` 在 macOS 和 iOS 上可用 | 🟡 macOS 上 101 个测试通过；iOS 17 模拟器上**库和测试都能编译**（产物确认是 iOS Simulator 平台、minos 17.0），但**没有实际运行**：本机没装 iOS 模拟器运行时（Xcode 16.2 需要另外下载约 8GB） |
| 包内没有 AppKit / UIKit / SwiftUI | ✅ 没有任何这类 import |

**迁移了什么**

| 目录（`ImmerseKit/Sources/ImmerseCore/`） | 内容 |
|---|---|
| `Models/` | 全部 8 个模型文件 |
| `Data/` | 仓库协议与 SwiftData / 内存实现、PersistenceController、SampleData、LegacySampleCleanup |
| `Stores/` | TaskStore（含 Planning 扩展）、SettingsStore |
| `Focus/` | FocusEngine、AutoFocusScheduler，以及从 Mac 端拆出来的 `FocusNotifying`、`DoNotDisturbServicing`、`RecordingNotifier` |
| `Calendar/` | EventLayoutEngine、EventEditing、TimeSlots，以及从 Mac 端拆出来的 `Calendar.app`、`TimeText` |
| `Planning/` `Review/` `Stats/` `Import/` `Parsing/` | IdeaStaleness、PlanningInput、DailyPlan、DailyReview（纯计算部分）、FocusStats、NotionCSVImporter、NaturalLanguageParser |

**和原计划不同的地方**

- **`CalendarStore` 留在 Mac 端**：它依赖导入预览（定义在 SwiftUI 视图文件里），本质上是 Mac 日历的界面状态。M2 做 iOS 日历时，再决定拆出共享部分还是各写一份。
- **`ImmerseAgent` target 推迟到 M3 再建**：现在建只能放一个空文件。
- **拆出平台相关的部分**：`FocusEngine` 时间到时让 Dock 图标跳动，改为由外部注入 `onTimeUpAttention` 回调；`IdeaStaleness.color` 和 `DailyReviewScheduler` 留在 Mac 端；拖动吸附步长 `snapMinutes` 移到 `EventEditing`，`CalendarMetrics` 引用它。
- **访问控制**：包内类型统一标为 `public`；结构体的成员初始化器在模块外不可见，所以给 `TaskSnapshot`、`LayoutItem`、`Toast`、`FocusRecord` 等补了显式的 `public init`。

**怎么测**：`scripts/test-kit.sh` 在 macOS 上跑包内测试，再用 iOS 17 模拟器 SDK 交叉编译库和测试；Mac 端测试照常用 Xcode 跑 `Immerse` scheme。

### 8.2 M1–M6 实现记录（2026-11-20，分支 `feat/immersekit`）

| 里程碑 | 提交 | 完成情况 | 和计划不同 / 遗留 |
|---|---|---|---|
| M1 数据层 | `7f979bb` | ✅ CloudKit 兼容的 V2 模型（去掉唯一约束、全部默认值、关系可选）、新字段、`MemoryItem` / `ProfileSetting`、`DedupeService`、`SyncMonitor`、App Group 存储路径、CloudKit 开关（Info.plist 填容器 ID 即开启） | **没有用 `MigrationPlan`**：测试证明从 0.1.0 和 0.1.9 两种真实布局的老库都能靠自动轻量迁移升级，你本机真实数据库的副本（15 个任务、10 条专注）也升级成功。Mac 版 Developer ID 签名、真正开启 iCloud 需要开发者账号，见 `docs/app-store.md` |
| M2 iOS 核心界面 | `67065c5` | ✅ 四个 Tab、日 / 3 日 / 月视图、长按拖动移动和改时长（每 15 分钟一次触感）、编辑 sheet、「+」收集、规划、专注页、沉浸模式、统计、设置 | 通知服务和晚间复盘调度也搬进了 `ImmerseCore`，两端共用 |
| M3 Agent 基础 | `c1a4e18` | ✅ `ImmerseAgent`：找空档、能量曲线、排期、重排、负载、截止风险、估时校准、目标节奏、专注前简报、提案校验与一步撤销、严格模式工具层、工具循环、Claude HTTP 客户端、结构化收集 / 拆分 / 记忆、Keychain 存 Key；iOS：幽灵日程、提案栏、建议横幅、语音、粘贴、EventKit 只读 | 收集评测集 20 条已写好（`capture-eval.json`），**需要真实 Key 才能跑**（会产生费用），还没有跑 |
| M4 主动秘书 | `4b2e420` | ✅ 晨间简报、晚间复盘页、截止和过载提醒、每日推送预算、专注期间推迟、后台刷新、通知上的「开始专注」、Live Activity + 灵动岛（暂停 / 完成按钮）、可交互「今天」小组件、Siri / 快捷指令（记一下、开始专注、排进本周）、Focus Filter | 小组件写入走共享 App Group 库；App 回到前台会重读 |
| M5 洞察 | `3e7d0d8` | ✅ 高效时段图、估时偏差与采纳、目标拆成节奏（AI 估算时长或手动）、秘书记忆管理页、按截止日倒推 | — |
| M6 上线准备 | 本次 | ✅ 隐私清单、TestFlight 自动上传流程、导出配置、隐私政策草稿、商店文案和审核备注、上架清单 | 账号、备案、截图、提交需要你本人完成，见 `docs/app-store.md` |

**测试**：`ImmerseCore` 114 个 + `ImmerseAgent` 54 个 + Mac 端 76 个，全部通过；iOS App 和小组件用 `scripts/typecheck-ios.sh` 对 iOS 17 SDK 做了完整类型检查。iOS 模拟器上的运行验证见本节末尾。

## 9. 测试策略

| 层 | 方法 |
|---|---|
| 引擎（纯函数） | 单测 + 固定 `now` / `Calendar` / 时区；包括边界：跨天、夏令时、全天日程、空数据 |
| 工具层 | 用 `InMemoryTaskRepository` 测试参数校验、草稿操作的累加、提案校验 |
| AgentLoop | 用 `MockLLMProvider` 回放预先录好的响应，测试多轮工具调用、`is_error`、refusal 和超时后退回规则模式 |
| LLM 质量 | 小评测集：收集解析 20 条、排期场景 10 个；每次修改提示词都重跑（会产生费用，需要你同意后再跑） |
| 迁移 | 用 V1 数据库文件作为 fixture，测试升级到 V2 |
| UI | 关键流程的 XCUITest + 截图（沿用 Mac 版的 DebugSnapshot 思路） |

---

## 10. 风险清单

| 风险 | 影响 | 应对 |
|---|---|---|
| CloudKit schema 上线后无法删改字段 | 字段设计失误会一直留着 | V2 一次加齐字段；上线前在 Development 环境跑完 M5 |
| 去掉唯一约束后产生重复数据 | 列表里出现重复日程 | `DedupeService` + 迁移测试 + 双设备离线测试 |
| LLM 排出不合理的日程 | 用户失去信任 | 只能提案、每项附理由、可以单独取消勾选、可以整体撤销；数字全部来自引擎 |
| LLM 费用 | 费用由用户自己承担，用多了会心疼 | 大部分功能是确定性计算，不调用 LLM；收集解析用 `low` effort；prompt caching；设置页显示本月用量 |
| 用户自填 Key 门槛高 | 普通用户不会申请 Key，AI 功能形同虚设 | 不填 Key 时规则模式完整可用；提供一页“如何获取 API Key”的说明；上架后视反馈再加代理（方案 A） |
| 审核质疑“需要用户自备 Key” | 被拒（例如认为功能不完整） | 审核备注里说明：核心功能不依赖 Key，AI 是可选增强；同时提供一个审核用的测试 Key |
| 隐私和审核 | 被拒，或用户不信任 | AI 默认开启，但第一次发送数据前必须明确同意；备注默认不发送；隐私营养标签如实填写“数据发送给第三方 AI 处理” |
| 推送打扰 | 违背“沉浸”的定位，用户关闭通知 | `NudgeBudget`、专注期间静默、低优先级内容只显示在 App 内 |
| iOS 17.0–17.3 的 SwiftData bug | 崩溃、数据不刷新 | 专门的 17.0 模拟器 CI；必要时在 17.4 以下禁用部分功能 |
| BGAppRefreshTask 不执行 | 通知内容过时 | 通知按时发出，正文只写稳定信息，点开后实时计算 |
| 开发者账号和签名 | 没有账号就无法做 CloudKit、TestFlight | M1 开始前完成 Apple Developer 注册 |
| ICP 备案周期长 | 国区上架延后 | M3 开始就并行办理 |

---

## 11. 待你决策

| # | 问题 | 选项 | 我的推荐 |
|---|---|---|---|
| 1 | ✅ **已定（2026-11-20）：先用 B（用户自己填 Key）**，已在 M3 实现，A 留作上架后的可选项<br>**LLM API Key 方案** | **A. 轻量代理后端**：例如 Cloudflare Worker，用官方 TypeScript SDK 转发 `/v1/messages`；用 Sign in with Apple 或 App Attest 鉴权，并按用户限额。优点：Key 不会落到设备上，能控制费用，以后可以收费。缺点：要维护一个服务，需要域名和备案，有运营成本。<br>**B. 用户自己填 Key**：存在 Keychain 里，App 直接调用 `api.anthropic.com`。优点：零后端，开发最快。缺点：普通用户门槛高，审核可能质疑，费用由用户承担 | **先 B 后 A**：M3、M4 用 B 自用和内测，上架前（M6）补上 A，B 作为“高级选项”保留 |
| 2 | **模型** | 所有场景都用 `claude-opus-5-5`（$4 / $20 每百万 token），用 effort 区分深浅；或者收集解析这种高频的轻量场景改用更便宜的模型 | 先全部用 `claude-opus-5-5`，M3 用评测集量化质量和单次成本后，你再决定要不要给收集解析换模型 |
| 3 | **Share Extension** | 做（M5 之后，复用收集流程，约 1–2 天）/ 不做 | 先不做，`PasteButton` 和 Siri 已经覆盖大部分场景；TestFlight 反馈里有需求再加 |
| 4 | **任务类别从哪来** | LLM 自动归类加用户修改 / 用户手动打标签 | LLM 自动归类加关键词规则兜底，用户可以改。手动打标签的话，几乎没有人会坚持 |
| 5 | **Mac 版同步获得秘书能力的时间** | 和 iOS 同步上线 / iOS 先上线 | iOS 先上线；`ImmerseAgent` 本来就是两端共用的，Mac 版在 M5 之后只需要补界面 |
| 6 | ✅ **已定（2026-11-20）：默认开启**<br>**AI 默认开关** | 默认关闭、主动开启 / 默认开启 | 按默认开启实现，但第一次把数据发给模型前，仍需用户明确同意一次（见 §3.5） |
