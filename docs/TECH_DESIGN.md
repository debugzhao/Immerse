# Immerse 技术方案

> 版本：v1.1 · 日期：2026-11-18 · 状态：M1–M6 已实现（实现记录见第 14 节）
> App 名称 `Immerse` 为暂定名，Bundle ID 暂定 `com.debugzhao.immerse`

## 0. 结论先行

**用原生 SwiftUI 开发，最低支持 macOS 14，界面用毛玻璃效果（Material）代替 Liquid Glass，数据只存本地（SwiftData）。分 M1–M6 六个阶段交付。**

| 关键决策 | 选择 | 一句话理由 |
|---|---|---|
| 技术栈 | SwiftUI + 少量 AppKit | 毛玻璃、通知、菜单栏都能直接用系统能力；体积小、启动快 |
| 最低系统版本 | macOS 14 Sonoma | 你的系统是 macOS 14.7.6，不打算升级；SwiftData 和 `@Observable` 都从 14 开始支持 |
| 视觉效果 | `Material` / `NSVisualEffectView` 毛玻璃 | Liquid Glass 需要 macOS 26，先不做；玻璃效果统一封装，以后升级只改一处 |
| 数据存储 | SwiftData，仅本地 | 第一版不同步；数据访问统一走 `TaskRepository` 协议，以后接 iCloud 或 Notion 只换实现 |
| 勿扰 | 调用「快捷指令」 | macOS 没有切换专注模式的公共 API，这是唯一稳定可行的办法 |
| 工程管理 | XcodeGen（`project.yml`） | 工程配置是可读的文本，git diff 清楚，没有 `.pbxproj` 合并冲突 |
| 分发 | 不开沙盒，本机 ad-hoc 签名 | 自己用不需要开发者账号；调用 `/usr/bin/shortcuts` 不能开沙盒 |

---

## 1. 开发环境

### 1.1 现状与准备工作

| 项目 | 现状 | 需要做的 |
|---|---|---|
| 操作系统 | macOS 14.7.6 | 不升级 |
| Xcode | ✅ Xcode 16.2（在 `~/Downloads/Xcode.app`） | 不需要 `sudo xcode-select`：`scripts/build.sh` 会自动通过 `DEVELOPER_DIR` 找到它。注意只有命令行工具时 SwiftData 的 `@Model` 宏无法编译 |
| XcodeGen | ✅ 2.47.0（在 `~/.local/bin`） | Homebrew 在 macOS 14 上编译会误用命令行工具而失败，改为用 Xcode 从官方源码 `make install PREFIX=~/.local` |
| Swift | 6.0.3（随 Xcode 16.2 提供） | 用 Swift 5 语言模式 + 完整并发检查（见 1.2） |

安装 Xcode 后执行：

```bash
sudo xcode-select -s /Applications/Xcode.app
```

### 1.2 编译配置

| 配置项 | 值 | 说明 |
|---|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | 14.0 | |
| `SWIFT_VERSION` | 5.0 | SwiftData 在 Swift 6 严格并发模式下还有不少警告和报错，先用 5 模式 |
| `SWIFT_STRICT_CONCURRENCY` | complete | 提前暴露并发问题，以后切换到 Swift 6 成本低 |
| `SWIFT_UPCOMING_FEATURE_INFER_SENDABLE_FROM_CAPTURES` | YES | SE-0418，消除 SwiftData `#Predicate` / `SortDescriptor` 的 KeyPath Sendable 误报 |
| `ENABLE_APP_SANDBOX` | NO | 需要执行 `/usr/bin/shortcuts` |
| `ENABLE_HARDENED_RUNTIME` | Debug: NO / Release: YES | Debug 关闭是为了让单元测试 bundle 能注入宿主 App；Release 保留，以后公证不用再改 |
| `CODE_SIGN_IDENTITY` | `-`（Sign to Run Locally） | ad-hoc 签名，不需要开发者账号 |

---

## 2. 整体架构

### 2.1 分层

```
┌──────────────────────────────────────────────────────────────┐
│ 视图层 Features                                              │
│  Calendar · Sidebar · Editor · CommandPalette · Focus UI  │
├──────────────────────────────────────────────────────────────┤
│ 状态层 Stores（@Observable，@MainActor）                       │
│  CalendarStore · TaskStore · FocusEngine · SettingsStore     │
├───────────────────────────────┬──────────────────────────────┤
│ 数据层 Data                    │ 系统集成层 System             │
│  TaskRepository（协议）         │  NotificationService          │
│  SwiftDataTaskRepository      │  DoNotDisturbService          │
│  SampleData                   │  ShortcutsRunner · PowerMonitor│
└───────────────────────────────┴──────────────────────────────┘
```

- 采用 MVVM，用 `@Observable` 类实现 ViewModel，这里统一叫 **Store**
- 视图只读取 Store 并调用 Store 的方法，不直接操作 `ModelContext`
- 系统集成层的服务都先定义协议，单元测试时换成假实现

### 2.2 依赖注入

在 App 入口创建一个 `AppEnvironment`，统一持有所有 Store 和服务，通过 `.environment()` 传给视图：

```swift
@MainActor
final class AppEnvironment {
    let repository: TaskRepository
    let taskStore: TaskStore
    let calendarStore: CalendarStore
    let focusEngine: FocusEngine
    let settings: SettingsStore
    let notifications: NotificationServicing
    let dnd: DoNotDisturbServicing
}
```

### 2.3 窗口与场景

