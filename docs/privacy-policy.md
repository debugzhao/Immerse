# 沉浸日程 Immerse 隐私政策

> 草案 · 2026-11-20 · 上架前需要发布到一个公开网址（例如官网 `/privacy`），并填进 App Store Connect

**一句话：你的日程只存在你自己的设备上（开启 iCloud 后同步到你自己的 iCloud）；只有你主动开启 AI 并填写自己的 API Key 后，相关内容才会发送给 Anthropic 处理。我们没有服务器，也不收集任何数据。**

## 1. 我们存储什么、存在哪里

| 数据 | 存储位置 | 谁能看到 |
|---|---|---|
| 日程、收集箱、目标、备注、专注记录 | 本机；开启 iCloud 同步后在你的 iCloud 私有数据库 | 只有你 |
| 秘书记忆（例如「周三晚上打球」） | 同上 | 只有你 |
| 设置、用量统计 | 本机 | 只有你 |
| Anthropic API Key | 本机钥匙串，仅限这台设备，不同步、不备份到其他设备 | 只有你 |

开发者没有任何服务器，无法看到你的数据。

## 2. AI 功能会发送什么

AI 功能默认开启，但只有在你**填写自己的 API Key 并同意数据说明**后才会真正调用。调用时，沉浸日程直接把请求发送给 Anthropic（Claude），内容包括：

- 你输入、说出或粘贴的那句话
- 相关任务的标题、时间、分类、优先级、截止日期
- 统计数字（例如当天已排时长、完成率、高效时段）

**不会发送：** 任务备注（只有你主动点「拆成小步骤」时，才会附上那一条任务的备注）、系统日历的会议详情（排期时只用到会议的时间段和标题）、你的位置、通讯录或任何设备标识。

请求通过你自己的 Anthropic 账户发送，适用 Anthropic 的隐私政策和数据保留规则：<https://www.anthropic.com/legal/privacy>。你可以随时在「设置 → 秘书 AI」关闭 AI 或删除 API Key，关闭后所有功能改用本机规则运行。

## 3. 权限

| 权限 | 用途 | 不授权会怎样 |
|---|---|---|
| 通知 | 专注结束、进度提醒、晨间简报、每晚复盘 | 收不到提醒，其他功能正常 |
| 日历（完全访问） | 只读系统日历里的会议，排期时避开 | 排期时不考虑系统日历的会议 |
| 麦克风、语音识别 | 按住说话记录待办；支持的设备上在本机完成识别 | 不能语音输入 |

沉浸日程不会修改你的系统日历。

## 4. 儿童

本应用不面向 13 岁以下儿童，也不会有意收集儿童的信息。

## 5. 变更与联系

政策变更会在应用更新说明和本页面中注明。有任何问题，请在 GitHub 提交 Issue：<https://github.com/debugzhao/Immerse/issues>。

---

## Immerse Privacy Policy (English summary)

Your schedule lives on your device (and in your own private iCloud database if you turn sync on). There is no server and the developer collects nothing. AI features only run after you enter your own Anthropic API key and accept the data notice; then the sentence you typed, relevant task titles, times, categories and summary numbers are sent directly to Anthropic under your account. Notes are not sent unless you ask to split that task. The API key stays in this device's Keychain. Permissions (notifications, read-only calendar access, microphone and speech recognition) are optional and only used for the features described above.
