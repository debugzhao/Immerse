# iPhone 版上架准备（M6）

> 2026-11-20 · 代码侧已完成的部分和需要你亲自完成的部分分开列出

## 0. 结论

**代码侧已经就绪：隐私清单、导出配置、TestFlight 自动上传流程、隐私政策草稿、商店文案都已准备好。剩下的都需要你的 Apple 账号或本人身份：开发者账号、证书与 App Group、备案、截图审核、点「提交」。** 按下面第 1 节的顺序做，大约 1–2 周（主要等备案）。

## 1. 需要你完成的步骤（按顺序）

| # | 步骤 | 说明 | 阻塞什么 |
|---|---|---|---|
| 1 | 加入 Apple Developer Program | 99 美元/年（国区 688 元） | 后面所有步骤 |
| 2 | 在开发者后台注册标识 | App ID `com.debugzhao.immerse`（勾选 App Groups、iCloud、Push 不需要）；App ID `com.debugzhao.immerse.widgets`；App Group `group.com.debugzhao.immerse`；iCloud 容器 `iCloud.com.debugzhao.immerse` | 真机运行、小组件共享数据、iCloud 同步 |
| 3 | 把 Team ID 告诉我 | 我会写进 `project.yml` 的 `DEVELOPMENT_TEAM`，并给两个 target 加上 iCloud entitlement、在 Info.plist 写入 `ImmerseCloudKitContainer`（代码已支持，填上就开启同步） | 真机调试、CloudKit |
| 4 | 在 App Store Connect 新建 App | 名称「沉浸日程」，主语言简体中文，Bundle ID 选第 2 步的 | TestFlight |
| 5 | 创建 App Store Connect API Key | 「用户和访问 → 集成 → App Store Connect API」，角色 App Manager；下载 `.p8` | 自动上传 |
| 6 | 配置 GitHub Secrets | `APPLE_TEAM_ID`、`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_P8_BASE64`（`base64 -i AuthKey_xxx.p8 \| pbcopy`） | 自动上传 |
| 7 | 触发上传 | GitHub → Actions → iOS TestFlight → Run workflow，或推送 `ios-v0.2.0` 标签 | TestFlight 内测 |
| 8 | 发布隐私政策 | 把 `docs/privacy-policy.md` 放到官网（例如 `/privacy`），网址填进 App Store Connect | 提交审核 |
| 9 | 办理 App 备案（ICP） | 通过阿里云或腾讯云办理，需要等管局审核（通常 1–3 周），拿到备案号填进 App Store Connect；**建议现在就开始** | 国区上架 |
| 10 | 截图 | 6.9 英寸（iPhone 16 Pro Max，1320×2868）至少 3 张；可以用 TestFlight 版截，或等模拟器下好后我来生成 | 提交审核 |
| 11 | 提交审核 | 填好第 3 节的隐私标签、第 4 节的审核备注，提交 | — |

## 2. CI 选择

| | GitHub Actions（已配好） | Xcode Cloud |
|---|---|---|
| 文件 | `.github/workflows/ios-testflight.yml`、`ci/ExportOptions.plist` | `ci_scripts/ci_post_clone.sh` |
| 现状 | 加好 Secrets 即可用；手动触发或推 `ios-v*` 标签 | Xcode Cloud 建立 workflow 时要求仓库里有 `.xcodeproj`，而本项目的工程由 XcodeGen 生成、不提交。要用 Xcode Cloud 需要把 `Immerse.xcodeproj` 从 `.gitignore` 移除并提交 |
| 费用 | 公开仓库免费 | 开发者账号每月 25 小时 |
| 推荐 | ✅ 先用这个 | 以后有需要再切 |

## 3. App 隐私标签（App Store Connect → App 隐私）

| 问题 | 回答 |
|---|---|
| 是否收集数据？ | **是**（因为开启 AI 后内容会发给第三方 Anthropic） |
| 数据类型 | 用户内容 → **其他用户内容** |
| 用途 | App 功能 |
| 是否与身份关联 | 否 |
| 是否用于跟踪 | 否 |

