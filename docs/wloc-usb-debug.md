# WLOC USB 诊断（仅 Debug 签名测试版）

## 范围

为当前阶段一 HTTPS CONNECT 透传实验增加诊断能力；不增加 MITM、证书、坐标改写、代理域名、路由或远程服务器。App 显示名保持 StikDebug。

扩展通过系统日志每 2 秒发布一条 `STIK_WLOC_DEBUG_V1` JSON，以及就绪、清零、停止事件。扩展自己采样，不依赖 App 页面轮询，所以 App 切后台时仍可记录。App 自测发布结构化结果（是否经代理、HTTP 状态、必要时 NSURLError 数字码）。诊断代码受 `#if DEBUG` 限制。

日志仅包含四个固定域名的连接计数、双向字节、时间、监听端口、会话 ID 和固定错误码。不包含坐标、TLS/HTTP 正文、请求路径、凭据或原始错误描述。Mac 工具只接受严格白名单 JSON；不保存或显示原始系统日志。没有流量来源 App / PID 信息，不能用这些记录直接证明 locationd 请求、`/clls/wloc` 路径或定位成功。

## Mac 读取

依赖已配对并信任此 Mac 的 USB iPhone，以及 `idevicesyslog`（libimobiledevice）。必须使用**实际安装的 Debug App Bundle ID**，以免混入同名 App 的记录。

```sh
python3 -B Tools/wloc-debug.py --bundle-id app.eclipse296.lake3160 watch \
  --udid 00008140-00062C2E1488801C --seconds 45
```

观察每次最多 55 秒。退出只停止本工具创建的日志子进程，不停止 VPN。零条日志表示诊断通道未观察到记录，不等于零连接。比较记录时先检查 `bundleID`、`at`、`snapshot.sessionID` 和 `snapshot.resetAt`，避免把旧会话、自测或清零前的计数混在一起。

## Mac → iPhone 受限指令

使用 Xcode `devicectl` 的已配对 App 数据容器服务，不开放网络监听端口。Debug App 首次进入前台会创建 `Documents/WLOCDebug/`。Mac 写入最多 1 KB 的 `request.json`，成功后再复制匹配 UUID 的 `ready.txt` 提交标记；App 在前台每 0.5 秒检查一次。半写入文件或不匹配的旧标记不会触发操作。

只接受 `status`、`reset`、`selfTest`、`stop`。每条请求限 60 秒有效期（未来时钟误差最多 5 秒），带 UUID 回执，原子保存已处理时间游标，拒绝过期、旧时间、重复或额外字段。请求先移入固定的 `claimed.json` 再执行；不自动重试有副作用的指令。目录仅保留最近请求、游标和响应，排除备份。Release 不处理这些文件。

```sh
python3 -B Tools/wloc-debug.py --bundle-id app.eclipse296.lake3160 status \
  --device 7E85C01C-59CA-4ACE-85CA-C12E43279E57
```

把 `status` 换成 `reset`、`self-test`、`stop` 分别清零、运行已有 HTTPS 自测、停止实验并恢复先前隧道意图。默认会将 StikDebug 打开到前台；`--no-launch` 用于已经在前台的情况。指令在 App 被系统挂起时不会执行，因此**观察其他 App 时只运行 `watch`**；先完成清零并收到回执，再切地图。

`status` 查询真实扩展状态；`reset` 的成功回执依赖 provider IPC 成功；自测仍按既有代理 + 双向字节条件判断，HTTP 404 可以通过传输测试，但不证明定位成功。繁忙或未启动实验时拒绝清零/自测。`stop` 不会关闭普通开发隧道。系统权限、VPN 首次开启和地图点击仍由用户操作。

工具要求 Mac 与 iPhone 时间基本一致。若等待回执超时，先查询状态，不要盲目重发；工具不会据“复制成功”宣称指令完成。日志和命令通道都需要真机验证，代码/构建通过不能替代此项。

## 验证记录（2026-09-09）

### Section 1：扩展遥测与 Mac 读取器

- Swift 包测试：20 项通过（原有 18 项 + 元数据脱敏、大小与时间字段 2 项）。
- Mac 读取器：4 项测试通过（精确 Bundle ID、未知字段/域名拒绝、畸形与超长记录、类型检查）。
- Debug 真机目标无签名构建成功；保留原有 `libpairable_host.a` iOS 18.0 / deployment 17.4 链接警告。
- 尚未安装这个诊断版本；USB 实时日志、后台日志是否在此设备上可见仍待真机验证。

