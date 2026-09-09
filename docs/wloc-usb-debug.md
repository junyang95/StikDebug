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

## 验证记录（2026-09-09）

### Section 1：扩展遥测与 Mac 读取器

- Swift 包测试：20 项通过（原有 18 项 + 元数据脱敏、大小与时间字段 2 项）。
- Mac 读取器：4 项测试通过（精确 Bundle ID、未知字段/域名拒绝、畸形与超长记录、类型检查）。
- Debug 真机目标无签名构建成功；保留原有 `libpairable_host.a` iOS 18.0 / deployment 17.4 链接警告。
- 尚未安装这个诊断版本；USB 实时日志、后台日志是否在此设备上可见仍待真机验证。