与 `ImmerseiOS/Resources/PrivacyInfo.xcprivacy` 保持一致。

## 4. 审核备注（Review Notes，可直接粘贴）

```
Immerse is a calendar and focus timer. All core features (calendar, inbox, goals, focus timer, Live Activity,
widgets, rule-based scheduling, evening review) work fully offline without any account.

AI features are optional and use the user's own Anthropic API key, entered in Settings → 秘书 AI → API Key.
Before saving the key the user must accept an in-app notice describing exactly what is sent to Anthropic
(App Review Guideline 5.1.2(i)). No data is sent anywhere until then.

For review, a test key is provided below. To try AI: open the "+" button, type 「明天下午3点 和老王聊预算 1小时」,
tap 「智能整理」; or in the 规划 tab tap 「排进本周」 to see a scheduling proposal (nothing is written until 应用 is tapped).

Test API key: <填入一个限额的测试 Key，审核通过后删除>

The app does not keep running in the background: timers are computed from timestamps and reminders are
scheduled local notifications. Background App Refresh is only used to refresh the next morning's briefing text.
```

## 5. 商店文案（中文）

- **名称**：沉浸日程
- **副标题**（30 字以内）：会排期的私人日程秘书
- **关键词**：日程,日历,专注,番茄钟,时间管理,待办,计划,秘书,效率,倒计时
- **推广文本**：一句话记下待办，秘书帮你排进空档；计划被打乱时一键重排，晚上帮你复盘。
- **描述**：

```
沉浸日程是一款会排期的日历：随手记下要做的事，秘书帮你找到合适的时间，开始后自动倒计时，结束时提醒你。

【一句话记下】
· 「明天下午3点 和老王聊预算 1小时 重要」自动识别时间、时长和优先级
· 按住说话、粘贴网页链接，都能直接变成待办
· 大任务自动拆成可以一次做完的小步骤

【秘书帮你排】
· 一键把收集箱排进本周的空档，避开系统日历里的会议和你的固定安排
· 难的事排进你精力最好的时段，有截止日期的按截止日倒推
· 所有改动先以虚线预览，你确认后才写入，随时一步撤销

【计划被打乱也不慌】
· 专注被打断、延长或错过时，提议把后面的安排顺延
· 今天排太满时提醒你，并建议挪走哪几项
· 赶不上截止时提前告诉你，并给出补救方案

【专注】
· 一键开始倒计时，锁屏和灵动岛实时显示剩余时间
· 开始前提示上次做到哪、备注里还有哪些待办
· 全屏沉浸模式，专注期间秘书不会打扰你

【越用越懂你】
· 统计你的高效时段和估时偏差，以后排得更准
· 记住你的固定安排，例如「每周三晚上打球」
· 晨间简报和晚间复盘，每天最多 3 条主动提醒

AI 功能可选：填写你自己的 Anthropic API Key 即可开启，未开启时排期、重排、预警、复盘等功能照常在本机运行。
```

## 6. 上架前自查

| 项目 | 状态 |
|---|---|
| `ITSAppUsesNonExemptEncryption = NO` | ✅ 已写入 Info.plist |
| `UIDesignRequiresCompatibility = YES`（iOS 26 先保持旧样式） | ✅ |
| 隐私清单（App + 小组件） | ✅ |
| 权限说明文案（日历、麦克风、语音识别） | ✅ |
| 通知、日历、麦克风都在用户触发时才申请 | ✅ |
| 不用后台保活（计时靠时间戳 + 本地通知） | ✅ |
| 图标无透明通道 | ✅ `scripts/make-icon.swift --ios` |
| 隐私政策网址 | ⏳ 第 1 节第 8 步 |
| ICP 备案号 | ⏳ 第 1 节第 9 步 |
| 截图 | ⏳ 第 1 节第 10 步 |
| 真机测试（iOS 17.x 和 18.x） | ⏳ 需要开发者账号 |