### Section 2：受限 USB 指令与回执

- Swift 包测试：23 项通过（新增动作白名单、过期/未来/重复请求、超长/畸形/额外字段 3 项）。
- Mac 工具测试：6 项通过（新增先复制载荷再提交标记、匹配回执、复制失败不重试）。
- Debug 与 Release 真机目标无签名构建均成功。Release 主程序和网络扩展二进制均未检出 `STIK_WLOC_DEBUG_V1` / `WLOCUSBDebugBridge` 标识。
- Release 构建保留依赖静态库的原有链接/缺少调试对象文件警告，未修改 FFI 库。
- 已验证 Mac 可通过 USB 读取准确 Bundle ID 的 App 数据容器；指令收发、安装和设备日志尚待验证。

### 签名与安装交接

- Section 1 commit：`8f8ee41`；Section 2 commit：`6352c79`。
- `6352c79` 已使用用户原有 P12 + zsign 签名，App ID 仍为 `app.eclipse296.lake3160`；网络扩展与 Live Activity 的 Bundle ID 后缀均保持正确。没有改动源项目身份或其它已安装 StikDebug。
- IPA：`/Users/junyang/IdeaProjects/wloc-reasearch/artifacts/StikDebug-WLOC-USB-6352c79-zsign.ipa`。
- SHA-256：`83ca7b3564058843ed02269c9356c61f78ddc410477e72a4464c2a5cbfa37705`；ZIP 完整性检查通过。Debug App 与 tunnel 的 `.debug.dylib` 含诊断标识；最终 Release App 包未检出诊断标识。
- USB 读取旧版偏好时，`wlocProbeRestoreConnection` 仍存在，表示实验尚待停止/恢复。为避免在实验运行期间替换扩展，**本次尚未覆盖安装**，已请用户先停止测试。
- 下一步：停止后更新安装；先发 `status` 验证双向回执，再由用户开启实验，Mac 执行清零/自测并读取扩展流。后台与地图触发验证仍不能跳过；本节未宣称已捕获系统 WLOC 请求。

### 2026-09-11：重新连接设备，准备首次安装

- 已发现原测试 iPhone 16 Pro Max（🐑🐑），配对可用，并成功打开准确的 `app.eclipse296.lake3160`；未操作其它手机或同名 App。
- 已重新验证 IPA SHA-256 与上次记录一致。USB 读取偏好仍存在实验恢复标记；首次检查尚无 `Documents/WLOCDebug`，符合仍在旧版的状态，不能宣称诊断通道已连通。
- 修正 Mac CLI 冷启动竞争：在发送载荷之前，最多等待 8 秒轮询诊断目录就绪（单次设备调用另有限时）；只重试只读检查，不重试已提交动作。真机确认不存在的目录会返回失败，能正确阻止过早发送。
- Mac 工具 7 项测试通过；这一节仅改变 Mac 工具和测试，不改变已签名 IPA。

### 2026-09-11：安装与 USB 双向通信真机通过

- 用户确认已停止；设备进程列表成功读取，未见 `PikminTunnel`。偏好标记仍存在，但它表示**待完成的恢复流程**，并非当前代理正在运行，不能仅凭它要求用户反复停止。
- 已成功更新安装 `StikDebug-WLOC-USB-6352c79-zsign.ipa`，Bundle ID 保持不变，未卸载 App 或删除数据；新 App 已成功启动。
- 发现并复现 Mac 启动命令参数顺序问题：`process launch` 把 Bundle ID 后的参数当作 App 参数，导致工具报缺少 `--device`。现已将 devicectl 公共选项放在 Bundle ID 前；8 项 Mac 测试通过，修正版自动打开 + USB `status` 真机成功。
- 首个 USB `status`：`vpnState=disconnected`、`experimentEnabled=true`。同一 UUID 的 `accepted` / `ok` 回执既能从文件通道读出，也能通过 USB 系统日志读出，证明双向指令与日志通道均可用。
- USB `stop` 成功完成恢复：`vpnState=connected`、`experimentEnabled=false`。这是恢复进入实验前的普通开发隧道，不是重新启动 WLOC，也未恢复模拟坐标。
- 用户手动开启新实验后，真实扩展快照为 `mode=wlocProbe`、`listening=true`；Mac `reset` 收到成功回执和空统计。
- Mac `self-test` 成功：HTTP **404**，`usedProxy=true`，`gs-loc.apple.com` **1** 个连接，发送 **1,904 B**、接收 **3,316 B**，活动连接随后从 1 回到 0。45 秒观察共接收 **31** 条白名单诊断记录，含扩展心跳、清零、自测和对应回执。
- 自测后再次 USB 清零成功。接下来单独观察用户切换系统定位服务时的后台扩展日志；系统 WLOC 来源/请求路径与新版本后台 5 分钟测试尚未确认。

