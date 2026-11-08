# StikDebug

StikDebug 是基于 StikDebug 定位底层重构的内部学习项目，面向 iOS/iPadOS 17.4 及以上系统。

当前版本为 **0.1.10 (11)**：无网站验证；受保护操作使用安装包签名凭据，在本地核对实际连接设备。DDI 保持安装包内置。首次设置与发布注意事项见 [精简版说明](docs/simplified-setup-and-bundled-ddi.md)。

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
- 打开 App 先展示可浏览的首页和四个标签页；点击“开始设置”后直接进入设备设置，继续配对、VPN 与系统权限步骤，不检查网站注册或 VIP 资格。
- 首次定位及开发操作在实际使用的 RSD 隧道上读取设备标识，与安装包内已验签的 `wowdevice.plist` 本地比对；缺少、损坏或设备不匹配时拒绝操作，不请求网站。恢复真实定位、停止和清理始终保留。
- 安装包内置 Personalized / Cryptex 两套 DDI，共 8 个文件。DDI 安装从内置资源复制并核对大小和 SHA-256，不访问七牛或 GitHub；系统个性化挂载仍可能连接 Apple 服务。DDI 维持可选入口，不成为路线或摇杆的新增前置条件。
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

## 历史版本记录

坐标校正、停止后保持位置及旧版原生 VIP 校验记录见 [修复说明](docs/buyer-fixes-2026-09.md)。下列旧版授权及联网下载说明不适用于 0.1.9 及以上版本；0.1.10 的本地设备绑定见当前精简版说明。

0.1.6 (7) 的蜂窝网络重试、离线授权边界及 DDI 安装入口见 [说明与复测步骤](docs/cellular-authorization-and-ddi-2026-10.md)。

0.1.7 (8) 支持 Personalized / Cryptex 两套 DDI，均从七牛版本目录下载，见 [资源与验证说明](docs/ddi-cryptex-qiniu-2026-10.md)。
