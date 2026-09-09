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
