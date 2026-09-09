# StikDebug 重签名

当前开发构建使用以下 Bundle ID：

- 主 App：`com.jy.stikdebug.pikmin`
- Packet Tunnel Extension：`com.jy.stikdebug.pikmin.networkextension`
- Live Activity Extension：`com.jy.stikdebug.pikmin.liveactivity`

Xcode 开发签名使用分别匹配的主 App、Packet Tunnel 和 Live Activity
profile；Packet Tunnel 需要 `packet-tunnel-provider`。重签必须覆盖全部
嵌入扩展，而不只是主 App。不能仅凭 profile 使用固定 App ID 就断言
zsign 安装必然失败：下面记录了本机实际通过的单 profile 安装实验。

```bash
P12_PASSWORD='your-password' ./scripts/resign-ipa.sh \
  PikminHelper.ipa \
  signing.p12 \
  app.mobileprovision \
  PikminHelper-signed.ipa
```

当前脚本是主 App 单 profile 验证工具；包含 Packet Tunnel Extension 的正式
IPA 不能使用这个保守脚本完成单 profile 重签。此脚本的主动拒绝是工具
限制，不是本机安装一定失败的证据。Extension Bundle ID 应与最终主
Bundle ID 保持约定的 `.networkextension` 后缀；App 运行时从主 Bundle ID
推导 VPN 扩展标识。Live Activity 也应保留并同步更新标识。

## 2026-09-09：用户提供的 zsign 单 profile 实验

- 使用 workspace 中用户提供的 zsign v1.0.4、P12 和 mobileprovision，未使用
  Mac 原有 Xcode 签名身份。证书与 profile 匹配，profile 包含目标 iPhone，
  并授权 `packet-tunnel-provider`。
- 在未签名 Debug 构建的独立副本上操作；打包排除旧的 `.xctest`、`.dSYM`
  和旧签名，保留两个 `.appex`，将所提供 profile 复制到各扩展后统一重签。
- 使用 `-b app.eclipse296.lake3160 -n StikDebug`；zsign 同步将扩展 Bundle ID
  改为 `.networkextension` 与 `.liveactivity` 后缀。未修改源码工程 Bundle ID。
- `-e` 只传入签名身份、调试、应用自身 keychain、HealthKit 与 Packet Tunnel
  所需的权限集合，未把 profile 中无关的 App Groups、推送等全部带入。
- 实际签名中，主 App 与两个扩展的 `application-identifier` 均保持 profile
  的固定值 `336W4P3WL5.app.eclipse296.lake3160`，而三个 Bundle ID 不同。
  不要把这两个字段混为一谈，也不要据此推导任意 App ID／系统版本均可用。
- `zsign` 签名和打包成功；`devicectl device install app` 在 iOS 26.6.1 的
  目标 iPhone 上返回成功，更新的是已有 `app.eclipse296.lake3160`，没有卸载
  App，也没有改动其他 Bundle ID 的 StikDebug。
- Mac 的 `codesign --verify --deep --strict` 仍返回 invalid signature；正常
  系统权限下可以读取签名 entitlements。保留这个校验差异，不能称为完整
  签名校验通过。iPhone 接受安装是已确认事实；运行和 VPN 扩展启动需另测。
- 首次启动请求被锁屏拒绝（`Locked`），不是安装失败；待用户解锁后继续。

本次签名链未包含 HTTPS 解密 CA，也没有开启 VPN 或 WLOC 改写。
网络和后续真机状态见 [第一阶段验证记录](wloc-probe-stage1.md)。

不要提交 P12、密码、provisioning profile 或生成后的签名 IPA。
