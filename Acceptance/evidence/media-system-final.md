# 原生媒体、网络和 iOS 系统集成复核

固定来源 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。media-system-signoff.json 逐项列出原始操作而非单独声明存储键；例如 CDN 取 getCdnUrl，图片菜单取 _showMenu，PiP 取原版 restoreUserInterface 回调。真实系统账户、地理网络和物理显示效果没有列作这轮的离线测量。

| 核查域 | 实际行为与修复 | 可复核依据 |
|---|---|---|
| 视频、声音和直播质量 | 按当前网络分别读默认/蜂窝设置；选实际响应内且本设备支持的轨道。Hi-Res 与两种 Dolby 有语义优先级，不把音质 ID 数字当音质排序；编码尝试遵循 AVC/HEVC/AV1/DVH1 顺序。直播默认/蜂窝 qn 与本次手动选择分开 | MediaSystemCheck、PortBehaviorCheck、[只读匿名画质对照](public-playback-quality.md) |
| 21 个点播线路和测速 | 官方主地址、备用、普通镜像及带独立签名的特殊线路区别选择。真实样片最多探测 256 KiB，拒绝、忽略范围或长度不符不显示虚构速度。当前视频样片与最初视频角色绑定，每次探测前后复核；切换角色不能沿用旧 URL。无法索引的渐进 MP4 回落到 MediaLoader 时，也在范围读取和缓存命中处校验旧视频身份 | MediaSystemCheck、vod_probe.py 的 HTTP 回环验证真实字节、短 EOF、拒绝、错误长度、取消；DashBridge 和渐进源权利门按同一角色 |
| 代理、TLS 和重试 | HTTP CONNECT 作用于接口、缩略图、图库原图与实况视频的新连接，重建图库会话不会附加账户 Cookie。允许的平台和网站证书验证始终执行；个人服务受精确来源、已核实的证书、主机与有效期约束。请求不可重放时不因超时重试 | secure_network_loopback.py 使用临时 CA、客户端及本地代理：h2/HTTP1.1 协商，拒绝 4 个信任错误，1 次直连 REST、4 次代理 DAV，条件写未重放；没有安装系统证书 |
| 直接播放、硬解拷贝、软件解码和输出 | 单独关闭硬解时不把解码器拒绝解释为可直通；保留支持的编解码能力和动态 HDR/受保护样本拒绝条件。渐进、DASH 与直播分别有真实字节处理；不能把车载/桌面/Android 驱动名当 iOS 选项 | native_decode.py 与 live_decode.py 读取合成 AVC/HEVC/AV1 等真实流；音画时间戳、向中段跳转、损坏/受限样本、直播分片/重连/独立音轨与压缩音频核验结果见[原生解码](native-decode.md)和[直播解码](live-video-decoder.md) |
| 音频、时钟、超分 | filter、fallback 和增益用生产滤镜和媒体时基验证，保留声道和不可降级的对象音频；显示/音频同步按各模式实际调整画帧与 PCM。Anime4K 两种预设与上游着色器对比，不将 CPU 参考跑分冒充 iPhone GPU 性能 | audio_segments.py、presentation_timing.py 和 anime4k.py；96 kHz 双声道 300% 增益保留声道与削波边界；10 组超分产物 15–48 个阶段，RGB 最大差约 0.004883 |
| 图片菜单、图库和系统文件 | 缩略图和大图共用 GalleryActions。分享的是实际原文件，支持单图/全部、原始实况；“静默”只隐藏保存进度，保留成功/失败，分享仍有加载状态。保存到相册只申请添加权限；拒绝时提供打开系统设置，实况在下载前检查。选 Files 目录不需要相册权限，使用安全范围书签、重名保护和统一的 JPEG/MOV 对。图库站内无签名公开图片可使用独立系统缓存，签名和受限响应不落该共享缓存 | StorageLocationsCheck 使用临时目录测重名、成组发布、中断与窜改；ArticleBodyCheck、MediaSystemCheck 对 URL、媒体组和缓存条件；[图库和 PhotoKit 配对说明](media-gallery.md) |
| 横屏图片预览 | 原版 image_grid 限定视频、动态详情和专栏，横屏的小部件并不等价于缩略图本身的 size class。现在由 PlaybackPanels 和 ReadingSplit 按实际窗口几何提供图库面板，视频/正文继续显示，竖屏和其他入口仍正常导航，关闭面板回到原内容 | 两处布局、GalleryLink 和 GalleryRailPanel 同轮定点 iOS SDK 核查 |
| PiP、AirPlay 与 DLNA | 系统播放控件可手动进 PiP，也可启用内嵌播放自动进窗。正式进入、返回原视图、启动失败、AVPlayer 被替换、用户在后台关闭和后台继续播放分支明确分开；返回时检查真实挂载的系统播放器。只在用户关闭当前后台 PiP 且禁止后台播放时主动暂停。AirPlay 用系统选路器与实际音频/视频路由；DLNA 独立发现、遥控和授权 | MediaSystemCheck 覆盖 16 个与所有者/后台/恢复/继续播放相关的组合。cast_receiver.py 实际交换 87 组本地 SOAP；逐字节验证 2.6 MB 普通读取及 2.2 MB seek 的回环 relay、撤权、重连和换机。AirPlay 未伪造接收器，系统浮窗与投屏手感需要实机 |
| 不适用与跨域 | badCertificateCallback 已补为默认关闭的“允许无效证书”显式开关，接入实际传输与备份；Android audioOutput 驱动及旧安卓 loudnorm 适配不算 iOS 原生驱动。直播弹幕 TCP、键盘、离线管理界面和系统音频中断的专门账本仍归本身领域 | 所有对应行保留具体平台/服务条件，证书策略详见 http-transport-trust.md |

本附件入口是 bash Checks/media_system.sh，每条 JSON 上游符号在固定 Git 修订中复验，Native-only 快照至少复验 Swift 消费处。所有行为测试只用合成媒体、临时目录或回环地址，当前 iPhoneOS 27.1 SDK 的定点检查覆盖这些变更