| 场景 | SwiftUI API | 用途 |
|---|---|---|
| 主窗口 | `WindowGroup` + `NavigationSplitView` | 侧栏 + 日历；日程详情在居中的 Notion 风格弹窗里编辑（`TaskEditorOverlay`） |
| 菜单栏 | `MenuBarExtra(style: .window)` | 显示专注倒计时和控制按钮；没有专注时显示今日任务 |
| 沉浸视图 | 单独的 `Window` 场景，进入后全屏 | 专注时的全屏视图 |
| 设置 | `Settings` 场景 | 勿扰开关、快捷指令名称、默认时长等 |
| 命令面板 | 主窗口上的浮层 | `⌘K` 呼出 |

---

## 3. 目录结构

```
schedule-management/
├── project.yml                      # XcodeGen 配置
├── Immerse/
│   ├── App/
│   │   ├── ImmerseApp.swift         # @main，各个 Scene
│   │   ├── AppDelegate.swift        # 通知代理、启动时恢复专注状态
│   │   └── AppEnvironment.swift
│   ├── Models/
│   │   ├── TaskItem.swift           # @Model
│   │   ├── FocusSession.swift       # @Model
│   │   ├── Priority.swift
│   │   └── TaskStatus.swift
│   ├── Data/
│   │   ├── TaskRepository.swift     # 协议
│   │   ├── SwiftDataTaskRepository.swift
│   │   └── SampleData.swift         # 开发用的假数据
│   ├── Stores/
│   │   ├── TaskStore.swift
│   │   ├── CalendarStore.swift      # 当前日期、视图模式、选中项
│   │   └── SettingsStore.swift
│   ├── Features/
│   │   ├── Calendar/
│   │   │   ├── CalendarContainerView.swift
│   │   │   ├── WeekView.swift · DayView.swift · MonthView.swift
│   │   │   ├── TimeGridView.swift   # 时间刻度 + 网格线
│   │   │   ├── AllDayRowView.swift
│   │   │   ├── EventBlockView.swift
│   │   │   ├── NowIndicatorView.swift
│   │   │   ├── EventLayoutEngine.swift   # 重叠日程的排布算法
│   │   │   └── DragInteraction.swift     # 拖拽创建、移动、调整时长
│   │   ├── Sidebar/
│   │   │   ├── SidebarView.swift
│   │   │   ├── MiniMonthView.swift
│   │   │   └── TodayTaskList.swift
│   │   ├── Editor/
│   │   │   └── TaskEditorView.swift
│   │   ├── CommandPalette/
│   │   │   ├── CommandPaletteView.swift
│   │   │   └── NaturalLanguageParser.swift
│   │   └── Focus/
│   │       ├── FocusEngine.swift
│   │       ├── FocusState.swift
│   │       ├── MenuBarFocusView.swift
│   │       └── ImmersiveFocusView.swift
│   ├── System/
│   │   ├── NotificationService.swift
│   │   ├── DoNotDisturbService.swift
│   │   ├── ShortcutsRunner.swift
│   │   ├── PowerMonitor.swift        # 监听睡眠和唤醒
│   │   └── KeyboardShortcuts.swift
│   ├── DesignSystem/
│   │   ├── GlassSurface.swift        # 毛玻璃封装（预留 Liquid Glass 分支）
│   │   ├── VisualEffectBackground.swift
│   │   ├── Palette.swift             # 优先级配色
│   │   └── Motion.swift              # spring 动画参数
│   └── Resources/
│       ├── Assets.xcassets
│       ├── Info.plist
│       └── Immerse.entitlements
├── ImmerseTests/
│   ├── FocusEngineTests.swift
│   ├── NaturalLanguageParserTests.swift
│   └── EventLayoutEngineTests.swift
├── scripts/
│   └── build.sh                      # 生成工程 → 编译 → 输出 .app
└── docs/
    └── TECH_DESIGN.md
```

> 模型命名为 `TaskItem` 而不是 `Task`，避免和 Swift 并发里的 `Task` 重名。

---

## 4. 数据模型

### 4.1 字段对照（来自 Notion「主线任务日程」）

| Notion 字段 | App 字段 | 类型 | 变化 |
|---|---|---|---|
| 任务 | `title` | `String` | — |
| 日期（start / end / is_datetime） | `start` / `end` / `isAllDay` | `Date` / `Date?` / `Bool` | — |
| 优先级（紧急 / 重要 / 普通） | `priority` | `Priority` 枚举 | — |
| 状态（未开始 / 进行中 / 已完成） | `status` | `TaskStatus` 枚举 | 合并 Notion 的「完成」复选框 |
| 完成 | — | — | ❌ 删除，和状态重复 |
| 备注 | `notes` | `String`（Markdown） | — |
| Place | `place` | `String?` | — |
| — | `plannedMinutes` | `Int?` | 🆕 计划专注时长 |
| — | `sessions` | `[FocusSession]` | 🆕 专注记录 |

### 4.2 模型定义

