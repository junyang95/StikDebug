# 七牛 Personalized / Cryptex DDI — 0.1.7 (8)

## 变化

`codex/pikmin-helper` 保留原有定位、路线、步数、内置 VPN 和配对功能。此次补齐两套 DDI 的下载、挂载与状态检查：

| 系统 | 使用的资源目录 | 文件数 |
| --- | --- | --- |
| iOS 17.4–26.3 | `Xcode_iOS_DDI_Personalized` | 3 |
| iOS 26.4 及以上 | `Xcode_iOS_DDI_Cryptex` | 5 |

App 同时支持两套资源，按当前系统下载其中一套。两者均使用七牛 HTTPS 地址，无 GitHub 下载回退。Cryptex 除清单、镜像和 trustcache 外，还需 `Image.dmg.cryptex_info` 与 `Image.dmg.root_hash`。

统一资源前缀：

```text
https://static.wow-app.store/Xcode_iOS_DDI_Personalized/releases/6eae353ae694bda1c421d4a3eee5459ae59c99a1
```

前缀后连接资源目录和文件名。每个文件的固定大小及 SHA-256 记录在 `StikDebug/Core/DDIAssetSet.swift`，下载和使用前均验证完整性。底层 `idevice.h` 和 `libidevice_ffi.a` 来自官方 StikDebug 提交 `4bdfc92aa7cebd7a534f1e1ef56415f5727402de`，保留 Pikmin 本机配对 shim 声明及独立静态库。

## 缓存与安装

- 旧版无版本标记的缓存会重新下载。系统从 Personalized 切换到 Cryptex 时，也会更新整套文件。
- 新文件暂存于按资源版本、类型区分的目录。所有文件校验成功后，整体替换 `Documents/DDI`，写入 `.asset-set` 标记并移除旧类型的附加文件。
- 失败或取消保留现有完整缓存；再次尝试会复用暂存区已校验通过的完整文件。点击重新下载会清空当前版本的暂存区。
- 自动挂载、安装引导、环境检查与诊断报告使用同一套文件要求，避免仅凭一个 trustcache 文件判断就绪。
- 自动挂载的网络操作在后台线程执行，并在完成后确认设备端状态。DDI 操作单独持有隧道，避免环境刷新重建共享隧道时释放挂载正在使用的句柄。
- 新增错误提示包含简体中文、繁体中文及英文。DDI 仍为可选功能，不会用于阻止定位模拟。

## 验证与真机复测

- 全量下载七牛目录内 8 个文件，大小和 SHA-256 与代码记录一致。
- `Tools/test-pikmin-runtime.sh`：87 项测试通过。新增测试覆盖系统版本分界、8 个 URL、缺失/截断/同长度篡改、旧缓存迁移、两种类型来回切换、失败/取消保留、重试复用、强制下载及并发拒绝。
- iPhone Release archive 编译、链接成功。主 App 和两个扩展统一为 0.1.7 (8)；ZIP 完整性、arm64 架构及全部可执行文件未签名状态均检查通过。包内确认包含七牛版本路径、Cryptex 文件名及新增三种语言提示。
- 仍存在旧有的链接警告：`libpairable_host.a` 的一个对象文件按 iOS 18.0 构建，而 App 声明最低 iOS 17.4。本次没有修改该配对库，不能仅凭编译通过确认 iOS 17.4 真机兼容性。

尚未完成真机挂载验证。重签后分别在 iOS 26.3 或更早版本、iOS 26.4 或更高版本上打开 DDI 安装页，确认下载数量为 3 / 5、挂载成功后环境检查显示已挂载。还需验证从旧版升级、下载中断后重试、重启手机后重新挂载，以及原有本机配对功能。

## 发布记录

- 未签名 Release 包：`artifacts/PikminHelper-0.1.7-8-unsigned.ipa`，12,314,358 字节。
- SHA-256：`bd7590c3de58ec461e62249990057f64daa8bc4a83081d6f637bc371f83b4ca3`。
- 编译、资源和测试记录：[验证报告](../artifacts/PikminHelper-0.1.7-8-verification.json)。IPA 按仓库规则保留在本地产物目录，不提交到 Git。
