# StikDebug WLOC 第二阶段 A：本机证书准备

日期：2026-09-11。承接第一阶段透传验证；本节只交付证书准备，不交付 MITM 或位置改写。

## 已实现的边界

- 设置 → 实验功能 → 本机 WLOC 连接测试 → 第二阶段 · 本机实验证书。
- 普通本机隧道或 WLOC 透传实验连接后，可生成 90 天、随机唯一的 EC P-256 根证书。
- 根密钥通过 Security 创建并永久保存在本机 Keychain，使用
  `AfterFirstUnlockThisDeviceOnly`，不同步；证书也存于 Keychain。
- 证书私钥仅由扩展代码读取/使用，不经 provider IPC、USB、文件共享或网络导出。
  IPC 只传公开 DER、指纹、有效期、信任检查结果和短期本机下载地址。
- 已保存材料会验证签名、P-256 密钥匹配、有效期、CA/pathLen=0、critical key usage。
  缺半边、损坏、过期、保存中断都报错，不自动旋转或覆盖已信任根。
- 主 App 没有链接 X509；证书库只加入 tunnel target，Live Activity 不受影响。
  现有 CONNECT 透传实现、四域名代理范围、DNS 和路由均保持不变。

### 重签的钥匙串限制

目前用户提供的单 profile 签名使主 App 与扩展共用固定的
`keychain-access-groups`。默认组由签名决定，不能把“由扩展代码保管”描述为
“只有扩展进程有权限访问”。其他拥有相同签名访问组的 App 也可能访问该组。
代码的 tag/label 包含扩展 Bundle ID，可避免不同 App 误复用，但不能创造权限隔离。
本次不增加 entitlement，也不承诺正式分发安全性。

## 本机安装与信任检查

1. App 发送 `certificate.prepare`，扩展生成或读取同一份 CA。
2. `certificate.download` 只读公开 CA 并生成可移除的 `.mobileconfig`。
   唯一 payload 为 `com.apple.security.root`；没有 VPN、代理、MDM 或 PKCS#12。
3. 扩展只在 `127.0.0.1` 的系统随机端口提供 HTTP 下载，URL 带随机 UUID 路径。
   主 App 仅接受该 loopback 地址并交给系统浏览器；无需 Worker、远程服务器或网站。
4. 用户自行允许下载、安装描述文件，并到系统设置打开完全信任。
   本 App 不静默安装、不代替用户信任，也不使用 MDM/Configurator 绕过该确认。
5. `certificate.verifyTrust` 签发一个临时 `gs-loc.apple.com` 叶子证书，使用
   `SecPolicyCreateSSL` / `SecTrustEvaluateWithError` 检查证书链。禁网络获取，
   不添加自定义锚、信任例外或忽略验证的回调。

信任结果只是当次默认系统证书链校验结果，**不是 TLS 握手、HTTPS 解密、
`/clls/wloc` 请求识别或定位成功的证明**。进入/返回此页会使旧结果失效，
检查失败也不会保留旧的通过状态。

下载服务限制：绝对存活期 120 秒、最多 2 个连接、4 KiB 请求头、5 秒头/发送超时、
最多 64 KiB 公开 profile、精确 GET 路径及 Host 校验、拒绝正文/分块/重复 Host。
发送回调完成后关闭服务，不将该回调解释为浏览器下载、安装或信任完成。
停止隧道会等待证书服务在自己的串行队列上取消 listener、连接和计时器。

停止隧道不会撤销用户安装的 CA。结束实验应在
“设置 → 通用 → VPN 与设备管理”移除 **StikDebug WLOC 实验证书**；不要移除其他证书。

## Mac 自动诊断

沿用仅 Debug 的配对 USB mailbox，新增两个只读动作：

```bash
python3 -B Tools/wloc-debug.py --bundle-id app.eclipse296.lake3160 \
  certificate-status --device 7E85C01C-59CA-4ACE-85CA-C12E43279E57
python3 -B Tools/wloc-debug.py --bundle-id app.eclipse296.lake3160 \
  certificate-verify --device 7E85C01C-59CA-4ACE-85CA-C12E43279E57
```

