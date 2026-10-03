# StikDebug

StikDebug 是基于 StikDebug 定位底层重构的内部学习项目，面向 iOS/iPadOS 17.4 及以上系统。

## 当前功能

- 地图定点与步行路线模拟
- 可锁定方向、切换 App 后继续运行的虚拟摇杆
- 步数、距离或时长目标
- 2–3 米连续 GPS 漂移
- HealthKit 步数读取、写入和来源统计
- LocalDevVPN、pairing file、CoreDevice 隧道和 DDI 检查清单
- SwiftData 行走历史
- ActivityKit 锁屏与灵动岛状态
- 收藏、最近位置、路线资料库，GPX 导入/导出与地图手绘

## 隐私与网络边界

- 不包含分析、广告、崩溃上报或遥测 SDK，不建立用户账号。
- pairing file、收藏、最近位置、路线和会话记录仅保存在 App 容器中。
- 地点搜索与步道/道路规划使用系统 MapKit；使用这些功能时，搜索文字或路线端点由 Apple 地图服务处理。
- 内置 VPN 只建立到本机/已配对设备的本地通道，不连接外部 VPN 服务器。
- Debug 的 WLOC 透传实验可让四个限定定位域名经本机代理直接出网；不解密、不改坐标，与旧模拟互斥，详见 [第一阶段验证记录](docs/wloc-probe-stage1.md)。
- VIP 校验会将已配对设备的 UDID 发送到 `wow-app.store`；授权签名与设备绑定在主程序内验证，不依赖注入 dylib。
- DDI 是可选开发能力。App 启动时不会自动下载；只有用户确认后才连接 `static.wow-app.store`。
- GPX 与诊断报告仅在用户主动打开系统导出/分享面板后离开 App。

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

完整的无签名构建、测试目标、隐私清单和 Extension 打包验证可运行：

```bash
Tools/verify-pikmin-helper.sh
```

真机版本矩阵与安装步骤见 [docs/device-test-matrix.md](docs/device-test-matrix.md)。

## 风险

GPS spoofing 违反 Pikmin Bloom 服务政策，可能导致账号受限或永久封禁。本项目不保证游戏接受第三方 HealthKit 步数来源，仅供内部学习。

## License

本项目继承原项目的 AGPL-3.0 许可证，详见 [LICENSE](LICENSE)。

## 本次买家反馈修复

坐标校正、停止后保持位置及原生 VIP 校验的行为与发布顺序见 [修复说明](docs/buyer-fixes-2026-09.md)。

0.1.6 (7) 的蜂窝网络重试、离线授权边界及 DDI 安装入口见 [说明与复测步骤](docs/cellular-authorization-and-ddi-2026-10.md)。

0.1.7 (8) 支持 Personalized / Cryptex 两套 DDI，均从七牛版本目录下载，见 [资源与验证说明](docs/ddi-cryptex-qiniu-2026-10.md)。
