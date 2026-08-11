# Pikmin Helper 开发计划

## 项目目标

基于 StikDebug 重构 iPhone/iPad 通用的 Pikmin 行走辅助 App。

- 名称：Pikmin Helper
- 最低系统：iOS/iPadOS 17.4
- 界面：简体中文、原创植物风
- 首版内置基于 LocalDevVPN / StosVPN 的本地 Packet Tunnel Extension
- 核心：摇杆巡航、路线行走、定点模拟、目标会话、HealthKit 步数同步
- 删除 JIT、JS、进程、应用管理、证书管理和 Widget 等无关功能
- 不实现游戏内点击、喂食或蘑菇自动化

GPS spoofing 违反 Pikmin Bloom 官方政策，存在账号处罚风险。

## 核心功能

### 行走会话引擎

新增应用级 `WalkingSessionController`，切换到 Pikmin 或离开移动页面后仍能继续。

- `MovementMode`：摇杆、路线、定点
- `SessionGoal`：步数、距离、时长、手动停止
- `WalkingSessionConfig`：速度、步幅、目标、起点和模式
- `WalkingSessionState`：准备、运行、暂停、完成、失败
- `LocationSimulationClient`：封装定位 FFI
- `SessionRecord`：保存距离、步数、时间和终止原因

默认速度 8 km/h、步幅 0.75 米，每秒发送一次坐标。模拟坐标叠加连续、低通处理的 2–3 米 GPS 漂移，漂移不计入距离或步数。达到目标后停止移动和步数写入，但保持终点坐标，用户手动恢复真实定位。

### 移动模式

- 摇杆支持航向控制和锁定巡航，切换 App 后沿最后航向后台移动。
- 自动路线使用 MapKit 步行路线和会话速度。
- 路线终点未达目标时沿原路反向，持续往返至达标。
- 保留 GPX、KML、JSON、文本路线导入。
- 定点支持地图选点、搜索、书签和 `pikminhelper://` 深链；定点不生成步数。

### HealthKit

- 请求读取和写入步数权限。
- 步数按“有效移动距离 ÷ 用户步幅”计算。
- 每 30 秒写入一个 `HKQuantitySample`，结束时补写余量。
- 样本记录会话 UUID、时间段和 App 来源，并支持删除。
- 用户拒绝权限或写入失败时，GPS 会话继续，只展示估算步数。
- 今日页区分健康总步数、设备真实步数和本 App 写入步数。

## 用户权限清单

今日页 Dashboard 和设置页新增独立的系统权限清单，和运行环境清单分开展示：

1. VPN 配置权限：检查本 App 的 `NETunnelProviderManager` 配置是否已由用户保存并启用；是否实际连通仍由运行环境清单中的 VPN 路由检查负责。
2. Health 健康步数权限：检查步数写入权限。iOS 出于隐私原因不提供可靠 API 直接读取 HealthKit 读权限状态，因此读权限失败会通过步数刷新或查询错误暴露，写入权限作为硬门槛。
3. 网络连通性：检查当前网络路径是否可用，并标注 Wi‑Fi、蜂窝或其他网络。普通 Wi‑Fi/蜂窝访问不是用户授权项；只有使用 Bonjour/局域网发现等能力时才会触发“本地网络”授权。
4. 位置始终允许：检查 `authorizedAlways`。`authorizedWhenInUse` 只作为警告，因为后台行走保活需要始终允许。

权限清单每一行均可点击：VPN 和 HealthKit 直接触发对应系统授权流程；位置在系统仍允许弹窗时调用 `requestAlwaysAuthorization()`，已拒绝时引导用户打开系统设置；网络项不伪造系统权限弹窗，只说明 iOS 限制并提供 App 设置入口。

设置页采用“缺什么给什么动作”的模型：未满足的权限项下方直接显示最短路径按钮，例如请求 VPN 配置、请求 HealthKit 步数、打开无线数据设置、请求位置始终允许。

## 环境检查清单

新增 `EnvironmentPreflightService`，统一维护 `unknown`、`checking`、`ready`、`warning`、`failed` 状态。检查入口位于首次配置向导、今日页状态卡、移动页会话启动前和设置诊断页。

1. 使用 `NWPathMonitor` 判断底层网络是否包含 Wi-Fi；若实际隧道可用则 Wi-Fi 仅警告。
2. 使用 `NETunnelProviderManager` 管理内置 VPN，并通过 `NWConnection` 探测 `10.7.0.1:49152`，确认实际路由可用。
3. 检查 pairing file 是否存在、能否被 `rp_pairing_file_read` 解析并完成 Remote Pairing 握手。
4. 调用 `tunnel_create_rppairing`；同时获得 adapter 和 handshake 才视为 CoreDevice 隧道已连接。
5. 检查 DDI 三个本地文件，并通过 `getMountedDeviceCount()` 确认设备端真实挂载状态。

配对、VPN 路由、CoreDevice 隧道和 DDI 均正常后才能开始移动。会话期间隧道断开时暂停坐标和步数推进，重连成功后再继续。

设置页运行环境清单同样按异常项显示动作：

