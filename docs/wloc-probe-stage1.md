# 本机 WLOC 连接测试 第一阶段

2026-09-09：CONNECT Host 格式兼容修正后，18 项自动测试与 Debug 构建通过。用户确认 iPhone HTTPS 自测、Safari 外部 App 对照、后台新请求、普通停止恢复，以及旧定点、摇杆和路线回归均正常。系统地图多次请求当前位置仍未见统计变化；系统定位链路和其他生命周期边界尚未验证完成，不能标记第一阶段全部完成。

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
| CONNECT 所有分片边界、完整/未完成超大头部、非法目标、歧义请求及 CFNetwork Host 格式 | 6 项解析/协议测试通过 |
| 执行中操作互斥、阻止已排队命令、显式恢复及失败恢复 | 4 项互斥测试通过 |
| 256 KiB 二进制原样回显、非法目标无上游、超时、提前断开、清空、停止、上游失败、半关闭 | 8 项本机 TCP 集成测试通过 |
| iPhone 目标 App、PikminTunnel 与测试目标编译 | 通过，无签名；不等于测试已在设备执行 |
| `git diff --check` 与 Xcode 工程 plist 校验 | 通过 |
| App 原生界面真机视觉检查 | 待验证 |
| iOS 26 代理启动与 HTTPS 自测 | 用户确认修正版“已就绪”，自测通过：HTTP 404 且代理双向数据被观察到 |
| 系统地图触发 | 用户报告地图显示当前位置，多次点击定位后未见统计变化；未证明系统定位请求经过代理 |
| Safari 外部 App 对照 | 用户报告打开测试地址 3 次，累计 3 条连接，发送约 6 KB、接收约 10 KB |
| 后台新请求对照 | 用户按后台 5 分钟步骤反馈同样收到数据；没有独立时间戳、截图或完整快照 |
| 普通停止、模式恢复与普通网络 | 用户对指定停止步骤反馈“都正常”；无独立状态快照 |
| 旧定点、摇杆和路线回归 | 用户对逐项启动、停止及恢复真实定位步骤反馈“正常的”；无独立截图或命令记录 |
| 其他生命周期边界 | 启动中取消、其他进入前 VPN 状态、App 重启恢复等尚未完整验证 |

编译仍有原有静态库警告：`libpairable_host.a` 的对象文件面向 iOS 18.0，工程最低链接目标为 iOS 17.4。本轮未调整无关部署版本，也未声称覆盖 iOS 17.4 运行兼容性。

## 2026-09-09 安装实测

- 设备：用户连接的 iPhone 16 Pro Max；iOS 26.6.1（23G83），开发者模式已开启。
- 构建源码：`a6ae64d`，配套设计记录提交 `a6fd5c8`；Debug `build` 再次通过，未启用 Xcode 签名。
- 使用用户提供的 zsign v1.0.4、P12 与同目录 mobileprovision；未添加新证书到钥匙串，未生成 CA。
- 独立打包副本的 Bundle ID 改为 `app.eclipse296.lake3160`，两个扩展随之更新并保留；源码工程标识保持不变。签名细节与固定 App ID 的实测边界见 [签名记录](signing.md)。
- 10:36（Asia/Shanghai）：`devicectl` 确认安装成功，更新目标 Bundle ID 的已有 StikDebug；没有卸载或修改另外两份 StikDebug。
- 10:37：首次启动请求返回 `Locked`。10:39 用户解锁后，再次启动返回成功，目标 Bundle ID 为 `app.eclipse296.lake3160`。扩展加载、自测和其他真机验证仍待执行。
- Mac 严格签名校验与设备安装结果存在差异：前者返回 invalid signature，后者成功。此项仍需保留为签名工具兼容性限制，不写成全部校验通过。
- 没有自动开启实验或其他 VPN，没有变更坐标，也没有替换旧定点功能。

## 2026-09-09：CONNECT 格式兼容修正

用户报告代理已就绪，但自测显示“网络连接已中断”。原版尚未取得手机连接数、
收发字节和代理错误截图，因此手机中断的根因不能仅凭这一条通用错误定论。

