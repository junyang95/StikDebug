# 本机 WLOC 连接测试 第一阶段

2026-09-09：代码已完成，17 项自动测试通过；今日重新确认 Debug 无签名编译通过，并用用户提供的 P12、描述文件和 zsign 成功安装到 iOS 26.6.1 真机。首次启动被锁屏拒绝，等待解锁。出网、系统地图触发、后台与旧功能回归尚未执行。本记录不代表本机 WLOC 方案已经在真机成立。

用户此前在 iOS 26 使用 Shadowrocket 与 cyberhandyman 模块取得金盆，是既有成功基线，不是本轮验证结果。本轮仅替换连接层，不重复验证游戏效果，不修改坐标。

配套 [System Design 文档](wloc-probe-stage1-system-design.docx) 保留指定模板的页面设置、样式、表格、编号与页眉页脚结构；六页已逐页渲染检查。架构图源文件为 [SVG](wloc-probe-stage1.svg)。

Word 文档为 2026-09-08 的设计快照；本页追加的 2026-09-09 安装实测记录尚未同步到 Word。

## 实现边界

- Debug 入口：设置 → 实验功能 → 本机 WLOC 连接测试。Release 不展示此入口，实验默认关闭。
- 复用 PikminTunnel，新增临时启动选项 `Mode = wlocProbe`；不带此选项时仍为 `developerLoopback`。
- 原有 10.7.0.0/24 回环路由、默认路由排除与包改写保留；不添加默认接管路由、不修改 DNS。
- `NEProxySettings` 只配置 HTTPS 代理及目标域名。`NWListener` 只绑定 `127.0.0.1` 的动态端口；上游为直接 TCP 443，不使用远程代理服务器。
- 只允许下列精确 CONNECT 目标，不允许任意 IP、后缀域名、用户信息或其他端口：

  - `gs-loc.apple.com:443`
  - `gs-loc-cn.apple.com:443`
  - `bluedot.is.autonavi.com:443`
  - `bluedot.is.autonavi.com.gds.alibabadns.com:443`

- Network 框架双向原样转发 TLS 字节，未终止 TLS，不参与 HTTP/2 协商。每方向每次最多 32 KiB，写入完成后才继续读取；最多 8 个连接；CONNECT 请求头上限 16 KiB；握手/上游连接等待 10 秒；透传空闲 120 秒后关闭单条连接，监听器继续运行。
- 本轮没有证书、MITM、HTTP 正文读取、坐标存储、WLOC 改写、Worker、快捷指令或第三方页面。

## 组件与状态

| 组件 | 职责 |
| --- | --- |
| `WLOCProbeCore` | 精确目标校验、CONNECT 解析、TCP 透传、统计协议及开发命令互斥 |
| `PacketTunnelProvider` | 保留回环，按模式设置域名代理，串行处理生命周期，处理状态 IPC |
| `EmbeddedVPNService` | 串行启停、恢复进入前的连接意图、读取真实扩展状态、HTTPS 自测 |
| `WLOCProbeView` | 原生 Form、开始/停止、自测、清空记录、必要元数据和限制说明 |

App 通过 `NETunnelProviderSession.sendProviderMessage` 发送 JSON 字符串 `"status"` 或 `"reset"`。返回 `ProbeSnapshot`：实际模式、会话 UUID、监听状态、端口、活动连接数、各域名连接次数与双向字节数、最近活动时间、最近错误和统计起点。IPC 等待上限 3 秒。

统计只在扩展内存中存在，不持久化流量正文、HTTP 请求头或凭据；它也不能证明请求来自哪个进程。`reset` 会先关闭旧连接再清零，以免旧连接后续的数据被当作新观测。App 丢弃跨启停周期及早于最近清零的迟到状态。

## 与旧模拟功能隔离

启用前检查定点、行走/摇杆/路线、本机配对状态与执行中的开发命令。新版本发起过模拟命令后，须成功执行“恢复真实定位”才能进入实验；设置失败也保守视为可能仍需恢复。旧版本或其他 App 的模拟状态无法由该标记追溯，仍须用户确认已恢复。

UI 与底层 FFI 同时设防，已排队的模拟命令也会被拒绝。自动预检暂停进入开发连接的后续阶段；进入实验前等待已运行的预检退出。实验不要求 pairing file，但原有模拟功能的恢复操作仍按原要求执行。

进入前保存普通 VPN 的连接意图和按需连接设置，实验关闭按需重连。停止时关闭实验连接、取消自测、停止扩展以移除临时代理设置，再按原意图恢复普通回环；不会恢复旧模拟坐标。回滚失败保留互斥标记，用户需重试停止。前台和 App 重启后读取扩展实际模式，不能将实验连接显示为正常开发连接。

## 可重复的自动验证

在 StikDebug 仓库运行：

```sh
swift test --scratch-path /private/tmp/StikDebugWLOCProbeTests

xcodebuild -project StikDebug.xcodeproj -scheme StikDebug \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/StikDebugWLOCProbeBuild \
  CODE_SIGNING_ALLOWED=NO build-for-testing -quiet
```