```swift
enum Priority: Int, Codable, CaseIterable, Comparable {
    case urgent = 0      // 紧急 · 红
    case important = 1   // 重要 · 黄
    case normal = 2      // 普通 · 紫
}

enum TaskStatus: String, Codable, CaseIterable {
    case todo, inProgress, done   // 未开始 / 进行中 / 已完成
}

@Model
final class TaskItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var start: Date
    var end: Date?             // nil 表示单个时间点或单个全天
    var isAllDay: Bool
    var priorityRaw: Int       // SwiftData 对枚举谓词支持不好，存原始值
    var statusRaw: String
    var notes: String
    var place: String?
    var plannedMinutes: Int?
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \FocusSession.task)
    var sessions: [FocusSession] = []
}

@Model
final class FocusSession {
    @Attribute(.unique) var id: UUID
    var task: TaskItem?
    var startedAt: Date
    var endedAt: Date?            // nil 表示正在进行
    var plannedSeconds: Int       // 包含所有延长时间
    var pausedSeconds: Int        // 暂停时间累计
    var pausedAt: Date?           // 非 nil 表示当前处于暂停状态
    var endReasonRaw: String?     // completed / finishedEarly / abandoned
}
```

### 4.3 派生规则

| 规则 | 说明 |
|---|---|
| 实际专注时长 | 计划时长没设置时，有时间段的任务取 `end - start`，全天任务默认 **60 分钟** |
| 显示颜色 | 由 `priority` 决定；状态为 `done` 时整体变灰并加删除线 |
| 同一时段排序 | 先按 `priority` 升序，再按 `start` 升序 |
| 进行中的任务唯一 | 由 `FocusEngine` 保证，任何时候最多只有一个 `endedAt == nil` 的 `FocusSession` |

### 4.4 数据访问抽象

数据层之上只使用值类型 `TaskSnapshot`，不直接持有 `@Model` 对象。这样视图不受托管对象生命周期的影响；除了模型、SwiftData 仓库和 App 入口，其余代码都不依赖 SwiftData，也可以单独测试。

```swift
@MainActor
protocol TaskRepository: AnyObject {
    func tasks(in interval: DateInterval) throws -> [TaskSnapshot]
    func isEmpty() throws -> Bool
    func insert(_ snapshots: [TaskSnapshot]) throws
    // M2 增加：update / delete / search / undoManager
    // M3 增加：activeSession 等专注记录相关接口
}
```

- 实现有两个：`SwiftDataTaskRepository`（正式使用）和 `InMemoryTaskRepository`（单元测试和预览使用）

- 撤销：创建 `ModelContainer` 时开启 `isUndoEnabled: true`，拖拽、编辑、删除都自动注册撤销操作
- 以后做 Notion 同步时，新增 `NotionSyncService`，用 `notionPageId` 字段做映射，不改现有协议

---

## 5. 日历模块

### 5.1 视图参数

| 参数 | 默认值 |
|---|---|
| 默认视图 | 周视图，显示周末 |
| 每周第一天 | 周一 |
| 时间范围 | 0:00–24:00，打开时滚动到 8:00 |
| 每小时高度 | 48pt（以后可以用 `⌘+` / `⌘-` 缩放） |
| 拖拽吸附粒度 | 15 分钟 |
| 最短日程 | 15 分钟 |

### 5.2 重叠日程排布（`EventLayoutEngine`）

和 Google Calendar、Notion Calendar 一样，采用「分簇 + 贪心分列」算法：

1. 把当天有时间段的日程按 `start` 升序排列，`start` 相同时按 `priority` 排序
2. **分簇**：时间上相互重叠（直接或间接）的日程归为一簇
3. **分列**：簇内每个日程放到第一个「最后一个日程已经结束」的列；没有这样的列就新开一列
4. **计算宽度**：`宽度 = 当天列宽 / 簇的列数`；如果右侧相邻列在该时段是空的，就向右扩展
5. 输出每个日程的 `CGRect`，视图层只负责绘制

这个算法是纯函数，便于单元测试，详见 `EventLayoutEngineTests`。

### 5.3 交互

| 操作 | 实现 |
|---|---|
| 拖拽框选创建 | 在网格空白处用 `DragGesture` 记录起止 y 坐标 → 换算成时间并吸附到 15 分钟 → 显示虚线预览块 → 松手后弹出居中的新建弹窗（标题输入框获得焦点） |
| 移动 | 在日程块主体上拖拽；可以跨天（按 x 坐标换算日期） |
| 调整时长 | 日程块上下边缘各留 6pt 热区，鼠标悬停时光标变成 `resizeUpDown` |
| 点击 | 选中日程（高亮，⌫ / Space 作用于它） |
| 双击 / `↩` / 右键「打开」 | 打开日程弹窗编辑，改动立即保存 |
| 悬停 | 显示「▶ 开始专注」小按钮 |
| 右键 | 菜单：开始专注 / 标记完成 / 修改优先级 / 删除 |
| 当前时间线 | 用 `TimelineView(.everyMinute)` 驱动红线位置 |
| 进行中的日程块 | 用 `phaseAnimator` 做边框和阴影的呼吸效果 |

### 5.4 月视图与全天日程

- 全天和跨天日程放在顶部的全天行，横跨多天显示成一条连续的条
- 月视图每格最多显示 3 条，超出部分显示「+N」，点击后切换到日视图

---

## 6. 专注引擎（核心）

### 6.1 状态机

```
            start(task)
  ┌──────┐ ───────────▶ ┌─────────┐  pause   ┌────────┐
  │ idle │              │ running │ ───────▶ │ paused │
  └──────┘ ◀─────────── └─────────┘ ◀─────── └────────┘
     ▲     finish /         │        resume       │
     │     abandon          │ 剩余时间 ≤ 0          │ finish / abandon
     │                      ▼                     │
     │               ┌──────────────┐             │
     └────────────── │ timeUp(等待)  │ ◀───────────┘
       标记完成 /       └──────────────┘
       延长 15 分钟会回到 running
```

