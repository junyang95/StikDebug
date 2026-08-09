# Pikmin Helper 重签名

当前开发构建使用以下两个显式 App ID：

- 主 App：`com.jy.stikdebug.pikmin`
- Packet Tunnel Extension：`com.jy.stikdebug.pikmin.networkextension`

最终签名必须同时提供主 App 和 Extension 的 provisioning profile。两个
profile 必须属于同一 Team，且 Extension profile 必须授权
`packet-tunnel-provider`。只重签主 App 会导致内置 VPN 无法加载或安装失败。

```bash
P12_PASSWORD='your-password' ./scripts/resign-ipa.sh \
  PikminHelper.ipa \
  signing.p12 \
  app.mobileprovision \
  PikminHelper-signed.ipa
```

当前脚本是主 App 单 profile 验证工具；包含 Packet Tunnel Extension 的正式
IPA 不能只使用这个命令完成最终重签。后续 zsign 流程必须先使用 Extension
profile 重签 `PlugIns/PikminTunnel.appex`，再使用主 profile 重签外层 App，且
Extension Bundle ID 应与最终主 Bundle ID 保持约定的 `.networkextension`
后缀。当前机器尚未安装 `zsign`，因此该双 profile 流程尚未实测。

不要提交 P12、密码、provisioning profile 或生成后的签名 IPA。
