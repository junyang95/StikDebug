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