### 2026-09-11：系统定位开关与地图操作窗口

- 自测后清零时点为本地时间 11:15:32（Unix `1789096532.000885`），四个域名统计为空。此后 Mac 仅通过 USB 日志只读观察，没有打开 StikDebug、发起自测或再次清零。
- 用户确认在系统设置关闭定位服务约 10 秒再打开，未先打开地图/Safari。确认后的 20 秒采样读取 10 条扩展记录：`gs-loc-cn.apple.com` 从 19 增至 **20**，最终发送 **42,491 B**、接收 **227,624 B**。自测域名 `gs-loc.apple.com` 未出现在这次清零后的统计中。
- 下一段 55 秒窗口读取 29 条记录，用户随后确认已在系统地图点击当前位置。CN 域名从 **20 → 21**，新增发送 **2,224 B**、接收 **6,013 B**；合计发送 **44,715 B**、接收 **233,637 B**。这是操作窗口内的变化，不是来源 PID 证明，也没有精确到点击瞬间的独立时间戳。
- `connections` 在 CONNECT 头完整解析、白名单校验通过之后、上游连接成功之前递增。因此以上数字不是成功 HTTPS 请求数、WLOC 次数或定位次数。
- 记录先后出现 `upstream_interrupted`、`client_failed`。它们分别对应 Network 框架上游/客户端 `.failed` 路径；目前只有最后一个错误标签，没有关联连接 ID、发生次数或底层 NWError 数字码，不能据此认定是正常关闭，也不能认定全部连接失败。
- 后续两个只读窗口各收到 28 条记录。用户按要求停留于设置/地图，Mac 未再次前台启动 App；从确认切换后的首个采样 11:17:48 到 11:23:02，扩展保持相同 sessionID、监听端口与清零时间，证明这个操作时序下超过 5 分钟仍有扩展心跳。**心跳存在不等于 5 分钟后已处理新连接**，因此继续用手机 Safari 单独做新连接对照。
- 局部脱敏证据文件位于 `/private/tmp/stikdebug-usb-sign.MfEwty/`，仅包含经过 Mac 白名单校验的 JSONL，不含原始系统日志、坐标或流量正文。以上是 HTTPS CONNECT 透传层的证据，不涉及证书解密或位置改写。

### 2026-09-11：超过 5 分钟后的新连接与本轮收尾

- 请求用户在手机 Safari 打开 Apple 根地址作为独立对照后，新的 55 秒窗口收到 28 条记录。同一会话的 `gs-loc.apple.com` 从无记录增至 **2** 条 CONNECT，发送 **3,804 B**、接收 **6,561 B**；CN 域名保持 21 条。期间 Mac 没有发起 App 自测，也没有前台启动 StikDebug。
- 首次采样到新域名连接为 11:24:10（Unix `1789097050.388714`），相对用户已确认切换设置后的首个采样超过 **6 分 21 秒**。活动连接从 1 回到 0，后续仍有少量接收字节；因此观察到的不仅是旧计数或心跳，而是后台窗口后的新 CONNECT 和双向转发。此时尚未收到用户的 Safari 完成回复，不把来源 PID 或具体页面结果写成已证实。
- 该窗口末尾错误标签为 `relay_interrupted`；结合此前客户端/上游标签，目前无法统计错误次数或确定原因。下一项合适的诊断是为连接增加受限的数字错误码、方向与生命周期记录，而不是直接认定所有 TLS/WLOC 请求成功。
- 本轮完成后通过 USB `stop` 收到 `ok`，实验标记为 false；随后查询扩展真实状态，确认普通 `developerLoopback` 模式。没有清除模拟坐标、引入远程代理、添加新域名、部署 Worker 或安装 CA。
- 结论：本机 CONNECT 代理已观测到非自测的 Apple 定位域名流量，并能在上述后台时序下处理新连接；尚未解密确认 `/clls/wloc`，未修改定位。其它生命周期边界及断连原因仍有待验证，不标记整个阶段一全部完成。

## 连接级诊断迭代（2026-09-11）

