# 接口协议与自托管证书

固定上游：`d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`

- `lib/utils/storage_pref.dart`：`enableHttp2`、`badCertificateCallback` 均默认关闭
- `lib/http/init.dart`：前者选择通用 Dio 的 HTTP/1.1 适配器，或 HTTP/2 加 HTTP/1.1 回退，可复用连接；`lib/services/download/download_manager.dart` 单独使用 `Request.http11Dio`
- `lib/main.dart:_CustomHttpOverrides`、`lib/http/init.dart:_createPool`：后者、调试配置或手动代理在指定路径允许任意不可信证书。原生版提供同义的显式“允许无效证书”开关，默认关闭，不因调试或代理自动启用

## 允许无效证书

- 入口：设置 → 网络连接 → 接口连接 → 允许无效证书；原生键 `network.allowInvalidCertificates`，原版备份键 `badCertificateCallback`，布尔值，双向导入导出。恢复备份仍走现有用户确认流程
- `ServerCertificatePolicy` 只在此键为 true、认证方式为服务端信任、有 `SecTrust` 且首次挑战时返回 `URLCredential(trust:)`。HTTP Basic、客户端证书和重复失败挑战仍交给默认处理；关掉开关后新的认证挑战回到系统验证
- `CertificateSessionDelegate` 同时处理会话与任务挑战。普通 REST、gRPC、二维码与登录验证、图片/实况素材/时间轴、字幕、歌词、直播 WebSocket、FLV/HLS、Range 媒体、后台离线下载、投屏描述与媒体中继、短链及版本查询的实际会话均接此策略。私有 WebDAV/SponsorBlock 的独立代理先判断同一显式开关，关闭时继续原来的单源锚点验证
- 严格 HTTP/1.1 的 `HTTP11Job` 在显式开启时给 Network.framework TLS 安装 verify block。WKWebView 的站点浏览/网页登录通过导航认证回调接入；直连直播及手动媒体 AVURLAsset 通过 `AVAssetResourceLoaderDelegate.shouldWaitForResponseTo` 公开认证回调接入。已有通过 RangeTransport 的点播、音频和解码桥继承同一策略，本机文件与 localhost 中继不涉及远端证书
- `Info.plist` 的 `NSAllowsArbitraryLoads` 允许应用处理这些挑战；默认关闭时 URLSession/WKWebView/AVFoundation 继续默认信任处理，Network.framework 继续系统链验证。没有安装系统根证书或修改设备设置，重定向、账号校验、Cookie 隔离、范围与正文限制保持原规则

## 普通接口与代理

入口：设置 → 网络连接 → 接口连接 → HTTP 协议。原备份 `enableHttp2` ↔ `controls.flags.network.negotiateHTTP2`，布尔值，默认 false

| 选项或路径 | 实际行为 |
| --- | --- |
| HTTP/1.1 | 账号/普通 REST 请求走 `BiliServiceSession → HTTP11Proxy → HTTP11Job`；使用 Network.framework TLS + TCP，最低 TLS 1.2，目标主机 SNI，正常服务端验证，ALPN 只提供 `http/1.1`，实际编码 HTTP/1.1 请求行和消息；服务端不选 ALPN 也可处理 HTTP/1.1 |
| 自动协商 | 同一来源、同一账号角色及同一代理配置的临时 URLSession，协议由系统和服务器协商，不承诺只使用 HTTP/2 |
| 移动接口 gRPC | `mobileCall` 的 `application/grpc` 始终使用现有的系统协商通道，保留原来的 gRPC 数据帧、状态解析、账号授权与只读重试 |
| 登录 | 网页/Cookie 登录后的 nav 校验和二维码申请/轮询使用同一协议偏好；扫码的多条 Set-Cookie 分别解析，带 Expires 的逗号不拆包。登录网页本身由 WKWebView 加载 |
| 代理 | 手动接口代理用 HTTP CONNECT；未设手动代理时用 CFNetwork 读取系统对目标 URL 的首选 DIRECT/HTTP CONNECT/SOCKS5 规则，支持内联和 URL PAC。PAC 超时或尚不支持的规则会失败，不自动绕开代理。目标 Cookie 和 Authorization 在 TLS 隧道内部；不把 Proxy-Authorization 转发给目标 |
| 完整性 | 严格解析固定长度、分块及关闭定界，处理临时状态、HEAD、204/205/304、分段接收，响应正文上限 32 MiB；协议请求 identity 编码。一次请求一条连接，使用 Connection: close，协议选择即时生效 |
| 权限与重定向 | 原账号角色/设备 ID 生成和重试前的账号验证保持在请求方；普通接口不使用 Cookie 存储。读请求仅同 HTTPS 主机同端口重定向；写方法、带反馈或登录副作用的 GET 不重定向，不会借重连重复写。诊断只记原有路径和错误码 |
| 系统传输边界 | 后台离线下载保留 `URLSessionConfiguration.background` 的系统续传，播放器、CDN、图片、直播套接字、网页以及独立的 WebDAV/SponsorBlock 服务不套用 REST 协议偏好。iOS 没有给 URLSession 后台任务指定“强制 HTTP/1.1”的公开配置；这里与 Dio 下载器不同。严格模式也没有照搬上游的连接池/压缩传输 |

