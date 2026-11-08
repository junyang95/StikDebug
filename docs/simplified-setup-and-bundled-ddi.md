# 精简设置与内置 DDI — 0.1.10 (11)

`codex/pikmin-helper` 不使用网站 VIP、注册、封禁、联网授权或限时离线许可。受保护操作使用安装包签名凭据进行本地设备绑定。地图定点、行走路线、摇杆、HealthKit、历史记录、Live Activity、配对及本地 VPN 功能保留。

## 设置和定位

打开 App 可以先浏览。点击“开始设置”后直接进入设备设置，不出现 VIP 页面，不请求网站授权。配对、开发者模式、VPN 和系统权限继续按照原有连接流程处理。进入后台、替换配对文件或本地连接变化时，仍保留任务取消及连接失效处理。

首次定位命令先建立真正用于发命令的 RSD 隧道，在同一隧道的 lockdown 服务读取 `UniqueDeviceID`，校验安装包内 `wowdevice.plist` 的签名、产品与设备标识，然后才创建定位控制器并发出 set。不是 UI 开关，也不使用另外一次连接探测来放行。

成功检查仅在该定位连接内复用；更换目标 IP 或配对记录、VPN 断开或命令失败后重连均重新检查。JIT、DDI 挂载及其他受保护开发操作也在各自实际使用的隧道上检查。缺失、损坏、签名无效、产品错误、设备不匹配均拒绝，不访问网站、不保存跨连接放行缓存。

暂停、停止和清理不要求绑定凭据。恢复真实位置可在没有凭据、凭据无效或 App 重启后重新建连执行 clear；恢复通道不会变成后续 set 的放行依据。本地连接状态、配对记录和 WLOC 测试互斥规则继续保留。

## 内置资源

资源固定到上游 `doronz88/DeveloperDiskImage` 提交 `6eae353ae694bda1c421d4a3eee5459ae59c99a1`。大小和 SHA-256 保留在 `StikDebug/Core/DDIAssetSet.swift`。

| 系统分支 | 目录 | 文件数 |
| --- | --- | --- |
| iOS/iPadOS 17.4–26.3 | `DDI/Xcode_iOS_DDI_Personalized` | 3 |
| iOS/iPadOS 26.4 及以上 | `DDI/Xcode_iOS_DDI_Cryptex` | 5 |

仓库 `Resources/DDI` 作为完整文件夹放入主 App，避免同名文件被展平或写入两个扩展。8 个文件合计 33,239,188 字节（约 31.7 MiB），实际 IPA 大小取决于 ZIP 压缩。

用户选择安装后，程序将当前系统所需文件复制到可写缓存，完成大小及哈希校验后再提交整套资源，随后使用现有系统协议挂载。恢复操作从安装包重新准备资源，保留配对记录。缺失、损坏、取消或复制失败直接报告错误，不访问下载服务器，也不以部分文件替换原有完整缓存。

App 没有新增“先装 DDI 才允许定位”的阻塞条件。这不构成所有真机均无需 DDI 的兼容性保证：底层调试服务能否使用仍由设备系统决定。Apple 个性化挂载所需的硬件参数与系统请求保留，内置资源不等于所有步骤均可离线。

## 重签发布

主 App 的 `WowOfflineDeviceBinding` 字典声明 `schema = 1`、`product = pikmin-helper` 与 `keyId = 9a6a40f263ac458839e9a4fe6973cee315e10111e1ffd30425788491deefe607`。产品验证常量写在运行代码中，不使用可修改的 Info 值决定接受哪个产品。

签名服务需把 `wowdevice.plist` 放在主 App 根目录，其字典只包含 `payload` 和 `sig` 两个 Base64 字符串。payload 是 UTF-8 JSON：`{"schema":1,"purpose":"wow.offline-device-binding","product":"pikmin-helper","udid":"小写设备标识"}`；sig 是该原始 payload 字节的 P-256 / SHA-256 ECDSA DER 签名。App 只接受编译时固定公钥，不接受凭据自带公钥。

主包不添加旧 `PikminNativeVIP` 或 `WowNativeDeviceAccess` 标记，不消费 `wowvip.plist`。重签流程须按新的标记生成设备凭据，避免重新注入旧商业验证库。原始未绑定包仍可浏览和配对；没有正确凭据时受保护操作会明确失败。一个凭据只绑定一台设备，不能作为多设备共用的企业共享包凭据；需按设备生成签名包。三个目标的版本统一为 0.1.10 (11)，更新原始 IPA 后需使旧签名缓存失效。

## 验证

运行 `Tools/test-pikmin-runtime.sh` 验证真实定位 gate、会话控制器、坐标解析和内置 DDI（错误凭据不建控制器/不发命令、连接变化重验、无凭据恢复位置）；DDI 测试使用仓库中的真实 8 个资源。`Tools/verify-pikmin-helper.sh` 构建 App 与测试目标；Release archive 打包后还需核对主 App 的两套文件、哈希和两个扩展。

主机测试、编译和包内检查不能替代真机配对、VPN、定位、Apple 个性化及 DDI 挂载测试。
