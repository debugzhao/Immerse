# Immerse

> 用最轻的方式安排日程，用最强的方式进入专注。

一款 macOS 日程管理 App：以日历的形式管理日程，点击「开始」就自动计时、开启勿扰，时间到了再提醒你。

## 功能

| 模块 | 功能 |
|---|---|
| 📅 日历 | 日 / 周 / 月视图；拖拽框选或双击新建，拖动移动、拉边缘调整时长；重叠日程自动并排 |
| ✏️ 日程 | 优先级（紧急 / 重要 / 普通）、状态、地点、备注、专注时长；双击日程打开 Notion 风格的弹窗编辑；⌘Z 撤销 |
| ⌘K 命令面板 | 中文自然语言新建：「明天下午3点 阅读《第一性原理》 1小时 重要」 |
| ⏱ 专注 | 一键开始倒计时；菜单栏显示剩余时间；暂停 / +15 分钟 / 提前完成 / 放弃；全屏沉浸模式 |
| 🌙 勿扰 | 专注时通过「快捷指令」自动开启系统勿扰，时间到先关勿扰再提醒 |
| 📊 统计 | 今日 / 本周专注时长、最近 7 天柱状图、连续专注天数；日历上用绿色细条标出实际专注时间 |
| 📥 导入 | 导入 Notion 数据库导出的 CSV |

## 快捷键

| 快捷键 | 功能 |
|---|---|
| `⌘N` | 新建日程（打开新建弹窗，`↩` / `⌘↩` 创建） |
| 双击日程 / `↩` | 打开日程弹窗编辑 |
| `⌘K` | 命令面板 |
| `⌘F` | 搜索 |
| `Space` | 开始 / 暂停专注（选中的日程） |
| `⌘↩` | 开始专注选中的日程 |
| `T` | 回到今天 |
| `D` / `W` / `M` | 日 / 周 / 月视图 |
| `J` / `K` 或 `←` / `→` | 上一页 / 下一页 |
| `⌫` | 删除选中的日程 |
| `⌘Z` / `⇧⌘Z` | 撤销 / 重做 |
| `⌃⌘F` | 进入沉浸模式 |
| `⇧⌘I` | 导入 Notion CSV |

## 编译运行

环境要求：macOS 14+、Xcode 16.2、XcodeGen。

```bash
scripts/build.sh
```

```bash
open build/DerivedData/Build/Products/Debug/Immerse.app
```

跑单元测试：

```bash
xcodegen generate && xcodebuild -project Immerse.xcodeproj -scheme Immerse -destination 'platform=macOS' test
```

> 工程文件 `Immerse.xcodeproj` 由 XcodeGen 根据 `project.yml` 生成，不提交到 git。要用 Xcode 打开，先运行一次 `xcodegen generate`。

## 首次使用：设置勿扰

macOS 不允许 App 直接切换勿扰，需要在「快捷指令」里建两个快捷指令（App 首次启动时有引导）：

1. 新建快捷指令，添加操作「设定专注模式」→ 打开「勿扰模式」→ 直到关闭，命名为 `Immerse 开启勿扰`
2. 再建一个，操作设为关闭「勿扰模式」，命名为 `Immerse 关闭勿扰`

## 从 Notion 导入

在 Notion 数据库右上角 `⋯` → 导出 → Markdown & CSV，解压后在 Immerse 里选择「文件 → 导入 Notion CSV…」。

## 文档

- [技术方案](docs/TECH_DESIGN.md)