[Apple 的 URLSession 文档](https://developer.apple.com/documentation/foundation/urlsession) 和本地 iPhoneOS 27.1 SDK 的 URLRequest/URLSessionConfiguration 公共接口用于确认协议协商边界

## 私有证书

- 设置 → WebDAV → 填写 HTTPS 地址 → 服务器证书；空降助手 → 填写自定义 HTTPS 服务地址 → 服务器证书。用户选择单张 X.509 DER/PEM（128 KiB 以内），界面显示类型、到期日、SHA-256，确认才生效，可替换或移除
- `PrivateServiceOrigin` 按**服务种类 + 完整主机 + 端口**区分。证书存在 `PiliNative.PrivateTLS` 的本机 Keychain 项，非同步、解锁可读，不写 UserDefaults，不进入设置导出。独立的全局允许开关按上述原版布尔键备份
- 在全局允许开关关闭时，对配置好的这个私有来源保留原信任策略并加目标主机的 SSL 策略，只信任导入锚点，调用 `SecTrustEvaluateWithError` 验证签名、用途和证书链。所有链成员均须在有效期内；叶证书必须有匹配 DNS/IP 的 SAN。导入叶证书时还需匹配同一张 DER。导入 CA 时可更新服务器证书，只要新证书仍满足同主机、有效期、用途和同一条受信任链。单标签 DNS 通配符不会匹配多级子域
- B 站账号、API、官方 CDN、默认公共空降助手服务均不能设置私有锚点。认证 B 站会话从不安装私有信任代理；自定义空降助手/API 不共享 B 站 Cookie，WebDAV 仅使用该地址与用户名自己的 Basic 凭据
- 自定义证书不会安装到 iPhone 系统，也不会跟随 WebDAV 重定向；WebDAV 拒绝重定向。空降助手的读请求仅同源跳转，写请求不转发。有效期过期、换主机、换端口不会延续原授权

信任策略依据 [Apple 的 SecTrust 配置](https://developer.apple.com/documentation/security/configuring-a-trust)、[限定锚点](https://developer.apple.com/documentation/security/sectrustsetanchorcertificatesonly(_:_:)) 和[按主机校验 TLS 的 SSL 策略](https://developer.apple.com/documentation/security/secpolicycreatessl(_:_:))

## 实测

`cd Native && python3 Checks/secure_network_loopback.py`（swiftc、Python 标准库、OpenSSL；所有监听只绑定 127.0.0.1；临时证书测试后删除）

- 同一个 TLS 服务器实际协商到 h2 或 http/1.1；无关 CA、错误的请求主机、服务端错误 SAN、过期叶证书四种 TLS 握手全部失败
- 生产 Swift HTTP 编解码器经本机 TLS 发出一条确切的 HTTP/1.1 普通请求；生产 `DAVStore` 经本地 CONNECT 隧道完成 PROPFIND → GET → 带 If-Match 的 PUT → GET 读回。服务器校验模拟 Basic/Cookie、代理未收到这些字段。无真实账号或服务写入
- Swift 另外验证了独立 Cookie（含 Expires）、gRPC 的协议选择、同源 GET 与禁止写重定向、跨端口/域名保护、反馈 GET 不重试、分片/截断/超限/冲突长度、SAN 的域名/IP/通配符、受保护主机、证书有效期以及 WebDAV/SponsorBlock 授权相互隔离
- 2026-11-13 增量检查使用生产 `ServerCertificatePolicy.acceptsChallenge`，验证默认关闭、显式开启、非服务端认证/无信任对象/重复失败挑战不豁免、关闭恢复；生产备份映射检查 true 的导入/导出与错误类型拒绝。测试只使用临时 UserDefaults，未启用本机真实设置
- 使用 xtool 的 iPhoneOS 27.1 SDK，将上述网络、网页、原生媒体及设置实际消费者一起以 `arm64-apple-ios17.0` 独立通过 swift-frontend typecheck。主机回环 TLS 由 OpenSSL 提供，Apple Network.framework、AVFoundation、WKWebView、Keychain 与系统 PAC 的实际行为保留真机联调