### 6.2 计时原理

**不依赖每秒累加，只依赖时间戳计算**，这样睡眠、App 重启都不会让时间算错：

```
已用时长 = (暂停中 ? pausedAt : now) − startedAt − pausedSeconds
剩余时长 = plannedSeconds − 已用时长
```

- UI 刷新：`TimelineView(.periodic(from:by: 1))`，只在显示倒计时的视图里刷新，不触发全局重绘
- 菜单栏标题：`MenuBarExtra` 的 label 绑定 `focusEngine.remainingText`，由一个 1 秒定时器更新
- 数字变化动画：`.contentTransition(.numericText(countsDown: true))`
- 防止 App Nap：专注期间调用 `ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, ...)`，保证定时器按时触发，但不阻止系统睡眠

### 6.3 开始专注的流程

```
start(task)
 ├─ 1. 检查：已经有进行中的专注吗？有就弹窗让用户选择「结束当前专注并开始新的」或「取消」
 ├─ 2. 新建 FocusSession（endedAt = nil），把 task.status 改为 inProgress，保存
 ├─ 3. 安排一条兜底通知：在预计结束时间触发
 ├─ 4. 异步开启勿扰（失败只提示，不影响计时）
 └─ 5. 开始 App Nap 保护，菜单栏切换到倒计时
```

### 6.4 时间到的处理

> ⚠️ 关键问题：如果勿扰还开着，系统会把我们的提醒通知也静音掉。

所以「时间到」的处理**由 App 主动驱动**：

1. 引擎检测到剩余时间 ≤ 0，进入 `timeUp` 状态
2. **先关勿扰**，等待快捷指令执行完成（最多等 3 秒）
3. 再发送通知并播放提示音（`NSSound`）；同时把主窗口或菜单栏面板弹到前台
4. 取消第 6.3 步安排的兜底通知，避免重复提醒
5. 用户点「标记完成」：写入 `endedAt`，`endReason = completed`，`task.status = done`
6. 用户点「延长 15 分钟」：`plannedSeconds += 900`，回到 `running`，重新开启勿扰

**兜底措施**：

- 引导页建议用户在「系统设置 → 专注模式 → 勿扰模式 → 允许的 App」里加入 Immerse，这样即使勿扰没关掉，提醒也能到达
- 如果 App 被杀掉，第 6.3 步安排的系统通知仍会按时出现

### 6.5 睡眠、重启和崩溃恢复

| 场景 | 处理 |
|---|---|
| 时间到时 Mac 在睡眠 | `PowerMonitor` 监听 `NSWorkspace.didWakeNotification`，唤醒后重新计算；已经超时就按 6.4 处理，`endedAt` 记为计划结束时间 |
| App 正常退出 | 不结束专注，下次启动时恢复倒计时 |
| App 崩溃或被强制退出 | 启动时查找 `endedAt == nil` 的 FocusSession：没超时就恢复；已超时就补上「时间到」的处理 |
| 勿扰没被关掉 | 用 `UserDefaults` 记录「勿扰是由 Immerse 打开的」；启动时如果有这个标记但没有进行中的专注，就自动关闭勿扰 |

### 6.6 用户操作

| 操作 | 对计划时长的影响 | 对勿扰的影响 | 对兜底通知的影响 |
|---|---|---|---|
| 暂停 | 记录 `pausedAt` | 保持开启 | 取消 |
| 继续 | `pausedSeconds += now − pausedAt` | 保持开启 | 按新的结束时间重新安排 |
| +15 分钟 | `plannedSeconds += 900` | 保持开启 | 重新安排 |
| 提前完成 | 结束，`finishedEarly` | 关闭 | 取消 |
| 放弃 | 结束，`abandoned`，任务状态改回 todo | 关闭 | 取消 |

---

## 7. 系统集成

### 7.1 勿扰（`DoNotDisturbService`）

**实现方式**：用户在「快捷指令」App 里建两个快捷指令，App 用 `Process` 调用 `/usr/bin/shortcuts run "<名称>"` 执行。

| 快捷指令（默认名称） | 内容 |
|---|---|
| `Immerse 开启勿扰` | 操作「设定专注模式」→ 打开「勿扰模式」→ 持续到「关闭」 |
| `Immerse 关闭勿扰` | 操作「设定专注模式」→ 关闭「勿扰模式」 |

```swift
protocol DoNotDisturbServicing {
    func checkSetup() async -> SetupStatus     // 执行 `shortcuts list`，确认两个快捷指令都存在
    func enable() async throws
    func disable() async throws
}
```

| 要点 | 处理 |
|---|---|
| 执行方式 | 放在后台执行，不阻塞主线程；超时 5 秒 |
| 失败处理 | 在菜单栏显示一个提示，计时照常进行 |
| 首次引导 | 分步说明 + 截图 + 「打开快捷指令」按钮（`shortcuts://` 链接）+「重新检测」按钮 |
| 可选优化 | 用 `shortcuts sign` 生成两个签名好的 `.shortcut` 文件放进 App，用户双击即可导入，省去手动创建（M4 视情况做） |
| 设置项 | 勿扰总开关；两个快捷指令的名称可以修改 |
| 专注模式选择 | 默认用系统的「勿扰模式」；用户也可以在快捷指令里换成自建的专注模式，App 不需要改动 |

### 7.2 通知（`NotificationService`）

