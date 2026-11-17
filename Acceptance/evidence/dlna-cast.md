# DLNA、交回手机与 AirPlay

基线：PiliPlus 2.2.0.2。应用入口是 `lib/pages/video/controller.dart:onCast` → `VideoHttp.tvPlayUrl` → `lib/pages/dlna/view.dart`。原页面搜索 20 秒，刷新可重新发现，连接时设置节目标题和播放 URL，再请求 Play；换机前原版请求旧设备暂停。原页面不显示音量和进度条。固定依赖 [dlna-dart fe347512](https://github.com/suconghou/dlna-dart/blob/fe347512768400a4309dd73269f104ba65668f07/lib/dlna.dart) 含 SSDP、播放状态和位置轮询、RenderingControl 控制；这条调用链没有 GENA 事件订阅

| 操作 | 原生路径与边界 |
|---|---|
| 找电视 | 用户打开投屏页才搜索。SSDP 在本地 Wi-Fi/以太网接口发送 M-SEARCH，收集响应与 alive/byebye，20 秒后结束；可刷新，也可手动输入本地 XML 描述地址。重复响应合并，已经离开的设备即使描述请求稍后返回也不会重新出现。支持 HTTP 的 .local 名字解析到同一发布主机和手动本地 IPv4/IPv6 地址；HTTPS 仍用系统证书检查，不接受跨主机服务 URL 与 HTTP 重定向。组播发现是 IPv4 |
| 播当前视频 | 普通视频以 aid、cid、qn 和类型 1 查电视投屏；番剧以 ep_id、cid、qn 和类型 2 查。req 含 is_proj=1，账号依据视频服务角色。只有服务端返回的完整投屏源可用，试看、DRM、受限访客、无投屏地址或分段非整片均不会发给电视。原版对多 durl 只取第一段，本版不会把首段当整个节目。课程、直播没有使用本接口 |
| 授权 | 使用 /x/tv/playurl 的投屏授权，不拿下载或普通播放接口充当投屏授权。应用不内置上游私有签名凭据。若发行方另有自己的应用授权，可预置于本应用 Keychain 内，默认仓库没有此配置。服务拒绝会显示服务错误，本地网络权限和电视返回的 SOAP 错误分别处理。未在真实服务验证当前发行包能否取得投屏许可 |
| 交接与控制 | 两端收到有效 SetAVTransportURI / Play 回执后才切换本机会话。同片保留进度、换节目从新片本地进度开始；设备拒收时保留旧会话；同一设备换片失败时先核实 URI 再恢复旧片。播放、暂停、跳转、剩余时长使用 AVTransport；音量/静音先读设备实际状态，再按 SCPD 的最小值、最大值和步长写入 Master 通道。两秒轮询，额外状态约六秒一次；按协商能力显示操作，无 SCPD 时可尝试标准操作，收到不支持回执则禁用对应读取 |
| 断开与交回 | 连续两次读取失败标记失联，保留当前节目和已知进度以便手动重连。停止或交回手机先核实电视还在播放本会话 URL；进度通过 TrackURI 或 CurrentURI 校验。电视已换片则结束本机中继，不向新节目发 Stop。明确断开只关闭本机连接。失联回来可以从最近的进度恢复原先的 AVPlayerItem；若已打开别的视频会提示回到原视频。账号/角色变化立即结束中继 |
| TV 侧读媒体 | 在通向所选接收器的实际接口绑定随机端口和独立 URL，校验每条连接的来源地址和路径。电视只获取该节目的本地流，收不到 Cookie、源地址或签名参数。GET/HEAD、206/416、后缀范围、媒体类型和 DLNA 响应头经实际回环 HTTP 验证。配额为 8 条连接，每个远端 Range 最多 1 MiB；读之前和返回之前复核授权。只有正常线路故障且总长度相等可换镜像，401/403/412/429 立即停止。连接撤销/到期清理，不制作可导出的媒体文件 |

原版直播模块没有独立 DLNA 调用，全 `lib` 的 `/dlna` 与 `onCast` 路由来自点播播放器，未找到项目自定义 AirPlay 操作。原生点播页提供 [AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview)，区分 AVPlayer 的外部视频状态和 AVAudioSession 的 AirPlay 音频路由。直播使用系统播放器的路由能力；它没有将 FLV、带签名的直播 URL 或本机 127.0.0.1 桥暴露到局域网。能否外放图像取决于接收端、媒体格式和内容授权；未以音频路由出现代替投放视频成功

iPhone 自动发现有两个独立条件：[本地网络隐私授权](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)与 Apple 分配给签名团队的[网络组播 entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast)。Info.plist 包含用途说明及本地 HTTP 范围例外；entitlements 模板请求组播；已有 signed IPA 验收会检查签名程序和描述文件中的 entitlement。手动 XML 连接没有 SSDP 依赖，但仍需本地网络授权。AirPlay 使用系统路由选择器

验证：

- WSL `python3 Checks/cast_receiver.py`：仅用 127.0.0.1 的模拟 SSDP 与两台模拟 AVTransport/RenderingControl v1/v2 接收器，真实 UDP/HTTP/XML。87 次 SOAP 交换覆盖发现/离开、标题转义、真实状态、0…255 步长 5 的音量、跳至 83 秒、静音暂停与恢复，两设备交接、换机被拒时保留旧会话、同设备换节目失败恢复、重连、77 秒及失联后 60 秒交回手机、两种 URI 检测电视换片，未对其他节目发 Stop
- 同一检查启动原生中继 HTTP 处理和真实 RangeTransport，比较 2.6 MB 全文件和 2.2 MB 跳转范围逐字节相同；HEAD、后缀、416、405、错误路径、失效令牌/账号与镜像用例通过。`python3 Checks/vod_probe.py` 额外复核源长度变更、线路错误，以及 403 后不访问备用地址
- iPhoneOS arm64 SDK 对本组 Swift 源、两个内容入口及其项目依赖进行针对性类型检查，无错误。没有操作真实局域网、订阅、账号、Apple TV 或电视；物理网络权限弹窗、正式应用电视接口授权、接收器兼容性、iPhone 锁屏挂起时的持续转发与 AirPlay 外部画面仍需真机验证