本轮环境：Xcode 16.2 / iPhoneOS SDK 18.2。Swift package 无第三方依赖，在 Mac 上运行，网络测试只使用回环 TCP。原有 idevice 静态库仅带设备切片，不能据此声称完成 iPhone 模拟器或真机测试。

| 检查 | 本轮结果 |
| --- | --- |
| CONNECT 所有分片边界、完整/未完成超大头部、非法目标及歧义请求 | 5 项解析/协议测试通过 |
| 执行中操作互斥、阻止已排队命令、显式恢复及失败恢复 | 4 项互斥测试通过 |
| 256 KiB 二进制原样回显、非法目标无上游、超时、提前断开、清空、停止、上游失败、半关闭 | 8 项本机 TCP 集成测试通过 |
| iPhone 目标 App、PikminTunnel 与测试目标编译 | 通过，无签名；不等于测试已在设备执行 |
| `git diff --check` 与 Xcode 工程 plist 校验 | 通过 |
| App 原生界面真机视觉检查 | 待验证 |
| iOS 26 自测、外部应用触发、后台 5 分钟、停止与旧模拟回归 | 待验证，设备已连接并安装，首次启动受锁屏阻挡 |

编译仍有原有静态库警告：`libpairable_host.a` 的对象文件面向 iOS 18.0，工程最低链接目标为 iOS 17.4。本轮未调整无关部署版本，也未声称覆盖 iOS 17.4 运行兼容性。

## 2026-09-09 安装实测

- 设备：用户连接的 iPhone 16 Pro Max；iOS 26.6.1（23G83），开发者模式已开启。
- 构建源码：`a6ae64d`，配套设计记录提交 `a6fd5c8`；Debug `build` 再次通过，未启用 Xcode 签名。
- 使用用户提供的 zsign v1.0.4、P12 与同目录 mobileprovision；未添加新证书到钥匙串，未生成 CA。
- 独立打包副本的 Bundle ID 改为 `app.eclipse296.lake3160`，两个扩展随之更新并保留；源码工程标识保持不变。签名细节与固定 App ID 的实测边界见 [签名记录](signing.md)。
- 10:36（Asia/Shanghai）：`devicectl` 确认安装成功，更新目标 Bundle ID 的已有 StikDebug；没有卸载或修改另外两份 StikDebug。
- 10:37：启动请求返回 `Locked`，需用户解锁。尚不能确认 App 启动、扩展加载、自测和其他真机验证结果。
- Mac 严格签名校验与设备安装结果存在差异：前者返回 invalid signature，后者成功。此项仍需保留为签名工具兼容性限制，不写成全部校验通过。
- 没有自动开启实验或其他 VPN，没有变更坐标，也没有替换旧定点功能。

## iOS 26 真机步骤

1. 连接并解锁设备，安装具备 Network Extension 权限的 Debug 签名版本。确认旧模拟已恢复，关闭 Shadowrocket 和其他 VPN。
2. 打开实验页面并开始测试。首次运行可能需要在系统弹窗允许 VPN 配置。记录实际模式、监听地址与 VPN 状态。
3. 运行 App 内 HTTPS 自测。它先清空旧连接，再用临时 URLSession 发起 `HEAD https://gs-loc.apple.com/`，不覆盖系统代理、不跟随重定向、不绕过服务器证书校验。
4. HTTPS 收到响应、URLSession 的代理标记和扩展双向数据均被观察到，才作为该次自测证据。HTTP 非 2xx 不单独判失败；仅能证明传输观测，不能证明定位成功。
5. 点“清空记录并开始观察”，打开系统地图触发定位，再返回记录各域名新增连接和双向字节。禁止将这一步计数等同于确认 `/clls/wloc`。
6. 保持测试运行，将 StikDebug 置于后台至少 5 分钟，然后在其他 App 触发请求，再回来检查。需要证明后台仍能处理新连接，而非只看到旧计数。
7. 停止测试，确认普通网络正常，回环按进入前状态恢复；依次验证原定点、恢复真实定位、摇杆、路线。另测进入前 VPN 为断开、启动中取消、反复启停与 App 重启恢复。

建议每次记录：iOS/设备版本、Wi-Fi 或蜂窝、进入前 VPN 状态、自测 HTTP 状态、清零时间、目标域名计数与双向字节、离开/返回时间、停止后的回环及旧模拟结果。只保留必要元数据，不录制或导出流量正文。

没有新增连接时，分别排查定位缓存、未触发请求和系统代理未生效。无法直接出网、后台无法处理新连接或影响普通网络时，停止本阶段排查；不自动扩大为全局代理，不添加远程服务器。

## 后续门槛与参考

第一阶段真机通过后再独立讨论 CA/解密；单点 WLOC 改写与正式定点接入均未实现。即使真机实验成立，也不能推出正式分发或长期兼容结论。

- [Apple TN3120](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers)：网络扩展内托管代理服务器不属于支持用途。
- [cyberhandyman 模块](https://cyberhandyman-ioslocspo.cyberhandyman.workers.dev/ios-location-spoofer.sgmodule)：本阶段四个目标域名的对照来源，未执行其脚本或设置接口。
- [Apple 证书信任说明](https://support.apple.com/en-us/102390)：仅供后续证书阶段参考，本阶段不安装 CA。
