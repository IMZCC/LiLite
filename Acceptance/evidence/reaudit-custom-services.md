# 自建 WebDAV 与空降助手复核

日期：2026-11-13
固定上游：PiliPlus `d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`
复核基线：本地 `daa2ea629cc15584ebcad032c7275424dbc4700f` 加本轮未提交原生移植修复
范围：普通用户自建服务的地址、传输、认证、备份和证书入口

## 上游实际行为

- WebDAV 的 [webdav.dart](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/d9e9626f1a3f89cd9ca85e18f61aaba02634e12a/lib/pages/webdav/webdav.dart#L30) 直接把保存的地址和该服务器的用户名、密码交给客户端；[view.dart](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/d9e9626f1a3f89cd9ca85e18f61aaba02634e12a/lib/pages/webdav/view.dart#L132) 保存用户输入，没有 HTTPS 限制
- `pubspec.lock:1952–1960` 固定 `webdav_client` 1.2.2、提交 `2f669c98fb81cff1c64fee93466a1475c77e4273`；其 [webdav_dio.dart](https://github.com/wgh136/webdav_client/blob/2f669c98fb81cff1c64fee93466a1475c77e4273/lib/src/webdav_dio.dart#L78) 同时接受 HTTP 和 HTTPS，并在 88–134 行提供 Basic、Digest 认证及失效 nonce 更新
- 空降助手 [sponsor_block.dart](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/d9e9626f1a3f89cd9ca85e18f61aaba02634e12a/lib/http/sponsor_block.dart#L54) 在保存的服务器地址后拼接 `/api/`；[设置弹窗](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/d9e9626f1a3f89cd9ca85e18f61aaba02634e12a/lib/pages/sponsor_block/view.dart#L307) 接受输入并支持恢复默认地址；[默认值](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/d9e9626f1a3f89cd9ca85e18f61aaba02634e12a/lib/http/constants.dart#L16) 为 `https://www.bsbsb.top`

结论：原生版额外施加的 HTTPS 限制、缺少 Digest 以及缺少服务器重置动作均属于可实现的功能差异

## 已修复的操作链

| ID | 严重度 | 原问题 | 本轮结果与代码证据 |
| --- | --- | --- | --- |
| CUSTOM-01 | P2 | WebDAV 输入和 PROPFIND 文件解析只允许 HTTPS | `Network/SelfHostedServiceURL.swift` 统一解析 HTTP/HTTPS，保留 LAN、IPv6、显式端口和路径；`Settings/WebDAVStore.swift` 的 `DAVLocation`、请求边界与 `managedURL` 共用该规则；相对 href、完整同源 href、显式默认端口别名均返回受管文件 |
| CUSTOM-02 | P2 | 空降助手服务地址和备份校验拒绝 HTTP | `Playback/SponsorAPI.swift`、新 `SponsorAPIRequest.swift` 与 `NativePrefs.validate` 接入同一规则；状态、读取片段、写入片段、反馈等继续共用实际请求入口；`BackupFormat` 的 `blockServer ↔ sponsorServer` 映射和通过 `DAVLocation` 校验的 `PackServerProfile` 保留 HTTP 地址 |
| CUSTOM-03 | P2 | 原生 WebDAV 仅发送 Basic，Digest-only 服务器无法使用 | 新 `Network/SelfHostedHTTPAuthentication.swift` 支持专属 URLSession 的 Basic/Digest challenge，并为直接返回 401 的传输生成 Digest；`PrivateServiceDelegate` 增加 task challenge 回调，`DAVConnection.withStore` 处理有界 nonce 更新；支持 MD5、MD5-sess、SHA-256、SHA-256-sess、auth、auth-int 和 qop 缺省 |
| CUSTOM-04 | P3 | 空降助手服务器无法一键恢复上游默认值，界面把地址标成 HTTPS | `SponsorSettings` 增加“恢复默认地址”，共用 `SponsorAPIRequest.defaultServer`；WebDAV 与空降助手使用“服务器地址”“服务地址”，新标签与动作通过现有生成管线进入设置搜索 |

## 边界与兼容性

- 同源仍要求协议、主机和有效端口相同，HTTP 默认 80、HTTPS 默认 443；切换协议不是同源，显式 HTTP 443 也不是 HTTP 默认端口
- WebDAV 仍只接受受管文件及目录，拒绝越界、路径遍历、嵌入凭据、查询串和片段；条件写入、版本冲突、快照与恢复事务保持原路径
- WebDAV 使用专属服务器用户名和密码，Keychain 保存范围未扩大；Basic/Digest challenge 与手动 401 重试都限定该 origin，Digest 的普通认证失败不继续重放，失效 nonce 最多额外更新一次，认证响应体上限 16 KiB
- 两类服务继续使用无 Cookie、无共享 URLCredentialStorage 的独立会话；Sponsor 请求不携带 B 站 Cookie 或账号 Authorization
- WebDAV 继续拒绝自动跳转；Sponsor 仅允许同源 GET/HEAD 跳转，写操作不重放
- 现有 `PrivateServiceOrigin` 仍只描述 HTTPS 证书域，HTTP 没有 X.509 challenge 或证书设置入口；HTTPS 的系统信任、自定义证书和全局 `ServerCertificatePolicy` 按原有顺序处理，未替换全局 TLS 策略
- 默认空降助手地址保持 `https://www.bsbsb.top`；恢复默认动作回到该地址并沿表单的“保存”生效

## 验证记录

所有命令在 `Native` 目录、WSL `SwiftUI-Noble` 的 Swift 工具链执行

1. 现有 `BackupCheck.swift` 单独编译运行：PASS，覆盖 HTTP/HTTPS 默认端口、LAN 8080、IPv6、相对及绝对 PROPFIND href、JSON 直连地址、异源拒绝、写操作跳转拒绝、实际 Sponsor 请求构造及原有字段迁移和条件写入
2. `python3 Checks/backup_recovery.py`：PASS，原真实 HTTP URLSession 请求不再通过测试替换协议；执行 WebDAV Basic 读写、版本保护、相对/绝对 href 去重、加密快照及恢复；6 组 Digest 服务使用独立 Python 哈希校验生产签名，分别为 MD5、MD5-sess、SHA-256、SHA-256-sess、auth-int、stale nonce 更新；额外验证普通失败不重试、异主机/异协议/异端口不签名；HTTP Sponsor 状态、片段 GET、片段 POST 均成功且服务器核对无账号凭据；保留原 Python/Swift 密码互通及回滚校验
3. `python3 Checks/secure_network_loopback.py`：PASS，保留 HTTPS 证书和 origin 隔离、HTTP 分帧、有真实响应的 TLS REST 与 CONNECT WebDAV 条件读写；ALPN h2/HTTP1.1、4 条信任拒绝、1 条直接 REST、4 条隧道 DAV 请求通过
4. `bash Checks/setting_search.sh`：PASS，生成管线核对 317 个真实控件锚点、145 条同义词/值索引、170 项固定上游设置；新增锚点 `SponsorSettings/恢复默认地址`，地址锚点改为 `SponsorSettings/服务地址`
5. `python3 dist/custom-services-sdk.py`：PASS，相关生产文件通过 arm64 iOS SDK 定点类型检查，包含 UI、认证 delegate、备份、Sponsor 与服务器配置导入路径
6. 本域 `git diff --check`：PASS

没有新增独立测试套件，协议认证与事务行为扩展现有回环；简单界面按钮复用既有设置搜索检查

## 真机范围与交付边界

这份报告结清本轮自建服务差异，整仓最终收据由根任务统一捕获

仍交给最终 iPhone 验收的部分为：局域网权限提示与 LAN 实际连通、URLSession 原生 Basic/Digest task challenge、HTTP 下隐藏和 HTTPS 下显示证书入口、表单保存与恢复默认地址的交互；本轮回环在主机 URLSession 执行同一生产 URL/认证/存储组件，iOS 专属 Security 与 SwiftUI 路径已经 SDK 编译但未在此轮签名安装
