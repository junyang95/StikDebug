# 精简设置与内置 DDI — 0.1.9 (10)

`codex/pikmin-helper` 移除网站 VIP、注册、封禁、UDID 比对和离线许可。地图定点、行走路线、摇杆、HealthKit、历史记录、Live Activity、配对及本地 VPN 功能保留。

## 设置和定位

打开 App 可以先浏览。点击“开始设置”后直接进入设备设置，不出现 VIP 页面，不请求网站授权。配对、开发者模式、VPN 和系统权限继续按照原有连接流程处理。进入后台、替换配对文件或本地连接变化时，仍保留任务取消及连接失效处理。

原有 `VipLocationGate` 与定位通道里的商业 UDID 读取已删除。定位命令继续由本地连接状态、配对记录和 WLOC 测试互斥规则约束。暂停、停止、恢复真实位置不再受商业许可到期影响。

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

主包不再携带 `PikminNativeVIP` 标记，也不消费 `wowvip.plist`。给此 App 生成个人签名包时应关闭 `vip_check_enabled`，避免签名服务重新注入旧商业验证库。更新原始 IPA 后应使旧签名缓存失效，核对新包确实来自 0.1.9。

`free_guard_enabled` 是企业共享包的独立到期控制：保留为 true 会注入不绑定 UDID 的企业包有效期检查；若要求企业包也无这类运行时检查，应单独关闭。本次源码修改不改变后端开关，也不自动发布安装包。

## 验证

运行 `Tools/test-pikmin-runtime.sh` 验证真实会话控制器、坐标解析和内置 DDI；DDI 测试使用仓库中的真实 8 个资源。`Tools/verify-pikmin-helper.sh` 构建 App 与测试目标；Release archive 打包后还需核对主 App 的两套文件、哈希和两个扩展。

主机测试、编译和包内检查不能替代真机配对、VPN、定位、Apple 个性化及 DDI 挂载测试。