- 使用 `UNUserNotificationCenter`，首次开始专注时请求权限
- 注册通知类别 `FOCUS_END`，包含两个操作按钮：`COMPLETE`（标记完成）、`EXTEND_15`（再延长 15 分钟）
- 实现 `willPresent` 代理方法，App 在前台时也显示横幅并播放声音
- 用户点击操作按钮后，`AppDelegate` 收到回调并转给 `FocusEngine` 处理

### 7.3 键盘快捷键

| 快捷键 | 功能 | 实现 |
|---|---|---|
| `⌘N` | 新建日程 | `.commands` 菜单项 |
| `⌘K` | 打开命令面板 | `.commands` 菜单项 |
| `⌘F` | 搜索 | `.commands` 菜单项 |
| `⌘Z` / `⇧⌘Z` | 撤销 / 重做 | 系统自带，基于 `UndoManager` |
| `T` | 回到今天 | 主窗口 `.onKeyPress`，输入框获得焦点时不响应 |
| `D` / `W` / `M` | 切换日 / 周 / 月视图 | 同上 |
| `J` / `K`、`←` / `→` | 上一页 / 下一页 | 同上 |
| `Space` | 开始或暂停专注（针对选中的任务） | 同上 |
| `⌫` | 删除选中的日程 | 同上，删除后显示可撤销的提示 |
| `Esc` | 关闭浮层，或取消选中 | 同上 |

---

## 8. 命令面板与自然语言解析

### 8.1 命令面板

- `⌘K` 呼出居中的毛玻璃浮层，同时支持「执行命令」和「快速新建」
- 输入内容时实时显示解析结果预览，例如：`📅 11月19日 15:00–16:00 · 🟡 重要 · 阅读《第一性原理》`
- 按 `↩` 创建日程，按 `⌘↩` 创建并立即开始专注

### 8.2 解析规则（本地规则引擎，不联网）

| 类别 | 支持的写法 | 示例 |
|---|---|---|
| 相对日期 | 今天、明天、后天、大后天 | `明天` |
| 星期 | 周X / 星期X / 下周X / 本周X | `下周三` |
| 绝对日期 | M月D日、M/D、M-D | `11月20日`、`11/20` |
| 时段 | 上午、中午、下午、晚上 + X点 / X点半 / HH:mm | `下午3点半`、`20:30` |
| 时间段 | X点到Y点、HH:mm-HH:mm | `3点到5点` |
| 时长 | N小时、N分钟、Nh、Nmin、半小时 | `1小时`、`45min` |
| 优先级 | 紧急、重要、普通、`!!!`、`!!`、`!` | `重要` |
| 地点 | `@地点` | `@图书馆` |
| 标题 | 去掉上面识别出的部分后剩下的文本；`《》` 原样保留 | `阅读《第一性原理》` |

- 没写时间就创建为全天日程；只写了时长就作为计划专注时长
- 实现方式：先用正则从左到右识别各类片段，再组装成结果；解析器是纯函数，有 30 个以上的单元测试用例

---

## 9. 设计系统

### 9.1 毛玻璃封装（为以后切换到 Liquid Glass 预留）

```swift
enum GlassStyle { case sidebar, toolbar, panel, overlay, immersive }

extension View {
    /// 所有玻璃效果都统一走这个方法；以后升级到 macOS 26 只需要改这里
    func glassSurface(_ style: GlassStyle, cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassSurfaceModifier(style: style, cornerRadius: cornerRadius))
    }
}

struct GlassSurfaceModifier: ViewModifier {
    let style: GlassStyle
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            // 以后在这里接入 .glassEffect(...)
        }
        #endif
        content
            .background(material(for: style), in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))   // 玻璃边缘的高光
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}
```

| 位置 | 材质 | 实现方式 |
|---|---|---|
| 窗口背景 | 透出桌面的毛玻璃 | `NSVisualEffectView`，`material = .underWindowBackground`，`blendingMode = .behindWindow` |
| 侧栏 | `.sidebar` | `NavigationSplitView` 自带 |
| 顶栏 | `.bar` | `.toolbarBackground` |
| 日程弹窗、命令面板 | `.ultraThinMaterial` / `.regularMaterial` | `glassSurface(.panel / .overlay)` |
| 沉浸视图 | `.hudWindow` + 当前任务优先级颜色的径向渐变 | `NSVisualEffectView` |
| 日历网格 | 不透明，保证文字清晰 | — |

### 9.2 配色

| 语义 | 浅色模式 | 深色模式 | 用在哪里 |
|---|---|---|---|
| 紧急 | `#E5484D` | `#FF6369` | 日程块填充（透明度 0.18）+ 左侧 3pt 色条 |
| 重要 | `#F5A524` | `#FFC53D` | 同上 |
| 普通 | `#8E4EC6` | `#B07EE8` | 同上 |
| 当前时间线 | `systemRed` | `systemRed` | |
| 已完成 | `secondaryLabel` | `secondaryLabel` | 加删除线 |

### 9.3 字体与动画

- 字体：系统字体（SF Pro）；倒计时数字用 `.monospacedDigit()`，避免数字跳动；图标统一用 SF Symbols
- 动画：统一用 `Motion.snappy = .spring(response: 0.3, dampingFraction: 0.85)`
- 尊重系统「减少动态效果」设置：开启时关闭呼吸效果和 spring 动画

---

## 10. 测试策略