仅返回 prepared、SHA-256 指纹、有效期、系统信任布尔值及时间。
不返回 DER、私钥、URL、任意错误字符串。不存在 USB 生成、下载、安装或信任命令。
`result=ok` 表示命令完成，实际信任须看 `certificate.systemTrusted`，不能混为一谈。
原有 TTL、UUID、单设备串行锁、前台执行要求和不盲目重发规则不变。

## 验证记录

最终代码验证：Debug 主机回归 **84/84**，Release **48/48**，Python USB 校验 **24/24**。
Debug / Release iPhone 构建均成功；仍有原有 libpairable_host.a 的 iOS 18/17.4
链接版本警告，未将其掩盖或声称零警告。Release App 不含 `certificateStatus`、
`certificateVerify` 或 USB 日志前缀。完整构建日志保留在 Mac `/private/tmp/`：
`stikdebug-wloc-ca-*-final.log`。

只读 USB 检查发现旧实验 session `59511143-271E-427A-8C6F-C0816A98F60F`
仍在运行；安装前已发送一次 stop，得到 `result=ok`、`experimentEnabled=false`、
`vpnState=connected`，恢复了普通本机隧道。没有自动重启实验。

已覆盖的测试包含：CA 生成与复用、公开数据字段白名单、默认新根不可信、
测试专用锚的正对照、错误 hostname、材料损坏与保存中断不覆盖、profile 唯一公开根、
64 KiB 完整下载、4 KiB 分片请求头、FIN、非法请求、连接上限、超时和停止竞态。
显式信任锚只存在主机测试代码中，不存在产品代码中。

尚需真机验证：实际重签权限下的 Keychain 创建/重启持久化；Safari 本机下载；
用户手动安装与信任；默认系统策略由 false 变 true；关闭信任后再次变 false。
原生 Form 使用语义字体/颜色、可换行指纹、原生导航和无固定底部按钮；
真机页面、小屏/横屏/最大动态字体、VoiceOver 和深色模式的视觉检查尚未完成。

### 119484a 安装记录

- 使用用户原有 P12/profile 和 zsign，未修改源工程的 Bundle ID；没有卸载 App。
- IPA：`wloc-reasearch/artifacts/StikDebug-WLOC-CA-119484a-zsign.ipa`。
  SHA-256：`16839f954782194015e55590023f497b4c7cf53e7f29972c23818d828701ee39`。
- 14:36，`devicectl device install app` 确认成功：目标仅为 iPhone 16 Pro Max
  `7E85C01C-59CA-4ACE-85CA-C12E43279E57`，App 为 `app.eclipse296.lake3160`。
- 签名副本及安装 JSON：`/private/tmp/stikdebug-ca-sign.JLbpJC/`。Mac strict codesign
  与 zsign 的既有差异仍存在；不把设备接受安装等同于完整签名验证。
- 安装后的 USB `certificate-status` 未能完成自动启动；随后直接启动命令也在
  10 秒超时。没有收到证书状态，不能认定 App 启动成功、证书已生成或已受信任，
  也没有足够证据将超时归因为锁屏。已请用户手动打开新版证书页面生成证书，
  暂不下载或信任，随后再以 USB 检查默认不可信状态。

## 依赖与下一节

精确锁定 `swift-certificates 1.18.0`、`swift-crypto 3.12.3`、`swift-asn1 1.3.1`，
兼容本机 Xcode 16.2 / Swift 6.0。版本锁同时进入 SwiftPM 与 Xcode。
Apple 依赖的 LICENSE/NOTICE 原文随 App resource 提供，见 THIRD_PARTY_NOTICES.md。

下一节先验证受控本机 TLS 握手与 SecIdentity，再规划 CONNECT Framer 升级、
真实 WLOC 请求识别及 HTTP/2 兼容；不能在已 ready 的普通 NWConnection 上直接追加 TLS。
仍不修改坐标、不引入全局代理或远程服务器。

参考：[Apple 手动根信任](https://support.apple.com/en-us/102390)、
[Keychain access group](https://developer.apple.com/documentation/security/ksecattraccessgroup)、
[Framer prependApplicationProtocol](https://developer.apple.com/documentation/network/nwprotocolframer/instance/prependapplicationprotocol(options:))、
[TN3120 不支持的网络扩展用途](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)。
网络扩展内托管代理的实验限制仍然有效。
