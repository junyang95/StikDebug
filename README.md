# Pikmin Helper

Pikmin Helper 是基于 StikDebug 定位底层重构的内部学习项目，面向 iOS/iPadOS 17.4 及以上系统。

## 当前功能

- 地图定点与步行路线模拟
- 可锁定方向、切换 App 后继续运行的虚拟摇杆
- 步数、距离或时长目标
- 2–3 米连续 GPS 漂移
- HealthKit 步数读取、写入和来源统计
- LocalDevVPN、pairing file、CoreDevice 隧道和 DDI 检查清单
- SwiftData 行走历史

## 开发环境

- macOS 与 Xcode 16+
- 连接并信任的 iPhone 或 iPad
- 内置 LocalDevVPN / StosVPN Packet Tunnel Extension
- 对应设备的 pairing file

可直接使用未修改的 idevice_pair：它会把本 App 识别为 `StikDebug`，并通过
House Arrest 写入 `Documents/pairingFile.plist`。App 激活后会自动迁移并验证
该文件。
- 支持 HealthKit 的开发 provisioning profile

工程当前开发 Bundle ID 为 `com.jy.stikdebug.pikmin`。最终重签 Bundle ID 必须与实际 provisioning profile 匹配，参见 [重签名说明](docs/signing.md)。

## 构建

```bash
xcodebuild \
  -project StikDebug.xcodeproj \
  -scheme StikDebug \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  build
```

## 风险

GPS spoofing 违反 Pikmin Bloom 服务政策，可能导致账号受限或永久封禁。本项目不保证游戏接受第三方 HealthKit 步数来源，仅供内部学习。

## License

本项目继承原项目的 AGPL-3.0 许可证，详见 [LICENSE](LICENSE)。
