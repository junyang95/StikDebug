# 七牛 DDI 与简繁中文分支

## 分支用途

- `main`：跟随 `StikDebug/StikDebug` 的官方源码和目录，只保留个人仓库的 GitHub Actions。同步任务仅运行于 `main`，记录上游历史后将工作流目录以外的文件对齐官方。
- `codex/pikmin-helper`：独立的 Pikmin 助手开发分支，保留现有功能，不合并到 `main`。
- `codex/qiniu-ddi-zh`：基于官方 3.1.13（`4bdfc92`），只增加七牛 DDI 资源、简繁中文及对应验证。后续可以从 `main` 同步官方更新，本分支的定制不回流到 `main`。

## DDI 资源

两套文件统一固定到同一个七牛版本，避免不同发布版本的清单和镜像混用：

```text
https://static.wow-app.store/Xcode_iOS_DDI_Personalized/releases/6eae353ae694bda1c421d4a3eee5459ae59c99a1
```

| 系统 | 目录 | 文件 |
| --- | --- | --- |
| iOS 17.4 至 26.3 | `Xcode_iOS_DDI_Personalized` | `BuildManifest.plist`、`Image.dmg`、`Image.dmg.trustcache` |
| iOS 26.4 及以上 | `Xcode_iOS_DDI_Cryptex` | 以上三个文件，加 `Image.dmg.cryptex_info`、`Image.dmg.root_hash` |

保留官方的系统版本选择、下载、挂载方式标记和旧文件清理逻辑。下载服务不再使用 GitHub DDI 地址。

2026-10-03 已检查上述 8 个完整文件地址，均返回 HTTP 200。设备上的 DDI 挂载仍需真机验证。

## 语言

保留英文，新增 `zh-Hans` 和 `zh-Hant`，跟随 iOS 系统语言或系统设置中的 App 语言。

- `Localizable.xcstrings`：页面、按钮、运行时提示、错误和快捷指令参数。
- `InfoPlist.xcstrings`：系统权限说明。
- `AppShortcuts.xcstrings`：Siri 快捷指令短语。

运行日志、设备返回的数据和第三方库错误保留原始内容，便于诊断。

## 验证与构建

```sh
python3 Tools/verify-localizations.py
xcrun xcstringstool compile StikDebug/Localizable.xcstrings --output-directory /tmp/stikdebug-localizations
```

新分支推送时会单独运行 `Build Debug IPA`。构建还会检查 Swift 编译器提取的文案是否都有简繁翻译，并上传 IPA 构建产物。分支推送不会发布 Release。

本机 Xcode 16.2 可做 Swift 语法和字符串目录验证；完整 App 构建使用仓库 GitHub Actions 中配置的 Xcode 26.6。仍需在简体、繁体系统语言下进行真机页面和 Siri 检查。