在 Mac 上使用同一 `LoopbackConnectProxy` 和默认服务器信任校验的临时
URLSession 做一次显式本机代理对照，观察到系统发送：

```http
CONNECT gs-loc.apple.com:443 HTTP/1.1
Host: gs-loc.apple.com
```

旧解析器要求 Host 必须与带端口的 CONNECT authority 字符串完全相等，因而
返回 400；对照出现 `kCFErrorDomainCFNetwork 310`、零目标连接和
“CONNECT 请求被拒绝”。这是明确复现的兼容性问题，但 Mac 错误码不等于
已经取得手机错误码。

修正只允许 Host 为已匹配的同一个域名，或该域名加 `:443`。CONNECT 请求目标
仍必须精确匹配原有四个 `host:443`；错误端口、其他域名、后缀欺骗、userinfo
和尾点仍被拒绝。不调整路由、DNS、域名列表、监听地址、TLS 或证书策略。

修正后的结果：

- 18 项本机自动测试通过；新增四个域名的无端口 Host 兼容覆盖及负向用例，
  256 KiB 二进制原样转发测试也改用真实 CFNetwork 的 Host 格式。
- Debug iPhone 目标编译通过，只有原有静态库最低系统版本警告。
- Mac 直连同一 `HEAD https://gs-loc.apple.com/` 收到 HTTP 404，TLS 校验通过。
- 修正后 Mac 本机代理对照收到 HTTP 404；URLSession metrics 报告
  `isProxyConnection = true`，记录 1 条目标连接、发送 897 字节、接收 3101 字节。
  非 2xx 不影响本次 HTTPS 传输验证。
- HTTP 已完成后的快照也出现“客户端连接失败”；不能据此把已完成的 HTTPS
  传输写成失败，也不能把这一连接关闭元数据直接当成手机故障原因。
- Mac 对照显式设置了该 URLSession 的本机代理，只用于定位解析器问题，
  **没有验证 iOS 的 NEProxySettings 选择行为**。iPhone App 自测仍不添加代理覆盖。
- 用户确认停止实验后，修正提交 `cc8c86e` 以同一 P12、profile 与 zsign
  重签。10:49 更新安装成功，10:50 主 App 启动成功，目标仍为
  `app.eclipse296.lake3160`。用户随后确认 HTTPS 自测通过；后续状态见下节。

## 2026-09-09：iPhone 自测通过，地图未观察到新连接

证据来源为用户在当前任务中的页面读数反馈，尚未取得截图或导出的状态快照。

- 修正版显示“HTTPS 请求与代理双向数据均已观测到 HTTP 404”。依照当前自测
  判定代码，这包含 HTTP 响应、URLSession 的代理标记以及扩展收发数据证据。
  只能确认 StikDebug 自测链路，不证明具体 `/clls/wloc` 或位置修改。
- 用户打开苹果自带地图（国内使用高德地图服务），地图成功显示当前位置；多次
  点击定位后没有观察到统计变化。此结果记录为“没有观察到目标域名连接”，
  不能写成系统没有发任何网络请求或系统必然绕过代理。
- 自测每次先清零，通常累计显示 1 条；活动连接由 1 回到 0 表示该连接结束，
  与累计连接数和监听器是否仍运行是不同的状态。
- 待区分的解释包括：定位由现有信息／GPS 等提供而未触发新的目标请求；
  请求使用当前代理未覆盖的域名或协议；该请求未采用这些代理设置。
  仅凭地图显示位置和零新增计数无法选择其中一个原因。
- 执行的最小对照：清零后把 StikDebug 放后台，在同一 iPhone 的 Safari 手动
  请求 `https://gs-loc.apple.com/?stikdebug-probe=20260909`，返回查看计数和
  双向字节，不再运行 App 自测。此为一次诊断请求，不引入网站依赖或 Worker。
  HTTP 404 属于允许的传输结果，必须结合扩展计数判断。
- 用户反馈打开上述地址 3 次，目标域名连接累计为 3，发送约 6 KB、接收约
  10 KB。此结果支持 Safari 的这些请求经过了本机代理，不只是主 App 自测
  可以访问监听器。计数不能单独作为请求路径或发起进程的取证证明，归因基于
  这次受控操作及用户反馈；尚无截图或带时间戳的完整快照。