本次只改 Debug 观测层，不改变 CONNECT 校验、代理范围、双向字节转发、超时、半关闭或模式切换策略。没有修改地图界面、添加 CA、MITM、坐标改写或 Worker。

新增 `event=connection` 的五个阶段：`accepted`（TCP 接入）、`targetValidated`（完整 CONNECT 校验通过）、`upstreamReady`（上游 TCP 就绪）、`relayReady`（200 应答已交给网络栈，开始转发）、`closed`。这些阶段都不能直接代表 HTTP/TLS 或 WLOC 成功。

- 每条连接拥有 UUID，绑定代理 sessionID 与接入时的 resetAt；使用单调时钟记录耗时。每条连接最多五条生命周期日志，不按流量块输出，不保留无限历史数组。
- 关闭记录包含白名单域名、累计转发字节、两侧 EOF 标志、关闭原因，以及首个失败的操作阶段、方向、NWError 类别与数字码。收到错误时若同时携带数据，仅记录其字节数和 EOF 标记，不读取/输出内容，也不在本轮擅自改变原有错误处理。
- 错误类别仅限 `posix` / `dns` / `tls` / `other`，不序列化 `localizedDescription` 或任意错误字典；当前代理仍是原样 TCP 转发，记录 TLS 错误码类型不代表做了解密。
- 关闭原因区分双向 EOF、提前 EOF、取消、拒绝、传输错误、握手/空闲超时、主动清零、主动停止和连接上限。只发布一次终止记录，保留首个错误，避免后续取消覆盖原始原因。
- 新计数器区分 TCP 接入、CONNECT 通过、上游就绪、转发就绪、关闭、带错误关闭、清零关闭、停止关闭。`errorClosed` 是存在传输/策略错误的关闭数，不是失败 HTTP 请求数；若先发生错误再清零/停止，两类可同时计数。
- 清零时先用旧 resetAt 发布旧连接关闭记录，再清空计数并发布新 epoch。停止时发布最后计数。两秒心跳携带累计计数，因此短暂连接即使落在采样间隙也不会消失。
- Mac 端严格校验新事件的所有字段、白名单域名和枚举，仍限制单条 JSON 为 4 KB，并兼容原有诊断版本；未知字段或非元数据内容不输出。

本地验证：新增 10 项纯诊断测试、1 项不完整 CONNECT 提前 EOF 回归测试，并为 7 项现有集成测试补充生命周期断言；完整 Swift 测试共 34 项通过，半关闭测试额外连续复测 5 次通过；Mac 工具 14 项测试通过。Debug/Release 真机目标构建通过，Release 包未检出诊断标识或 `ProbeConnectionTrace`。回环测试观察到完整载荷和双向 EOF 与底层断连错误可以同时出现，因此测试和结论不把 EOF 等同于 HTTPS 成功。新诊断版本尚待签名安装及真机采样。

### 连接级诊断版本签名安装

- 代码提交：`21cc78e`。使用原有 P12、配套描述文件及 zsign 签名；IPA 为 `/Users/junyang/IdeaProjects/wloc-reasearch/artifacts/StikDebug-WLOC-Trace-21cc78e-zsign.ipa`，SHA-256 为 `2e36c03954a7eb3191ff020e5143062c342aafe8bd8d861445bb2bd6643ee4f9`，ZIP 完整性校验通过。
- App / tunnel / Live Activity Bundle ID 分别保持 `app.eclipse296.lake3160`、`.networkextension`、`.liveactivity`；签名前排除了构建目录残留的测试包、dSYM 和旧签名。签名后 App 与 tunnel 的 Debug 动态库均检出 `ProbeConnectionTrace`。
- 安装前 USB 查询确认 `experimentEnabled=false`、扩展真实模式为 `developerLoopback`。已在同一台 iPhone 16 Pro Max（🐑🐑）成功覆盖安装，未卸载或清理数据；其它手机和同名 App 未操作。
- 安装后自动打开 App 并完成 USB `status`，仍为普通回环模式（`vpnState=connected`、`experimentEnabled=false`、`listening=false`）。尚待用户手动开启实验后验证新生命周期日志；不把安装和状态查询等同于已完成真机转发测试。

### 新版真机自测：HTTP 已完成仍有关闭阶段错误

