---
name: release
description: 发布 Immerse 新版本：提交并 push 代码、升版本号、跑测试、打包 DMG、打 tag、发布 GitHub Release。当用户说"发版""发 release""打包发布""push 代码打包发布"或输入 /release [patch|minor|major|x.y.z] 时使用。
argument-hint: "[patch|minor|major|x.y.z]"
---

# 发布 Immerse

参数 `$ARGUMENTS`：版本号升级方式，默认 `patch`；也可以直接给 `x.y.z`。

按顺序执行，任何一步失败就停下来报告，不要跳过。

## 0. 环境

这台 Mac 的 Xcode 不在 /Applications，xcodegen 在 `~/.local/bin`。每条 Bash 命令前都带上：

```bash
export DEVELOPER_DIR=/Users/tyson/Downloads/Xcode.app/Contents/Developer PATH="$HOME/.local/bin:$PATH"
```

Shell 是 zsh：取管道退出码不要用 `PIPESTATUS`（不生效），改用 grep 结果判断。

## 1. 检查状态

```bash
git status --short
git log --oneline origin/main..HEAD   # 未 push 的提交
git describe --tags --abbrev=0        # 上一个 tag
git log --oneline $(git describe --tags --abbrev=0)..HEAD
```

- 上个 tag 之后**没有任何新提交、也没有未提交改动** → 告诉用户没有可发布的内容，停止。
- 有未提交改动 → 先看 diff，按 Conventional Commits 拆成合理的提交（`type(scope): description`，英文小写祈使句，≤50 字符，不加句号）。看不懂意图的改动先问用户。

## 2. 升版本号

版本号在 `project.yml` 的 `CFBundleShortVersionString`，构建号在 `CFBundleVersion`。

- `patch` / `minor` / `major`：按语义化版本递增；没给参数时，上个 tag 之后有 `feat` 提交用 `minor`，否则用 `patch`。0.x 阶段把 feat 也当 patch 处理，除非用户明确要 minor。
- `CFBundleVersion` 每次 +1。
- 确认新 tag `v<版本号>` 在本地和远程都不存在：`git tag -l v<版本号>`、`gh release view v<版本号>`。

## 3. 跑测试

项目用 Swift Testing，XCTest 的 `Executed 0 tests` 是正常的，要看 `Test run with N tests passed`：

```bash
xcodegen generate --quiet
xcodebuild -project Immerse.xcodeproj -scheme Immerse \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData test 2>&1 \
  | grep -E "Test run with|✘|error:|TEST (SUCCEEDED|FAILED)" | tail -10
```

必须看到 `✔ Test run with N tests passed` 和 `** TEST SUCCEEDED **`，否则停止。

## 4. 提交并 push

`Immerse/Resources/Info.plist` 由 xcodegen 根据 `project.yml` 生成但也纳入了 git，第 3 步跑过 `xcodegen generate` 后它的版本号会同步变化，要和 `project.yml` 一起提交：

```bash
git add project.yml Immerse/Resources/Info.plist
git commit -m "chore(release): bump version to <版本号>"
git push
```

## 5. 打包 DMG

```bash
scripts/package-dmg.sh
```

输出 `dist/Immerse-<版本号>.dmg`，最后一行应为 `x86_64 arm64`（通用包）。

## 6. 验证 DMG

```bash
DMG=dist/Immerse-<版本号>.dmg
hdiutil verify "$DMG" 2>&1 | tail -1                  # 应为 VALID
MNT=$(mktemp -d)
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
ls "$MNT"                                              # 应有 Immerse.app 和 Applications
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$MNT/Immerse.app/Contents/Info.plist"
"$MNT/Immerse.app/Contents/MacOS/Immerse" >/dev/null 2>&1 & PID=$!
sleep 4; ps -p $PID >/dev/null && echo "✅ launched" || echo "❌ exited"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
hdiutil detach "$MNT" >/dev/null
```

版本号要和新版本一致，App 要能启动。

## 7. 打 tag 并发布 Release

```bash
git tag v<版本号> && git push origin v<版本号>
```

Release 说明写到临时文件，格式见 [release-notes-template.md](release-notes-template.md)：

- 「更新内容」根据上个 tag 到现在的提交整理，写**面向用户的中文**，按 ✨ 新功能 / 🐛 修复 / 💄 体验优化 分组；`docs` / `build` / `chore` / `test` 这类对用户无感的提交不写。
- 「安装」一节原样保留模板内容，只替换版本号。

```bash
gh release create v<版本号> dist/Immerse-<版本号>.dmg \
  --title "Immerse <版本号>" --notes-file <说明文件>
gh release view v<版本号> --json assets,isDraft --jq '{draft:.isDraft, assets:[.assets[]|{name,size}]}'
```

## 8. 汇报

用表格汇报：版本号、包含的提交、测试结果、DMG 大小和架构、Release 链接、DMG 直链。

## 注意

- App 只做了 ad-hoc 签名、没有公证。以后有了 Developer ID 证书，要在 `scripts/package-dmg.sh` 里加签名和公证，同时更新模板和 README 里的「首次打开」说明。
- 不要 force push，不要删除或覆盖已发布的 tag / Release；发错了先问用户。