| 层级 | 覆盖内容 | 工具 |
|---|---|---|
| 单元测试 | `FocusEngine` 状态切换、计时计算（注入一个可控时钟）、`EventLayoutEngine`、`NaturalLanguageParser` | Swift Testing |
| 集成测试 | `SwiftDataTaskRepository` 增删改查（用内存数据库） | Swift Testing |
| 手工验收 | 每个阶段的验收标准（见第 11 节） | 运行 App + 截图 |

`FocusEngine` 不直接调用 `Date()`，而是依赖一个 `Clock` 协议。测试时注入假时钟，几毫秒就能跑完「专注 1 小时 + 睡眠 + 唤醒」这类场景。

---

## 11. 里程碑

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **M1** 骨架 | XcodeGen 工程、数据模型、假数据、毛玻璃封装、周视图（时间网格、日程块、全天行、当前时间线、重叠排布）、侧栏骨架 | 能看到带假数据的周视图；优先级颜色正确；重叠的日程正确并排；浅色和深色模式都正常 |
| **M2** 日程管理 | 拖拽创建、移动、调整时长；详情面板；`⌘N`；删除和撤销；搜索和筛选；今日任务列表 | 所有增删改查都能在日历上完成；`⌘Z` 能撤销拖拽和删除 |
| **M3** 专注计时 | `FocusEngine`、菜单栏倒计时、通知和操作按钮、睡眠和崩溃恢复 | 1 分钟的测试任务能按时弹出通知；睡眠 2 分钟后唤醒，剩余时间正确；强制退出后重新打开能恢复 |
| **M4** 勿扰 | `DoNotDisturbService`、引导页、设置页、勿扰状态兜底恢复 | 开始专注后系统进入勿扰，时间到了先退出勿扰再提醒；快捷指令缺失时有清楚的提示 |
| **M5** 完善 | 日视图和月视图、`⌘K` 自然语言解析、沉浸视图、全部快捷键、动画打磨 | 风格统一；快捷键全部可用；自然语言解析的单元测试全部通过 |
| **M6** 导入与统计 | 导入 Notion CSV（预览 + 去重 + 一步撤销）、专注统计窗口 | 导入你导出的 CSV 不丢字段；统计数字与专注记录一致 |

---

## 12. 风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| 系统没有切换勿扰的公共 API | 必须让用户手动建快捷指令 | 引导页 + 自动检测 + 可选的签名快捷指令文件 |
| 勿扰会把我们的提醒静音 | 时间到了用户收不到提醒 | 由 App 主动驱动：先关勿扰再提醒；并引导用户把 Immerse 加入勿扰的允许列表 |
| SwiftUI 在 macOS 14 上自定义拖拽和光标的能力有限 | 拖拽手感不如 Notion Calendar | 必要时在时间网格这一层改用 `NSViewRepresentable`，用 AppKit 处理鼠标事件 |
| SwiftData 早期版本的 bug（macOS 14 上的谓词和关系） | 查询可能出错 | 谓词只用基础类型字段（枚举存原始值）；复杂的过滤放在内存里做；所有访问都经过 Repository，出问题可以换成 Core Data |
| App Nap 导致计时器延迟 | 提醒晚到 | 专注期间使用 `beginActivity`；同时有系统兜底通知 |
| 没有 Xcode 无法编译 | 阻塞开发 | 开工前安装 Xcode 16.2（见 1.1） |

---

## 13. 已采用的默认值

以下问题没有收到反对意见，按默认方案执行，后续可以调整：

| 问题 | 默认方案 |
|---|---|
| App 名称 | `Immerse`（暂定） |
| 全天任务能否开始专注 | 可以；没设计划时长就默认 60 分钟 |
| 实际专注时间和日程安排的时间不一致 | 不移动日程，也不在日历上标出实际专注时间段，只计入统计 |
| 每周第一天 | 周一 |
| 自然语言解析 | 本地规则，不联网 |
| 勿扰使用哪种专注模式 | 系统「勿扰模式」 |
| 导入 Notion 数据 | 放到 M6 |
| 签名方式 | 本机 ad-hoc 签名，不公证 |

---

## 14. 实现记录（M1–M6）

### 14.1 各阶段提交

| 阶段 | 提交 | 验证方式 |
|---|---|---|
| M1 | `feat: add M1 week view with sample data` | 浅色 / 深色截图 |
| M2 | `feat: add task editing, drag, inspector and undo` | 单元测试（撤销 / 重做、拖拽计算）+ 详情面板、搜索截图 |
| M3 | `feat: add focus timer, menu bar and notifications` | 单元测试（假时钟模拟睡眠、重启、时间到）+ 专注中、时间到截图 |
| M4 | `feat: add do-not-disturb via shortcuts and onboarding` | 单元测试 + 引导页截图；真实切换勿扰见 14.3 |
| M5 | `feat: add command palette, month and immersive views` | 自然语言解析 22 组测试（50+ 个用例）+ 月视图、命令面板、沉浸视图截图 |
| M6 | `feat: add notion csv import and focus stats` | CSV / 日期格式 / 统计测试 + 统计窗口截图 |

当前共 75 个单元测试，全部通过；编译零警告。

### 14.2 和原方案的差异