- 用户手动开始实验，新扩展 sessionID 为 `E18E9025-FFDF-4DCE-B200-18907D60FB3F`，监听端口 50893。新计数器通过 USB 日志正常输出；清零指令成功。
- Mac 发起一次 App 内 HTTPS 自测，结果为 `passed`、`usedProxy=true`、HTTP **404**。连接 `6B167C8A-73E8-455E-B07C-AA7DB450932C` 的五条阶段记录均收到：TCP 接入 0 ms、CONNECT 校验 1 ms、上游就绪 57 ms、转发就绪 58 ms、关闭 221 ms；发送 **1,904 B**、接收 **3,316 B**。
- 同一连接关闭原因为 `transportError`，首个失败为 `clientState` / `client` / POSIX **50**；关闭时 `clientEOF=true`、`upstreamEOF=true`。因此 `errorClosed=1` 与已获得 HTTP 响应可以同时成立，不能直接当作失败请求数。此记录仍不足以把所有相似错误视为正常，也不能推广到尚未观察的系统请求。
- 自测观察文件 `self-test-lifecycle.jsonl` 共 41 条白名单记录（含五条连接阶段），位于 `/private/tmp/stikdebug-trace-sign.YxLP1V/`；没有保存原始系统日志或正文。
- 自测后再次 USB 清零（Unix `1789104238.585957`），随后只读观察用户切换系统定位服务，避免混入 App 自测。

### 新版非自测定位域名采样

- 请求用户切换系统定位服务后，两个只读 USB 窗口分别收到 120 条、27 条白名单记录；采样中没有再次启动 StikDebug、运行自测或清零。采集时尚未收到用户“已切换”确认，因此只能与操作请求窗口关联，不能声称已确认精确触发动作或来源进程。
- 同一 session/reset epoch 共 **20** 条 `gs-loc-cn.apple.com` CONNECT，全部观察到独立的 `upstreamReady`、`relayReady`、`closed` 记录；累计发送 **42,499 B**、接收 **238,132 B**，最终活动连接为 0。没有 `gs-loc.apple.com` 自测连接混入。
- 关闭分类：**4** 条 `completeEOF`（双 EOF、无记录错误）；**15** 条 `clientState` / `client` / POSIX **54**（客户端 EOF 为 true，上游 EOF 为 false）；**1** 条 `upstreamState` / `upstream` / POSIX **50**（双 EOF）。最后一条心跳计数为 `tcpAccepted=connectAccepted=upstreamReady=relayReady=closed=20`、`errorClosed=16`。
- USB 单事件日志并非完整无丢失：共收到 96 条连接事件，其中 `accepted` 19 条、`targetValidated` 17 条，后三个阶段各 20 条；前两阶段依累计计数交叉核对，不能宣称每条连接的五条日志全部收到。全部 20 条终止记录均在采样文件中。
- 样本已证明错误并非都与 App 自测主动结束有关，但尚不能断定是系统正常取消、半关闭时序或代理转发缺陷。双向字节与 EOF 也不足以证明系统 HTTP 响应完整或 `/clls/wloc` 成功；没有进行 TLS 解密。
- 下一项最小验证应针对“读取 EOF → 对侧 `.finalMessage` 提交/完成 → 状态失败”的先后关系，补充确定性半关闭/客户端复位对照；保持现有错误可见，不通过忽略 POSIX 50/54 或扩大代理范围来制造成功结果。
- 本轮新诊断的真机观察文件为 `/private/tmp/stikdebug-trace-sign.YxLP1V/location-toggle-lifecycle.jsonl` 与 `location-toggle-followup.jsonl`。本次新增验证未重跑完整 5 分钟后台实验，之前版本的后台证据保留在前文，不混写为本次版本已通过。
- 采集完成后 USB `stop` 成功；随后独立 `status` 确认 `experimentEnabled=false`、`mode=developerLoopback`、`listening=false`、`vpnState=connected`，实验代理已撤销并恢复普通回环模式。

## 自动回归迭代：半关闭截断（2026-09-11）

本轮继续阶段一；没有修改域名范围、默认路由、DNS、地图/UI、证书或坐标。本机 BSD socket 测试端点只使用 `127.0.0.1`，以确定的字节内容和 FIN/RST 顺序为对照，不依赖手机反复操作地图。

### 已复现的问题与修复范围