- Safari 对照通过不能推广为系统定位服务也采用代理；后台能力需要下述独立
  对照。当前不改变定位权限、路由、DNS 或代理范围。
- 后台对照步骤：清零后将 StikDebug 留在后台至少 5 分钟，中途不重新打开它。
  5 分钟后先在 Safari 请求同一 Apple 域名的新诊断 URL
  `https://gs-loc.apple.com/?stikdebug-probe=background-1`，再回 App 查看新增连接、
  双向字节和最近活动时间。新查询参数用于区分这次请求，不包含位置或凭据；
  不使用 App 自测代替后台请求证据。
- 用户对上述步骤反馈“同样可以收到在后台”。记录为本次用户报告的后台新请求
  对照通过；未收到实际离开／返回时间、具体字节数或截图，也未由工具独立计时。
  不推导长时间保活、锁屏、强制退出、换网或系统重启兼容性均已通过。
- 停止测试后的模式及网络恢复步骤：点击“停止测试并恢复隧道”，
  应退出实验、显示普通开发连接模式与本机代理未就绪；普通 VPN 是否连接取决于
  进入前状态，不要求一律断开。然后确认 Safari 普通网页正常。
- 用户对上述停止、模式及普通网页检查反馈“都正常”，记录为该普通停止路径的
  用户实测通过。尚无截图或独立状态快照，不能推广为启动中取消、不同进入前
  VPN 状态、App 重启恢复等所有生命周期场景均通过。
- 实验保持关闭时的旧定点、摇杆和路线回归：每项短时测试后停止并
  恢复真实定位，不要求进入游戏或重新验证金盆效果。任一步异常即暂停排查。
  用户对此反馈“正常的”，记录为三项普通回归的用户实测通过，没有独立截图或
  命令记录；系统定位请求未观察到的问题继续保留。

Apple 的[定位服务说明](https://www.apple.com/legal/privacy/data/en/location-services/)
列出 GPS、蓝牙、Wi-Fi 热点和基站等定位来源；这支持定位不只依赖单一网络
接口，但不直接证明本次地图使用了哪一种来源或缓存。

## 下一项：系统定位请求的只读诊断

2026-09-09 重新核对公开参考模块，发现需要区分的覆盖差异：

- [cyberhandyman 模块](https://cyberhandyman-ioslocspo.cyberhandyman.workers.dev/ios-location-spoofer.sgmodule)
  仍为当前四个域名，但匹配 `http` 与 `https`；当前实验只配置 HTTPS 代理与
  CONNECT 443，不包含普通 HTTP 转发。
- [Yu9191 模块](https://raw.githubusercontent.com/Yu9191/wloc/refs/heads/main/modules/wloc.module)
  另外包含 `gsp-ssl.ls.apple.com`。没有手机实际请求的证据，当前不直接增加
  该域名、普通 HTTP 或其他代理范围。
- [上游 README](https://github.com/Yu9191/wloc) 提到 iOS 26 缓存和重启经验，
  这属于作者报告，不是当前手机中断原因的证明，也没有据此操作重启、飞行模式
  或定位权限。上游同时报告后续 iOS 27 beta 的 MITM 限制；当前 iOS 26.6.1
  透传验证不能代替未来证书阶段的系统版本兼容验证。

已准备只读、限时的 `locationd` 日志观察：针对用户连接的指定 iPhone，使用
`idevicesyslog -p locationd`，本机仅提取固定事件标签和上述已知域名的出现次数。
不展示或保存原始日志行、坐标、URL 查询参数、正文或凭据。

一次 5 秒接口预检确认可读取日志；看到 607 行定位服务输出，仅提取出 1 次
缓存词项引用，没有已知域名引用。此时尚未与用户打开地图同步，且日志可能有
隐私脱敏，因此这些计数既不能证明缓存导致问题，也不能证明没有网络请求。

待用户重新开启实验、清零并确认就绪后，再开始一次同步短时观察，让用户打开
苹果地图请求当前位置。暂不修改代码、代理配置或系统定位设置；若日志不暴露
足够信息，应明确记录不可判定，再讨论下一项有针对性的验证。

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