| 方案原文 | 实际实现 | 原因 |
|---|---|---|
| 视图直接使用 `TaskItem` | 数据层之上只用值类型 `TaskSnapshot` | 视图不受托管对象生命周期影响；除数据层外的代码都能脱离 SwiftData 测试 |
| 撤销依赖 `ModelContext` 自带的 undo | `TaskStore` 自己注册逆操作，每个操作显式分组（`groupsByEvent = false`） | 测试发现默认按事件循环分组会把「新建 + 修改」合成一步；专注引擎改状态不进撤销栈 |
| 删除任务级联删除专注记录 | 改为 `.nullify`，专注记录冗余保存任务标题 | 删了任务统计数据不丢 |
| 数据库默认路径 | `~/Library/Application Support/com.debugzhao.immerse/Immerse.store` | 不开沙盒时 SwiftData 默认写 `default.store`，会和其他 App 冲突 |
| M6 同步 Notion | 导入 Notion 导出的 CSV | 直接调 Notion API 需要集成 token，第一版不处理凭据 |
| 沉浸视图用 `NSVisualEffectView(.hudWindow)` | `ultraThickMaterial` + 优先级色径向柔光 | 文字对比度更稳 |

### 14.3 已知限制

| 限制 | 说明 |
|---|---|
| 勿扰真实切换未端到端验证 | 开发环境里 `/usr/bin/shortcuts` 一启动就被系统 SIGKILL（命令行和 App 内调用都一样），疑似设备管理策略限制。App 已做降级：检测失败会提示具体原因，计时不受影响。需要在本机终端运行 `shortcuts list` 确认 |
| 菜单栏面板未截图 | Debug 自截图只能截 App 自己的窗口，菜单栏面板需要手动查看 |
| 拖拽、悬停等交互未自动化测试 | 计算逻辑（`EventEditing`）有单元测试，手感需要手动体验 |
| 截图里的毛玻璃不透出桌面 | `behindWindow` 模糊无法被窗口内截图捕获，以屏幕实际效果为准 |

### 14.4 开发辅助：Debug 自截图

只在 Debug 版本中可用，使用内存数据库 + 示例数据，不碰真实数据、不发通知：

```bash
IMMERSE_SNAPSHOT=/tmp/shot.png build/DerivedData/Build/Products/Debug/Immerse.app/Contents/MacOS/Immerse
```

可选环境变量：`IMMERSE_APPEARANCE=dark`、`IMMERSE_MODE=day|week|month`、`IMMERSE_SELECT=<关键字>`、`IMMERSE_SEARCH=<关键字>`、`IMMERSE_FOCUS=<关键字>[,秒数]`、`IMMERSE_IMMERSIVE=1`、`IMMERSE_PALETTE=1`、`IMMERSE_STATS=1`、`IMMERSE_ONBOARDING=1`。

### 14.x 迭代：Notion 风格日程弹窗

原来的新建浮层（280pt 宽的 popover）太小，右侧详情面板也和新建不一致，统一改成居中弹窗：

| 项 | 说明 |
|---|---|
| 外观 | 640pt 宽、最高 560pt 的毛玻璃卡片 + 半透明遮罩；28pt 大标题 + 属性列表（日期 / 优先级 / 状态 / 地点 / 专注时长）+ 备注正文 |
| 新建 | 框选、双击空白、`⌘N` 打开；`↩` / `⌘↩` 创建；Esc、取消、点遮罩都只关闭不创建（填写的内容保留到下次）；改时间时日历上的虚线草稿块同步移动 |
| 编辑 | 双击日程、`↩`、右键「打开」；改动立即保存（文字连续输入合并成一步撤销）；顶栏有「开始专注」和「⋯」（完成 / 删除） |
| 交互约束 | 弹窗打开时日历的单键快捷键（Space、⌫、D/W/M…）全部让路；`⌘⌫` 在文本框里改为删除到行首 |
| 截图 | `IMMERSE_EDIT=<关键字>`、`IMMERSE_CREATE=1` |

### 14.x 迭代：时间选择与 Markdown 备注