- Wi‑Fi 未连接时提供“打开 Wi‑Fi 设置”。
- 内置 VPN 路由只在 Wi‑Fi 已连接后显示“连接内置 VPN”；Wi‑Fi 未完成时显示等待前置条件。
- pairing file 缺失时显示电脑端 idevice_pair 最短步骤，并提供 Mac / Windows 下载链接、分享和复制链接入口。
- pairing file 导入后通过通知和 2 秒轻量轮询自动刷新 UI；idevice_pair 通过 Documents 写入 `pairingFile.plist` 时，App 会自动迁移并更新清单状态。
- Documents 中同时出现新旧文件名时，按修改时间选择最新且可解析的候选文件；候选文件先复制到受保护目录中的临时文件，经 `rp_pairing_file_read` 验证后再原子替换。无效或写入不完整的新文件不会破坏现有可用 pairing file，成功导入后会清理 Documents 中的文件共享副本。
- DDI 文件缺失时提供“下载/重新下载 DDI 文件”；不再只依赖 App 启动时自动下载缺失文件。
- CoreDevice/RSD 通道只在 Wi‑Fi、VPN 路由、pairing file 和 DDI 文件都满足后显示建立按钮。
- DDI 文件已准备但未挂载时，等待 CoreDevice/RSD 通道；通道建立后显示挂载动作。

### idevice_pair 兼容

- 不修改 idevice_pair；兼容其现有 `CFBundleDisplayName == StikDebug` 识别规则。
- App 的 `CFBundleDisplayName` 使用 `StikDebug`，以匹配 idevice_pair 的硬编码识别规则；因此桌面图标名也显示 `StikDebug`，App 内品牌仍为 `Pikmin Helper`。
- 启用 `UIFileSharingEnabled`，允许 House Arrest 写入 `/Documents/pairingFile.plist`。
- App 检测并迁移该文件到受保护的 Application Support 目录；新导入文件覆盖旧文件。

## 界面和数据

使用“今日、移动、历史、设置”四个 Tab。使用本地 SwiftData 保存会话、路线和书签；首版不启用 iCloud。

## Bundle ID、Entitlements 与重签名

- Xcode 本地开发使用已启用 HealthKit 的 `com.jy.stikdebug.pikmin`（Team `W8UCWPZS66`）。
- 业务代码不得硬编码 Bundle ID、Team ID 或 `application-identifier`。
- 最终 Bundle ID 由实际 `.mobileprovision` 决定。
- 若 profile 的 App ID 为 `ZTP5S4Z93Y.app.pineapple3119.elephant7948`，最终 Bundle ID 必须改为 `app.pineapple3119.elephant7948`。
- 只使用 profile 已授权且 App 实际需要的 entitlement，不直接照抄整份列表。
- HealthKit 必须同时存在于 profile 和最终可执行文件签名中。
- P12 必须属于 profile 的授权证书集合。

重签脚本自动解析 profile、验证 P12、提取 Bundle ID、生成最小 entitlements、调用 zsign，并检查 `CFBundleIdentifier`、`application-identifier`、`team-identifier`、Keychain Group、HealthKit 和 embedded profile。

更换 Team ID 或 Bundle ID 后视为全新安装，不迁移原本地数据。

## 真机开发与测试

1. 使用 `xcrun devicectl list devices` 和 `xcodebuild -showdestinations` 确认真机。
2. 通过 `xcodebuild` 构建 Debug 真机包。
3. 使用 `xcrun devicectl device install app` 安装。
4. 使用 `xcrun devicectl device process launch` 启动。
5. 收集设备日志、崩溃信息和真机截图。
6. HealthKit、后台运行、VPN、DDI 和定位以真机结果为准。

验收覆盖坐标速度、漂移连续性、步幅换算、路线往返、后台巡航、环境检查、网络中断、隧道重连、DDI、HealthKit 和重签安装。

### 当前验证状态（2026-07-06）

- Xcode Accounts 中的开发账号可正常使用；最初的签名失败是项目仍绑定旧 Team，而非账号不可用。
- 项目默认配置已切换为 Team `W8UCWPZS66`、Bundle ID `com.jy.stikdebug.pikmin`。
- 无额外命令行覆盖参数的 Debug 真机构建、安装和启动均已通过。
- 最终 App 签名仅携带 `application-identifier`、Team ID、HealthKit 和调试权限；profile 中其他未使用权限不会被无条件复制到 App。
- 已在 iPhone 16 Pro Max（iOS 26.5）验证首屏、HealthKit 步数读取和环境清单渲染。
- Mac 侧配对、CoreDevice 通道和 DDI 开发服务已能支持安装、启动和截图；App 内仍需单独导入 pairing file 才能建立定位模拟链路。
- 真机测试 target 暂时无法自动创建 xctrunner profile，因为 Apple Developer Program License Agreement 待账号持有人接受；App 本体构建不受影响。

## 内置 VPN

- Packet Tunnel Extension Bundle ID 为 `com.jy.stikdebug.pikmin.networkextension`。
- 主 App 与 Extension 分别使用各自 provisioning profile 签名。
- 首次连接由 iOS 展示系统 VPN 配置授权；之后可在 App 内连接或断开。
- 隧道只提供 `10.7.0.1` 到设备本地接口的映射，不把流量发送到外部服务器。
- 实现基于 LocalDevVPN / StosVPN，按上游许可证在设置页和 `THIRD_PARTY_NOTICES.md` 保留显著归属。
- zsign 重签必须按“Extension 在内、主 App 在外”的顺序使用两份匹配 profile；只替换主 App profile 不足以保留内置 VPN。