- **完整 CONNECT 与 EOF 同回调：** 提取 `ConnectHeaderReader` 重放原有决策，红测试确认原实现将合法 CONNECT + 初始字节 + EOF 判断为关闭。修复后携带 `clientReadClosed` 建链，发完 200 和初始数据再半关闭上游写方向，继续读取响应。不完整 CONNECT + EOF 仍不建链；白名单校验没有放宽。四个纯决策测试覆盖全部 header 分片边界。
- **已提交 FIN 后的反向数据截断：** BSD 对照两种方向均完整，但旧代理把 131,089 B 响应截为 32–64 KiB、98,321 B 上传截为 32 KiB。新的时序记录确认先完成向该端的 FIN，再出现该端 `state.failed / ENETDOWN(50)`；剩余读取和 EOF 尚未处理，立即 `cancel()` 导致截断。不是只靠错误标签推断，也不等于此前手机 POSIX 54 的原因已被确认。
- **有限排空：** 仅对 ENETDOWN 且此前已向同一端提交 FIN 的收尾情况保留现有单块读取/发送链，允许读取已缓冲内容；独立 1 秒截止时间不随传输或重复错误延长。其它错误（含 RST）不被自动降级。错误仍进入首错与最终错误记录，完整转发不被误记成“干净关闭”。不宣称所有类型的 `data+error` 已被修复。

### 诊断边界

关闭记录新增两侧 `readEOF`、`writeCloseSubmitted`、`writeCloseCompleted` 以及首错 `observedAt`，只记录同一串行队列内的相对次序和耗时，最多 7 个标记，不增加每块日志。最终 JSON 仍限制 4 KB，Mac 严格校验字段/类型/范围并兼容旧版本。

`writeCloseCompleted` 只代表关闭前处理到了无错误发送回调，不代表对端 ACK；缺失也可能是回调晚于终止。对于同一回调的 EOF 与错误，不能由标记推导网络因果。Apple SDK 的 `nw_connection_receive_completion_t` 明确区分读关闭与整个连接关闭，也允许数据与错误同时交付；本轮修复仅覆盖已复现、可测试的半关闭窗口。[Apple 接收回调语义](https://developer.apple.com/documentation/network/nw_connection_receive_completion_t)

### FIN 完成回调竞态与最终本地验证

- 增加可注入的 `writeClose` 回调；默认仍为原有 Network `.finalMessage`，注入只在本机测试使用。真实发出 FIN 后模拟回调 ENETDOWN，旧逻辑把 131,101 B 延迟响应截为 0 B；不实际发送 FIN、只模拟错误时，旧逻辑约 0.00022 秒便关闭，两个红测试复现了遗漏的错误出口。
- 修复让同一窄门槛覆盖状态、读取及 FIN 完成回调；`settledWriteCloses` 只计回调结算，不表示成功。失败 FIN 不记录 `writeCloseCompleted`，首错仍保留；两条读链的最后数据已处理、各自 FIN 回调均结算后，才能早于截止时间结束。
- 最终 **49** 项 Debug Swift、**23** 项 Release Swift、**16** 项 Mac 工具测试通过。8 项终止场景连续 **3** 轮（24/24）通过；其中无实际 FIN 的截止分别为 1004 / 1005 / 1005 ms，排空中的 stop/reset 立即结束，旧定时器不会重复关闭或污染新 epoch。此前5项真实 BSD 场景另已连续5轮通过；没有放宽原样载荷断言。
- Debug/Release 真机目标构建成功。Release App 包未检出诊断前缀、USB 桥或 `ProbeConnectionTrace`。保留既有 FFI 静态库链接警告，未修改这些依赖。
- 本地验证不代表已消除手机上此前所有 POSIX 54；安装后仍需通过 USB 自测验证实际构建。本节尚未部署 CA、MITM、坐标改写或远程代理。

### 半关闭修复版安装

- 代码提交 `b907575`，使用原有 P12 / 描述文件 / zsign。IPA：`/Users/junyang/IdeaProjects/wloc-reasearch/artifacts/StikDebug-WLOC-HalfClose-b907575-zsign.ipa`；SHA-256：`b206198f9ab612aadae02adc30610253027f5ab33bffeca94e22457419b3244e`，ZIP 校验通过。
- 安装前 USB 确认实验关闭、真实扩展为普通回环模式。已成功覆盖安装到同一台 iPhone 16 Pro Max（🐑🐑），App / tunnel / Live Activity Bundle ID 保持不变；未卸载、未清理数据、未操作其它手机或同名 App。签名后 tunnel 动态库确认包含本次 `HalfCloseDrainPolicy`。
- 安装后 App 自动打开成功，USB `status` 返回 `mode=developerLoopback`、`experimentEnabled=false`、`listening=false`，普通回环仍连接。已请求用户手动启动一次实验，之后由 Mac 连续自测并停止；此时尚未宣称新版真机转发验证完成。