| 项 | 说明 |
|---|---|
| 时间 | 去掉日期选择器，日期跟随日历上选的那天（只展示）；开始 / 结束是两个大按钮，点开是 15 分钟刻度的时间列表（32pt 行高、自动滚到当前值）；结束列表每项附带时长，顶部有 30 分钟 / 1 / 1.5 / 2 小时快捷项；跨天显示「次日」。候选项由 `TimeSlots` 纯函数生成 |
| 备注 | `MarkdownEditor`（NSTextView + TextKit 1）实时预览：存储仍是 Markdown 源码，`MarkdownStyler.spans` 纯函数解析出每段语法及其「显示源码」范围；光标不在其中时标记打上 `.mdHidden`，由 `MarkdownLayoutManager` 生成 null glyph 隐藏，列表圆点 / 复选框 / 引用竖线 / 代码块背景 / 分隔线 / 提及底色由它绘制。行内元素光标触碰即显示源码，链接仅光标在内部时显示（粘贴后保持渲染），标题 / 引用按行显示。输入法组字时不重排样式，避免打断候选 |
| 编辑辅助 | 回车续写 `-` / `1.` / `- [ ]` / `>`，空项回车先取消缩进再结束列表；` ``` ` 回车自动补闭合；`[] ` / `【】 ` 转待办；列表行首退格还原为正文；Tab / ⇧Tab 缩进；光标跳过圆点 / 复选框。`/` 或 `、`（行首或空格后）打开块菜单（`SlashMenu`：不抢焦点的子面板，按标题 / 英文 / 拼音过滤，选中后删掉 `/查询` 并一次性替换整行）。格式快捷键和菜单的 ↑↓ / 回车 / Esc 通过本地按键监听处理——SwiftUI 窗口会在 `performKeyEquivalent` 到达内嵌视图前吞掉 ⌘ 组合键，弹窗也会占用 Esc。⌘B / ⌘I / ⇧⌘X / ⌘E 切换包裹，⌘K 给选中文字加链接（无选中时仍是命令面板），⌥⌘0–6 / Q / C 切换块类型。粘贴网址插入 `[@标题](url)`：先用 URL 猜标题（Notion 取 slug），后台抓取 og:title / title 替换，登录墙的通用标题会被忽略。点击 `[ ]` 切换勾选、点击链接打开（⌥ 点击进入编辑），均可撤销 |
| 截图 | `IMMERSE_NOTES=<文字>`（配合 `IMMERSE_EDIT`，`\n` 换行） |

### 14.x 迭代：草稿保留、进度提醒、每日复盘、时钟倒计时

| 功能 | 实现 | 限制 |
|---|---|---|
| 新建内容保留 | 新建弹窗消失时（Esc / 取消 / 点外面）没创建就存进 `CalendarStore.unsavedDraft`；下次打开恢复，时间以新选的为准（`⌘N` 连时间一起恢复）；顶栏可「清空」 | 只保存在内存里，退出 App 后丢失 |
| 进度提醒 | `FocusEngine` 按「剩余专注时长」推算各百分比的时刻，交给系统定时通知；暂停时取消、继续 / 延长 / 恢复时重排；已经过了的百分比记在 `notifiedMilestones`，延长后不重复 | 勿扰开启时，需要把 Immerse 加入勿扰「允许的 App」才会弹出（time-sensitive 通知需要付费开发者证书） |
| 每日复盘 | `DailyReviewScheduler` 用 `UNCalendarNotificationTrigger` 安排下一次提醒（默认 21:00）；任务变动、设置变动、每 30 分钟、睡眠唤醒都会重排，保证内容最新；内容由 `DailyReview.content` 纯函数生成 | App 很久没开时内容可能过期（以最后一次安排时为准） |
| 时钟倒计时 | 「时钟」无公开 API，用快捷指令：`shortcuts run "Immerse 开始计时" --input-path <分钟数.txt>` →「从输入中获取数字」→「开始计时器」 | 暂停 / 提前结束不会同步到「时钟」 |

### 14.x 修复：安装包带出开发者日程

| 项 | 说明 |
|---|---|
| 原因 | 0.1.x 首次启动会写入 `SampleData` 示例任务（标题取自开发者的 Notion 日程），Release 也会执行，所以所有安装者都看到了这些任务。DMG 本身不含数据文件 |
| 修复 | `SampleData` 只编进 DEBUG，仅供截图模式写入内存库，标题换成通用示例；正式版首次启动是空日历 |
| 存量清理 | `LegacySampleCleanup` 启动时执行一次：只删「标题命中旧示例 + 同一批写入（createdAt 相差 ≤ 5 秒、至少 8 条）」的任务，用户自己建的同名任务不受影响；旧标题以 SHA-256 存储，二进制里不含明文 |

### 14.x 迭代：检查更新

| 项 | 说明 |
|---|---|
| 数据源 | GitHub API `repos/debugzhao/Immerse/releases/latest`（公开仓库，无需 token）；取 `tag_name`、`body`、`.dmg` 附件链接 |
| 自动检查 | 启动时检查，24 小时内最多一次；有新版本弹出更新窗口；「跳过此版本」后自动检查不再提示该版本 |
| 手动检查 | 菜单「沉浸日程 → 检查更新…」或 设置 → 关于；总会给出结果（新版本 / 已是最新 / 失败），忽略跳过记录 |
| 安装 | 只负责提示和打开 DMG 下载链接，安装仍是拖进「应用程序」替换（无 Developer ID 证书，暂不做 Sparkle） |
| 逻辑 | `AppVersion` 纯函数：数字比较版本（0.1.10 > 0.1.9）、解析 GitHub JSON；`UpdateChecker` 可注入 fetch 便于测试 |

### 14.x 迭代：收集箱与目标

| 项 | 说明 |
|---|---|
| 模型 | `TaskSnapshot.kind`：`event`（日程，原有）/ `idea`（收集箱）/ `goal`（目标，周期用全天的起止日期表示）；日程可带 `goalID` 关联目标；目标可设 `targetMinutes` |
| 迁移 | `TaskItem` 新增 `kindRaw` / `goalID` / `targetMinutes`，全部可选，SwiftData 自动轻量迁移；`kindRaw == nil` 视为日程。已用真实数据库副本验证 |
| 日历 | `tasks(in:)` 只返回日程，收集箱和目标不会出现在时间网格里 |
| 排期 | 侧栏行 `.draggable(uuid)` → 时间网格 / 全天行 / 月视图 `.dropDestination`；想法拖入变成日程，目标拖入生成一条关联日程（目标本身保留）。均为一步撤销 |
| 进度 | `GoalProgress` 纯函数：周期内「目标本身 + 关联日程」的专注时长 / 目标时长；没设时长时按完成次数；进度落后时间 15 个百分点以上算落后 |
| 专注 | 可以直接专注目标，但不会改变目标的状态（目标跨多次完成） |
| 入口 | 侧栏输入框；⌘K「想法：…」「本周目标：…」「本月目标：…」；任意输入都有「放进收集箱」选项 |
| 复盘 | 每晚复盘通知附带「进度落后的目标」 |

