# iOS 双播放内核

点播默认使用 libmpv 0.41.0，同时保留 AVPlayer 原有播放路径。设置键为 `player.engine`，取值 `mpv` / `avplayer`，未设置时为 `mpv`

## 选择内核

- 设置 → 播放 → 播放器内核
- 设置 → 画面与音轨 → 播放器内核
- 视频右上角更多设置 → 播放 → 播放器内核
- 全屏播放面板、番剧／课程播放工具也提供同一入口

内核在 `PlayerModel` 创建时确定，当前详情页及该页的选集／连续播放沿用同一内核。重新进入视频页后应用新设置，避免播放中更换渲染资源

## 结构与调用路径

`PlayerModel.engine` 是 `PlaybackEngine` 协议，AVPlayer 通过协议扩展实现，mpv 由 `MPVPlayer` 实现。原来的 AVPlayer 保留为 `PlayerModel` 的私有成员，只有 AVPlayer 路径使用 `DashBridge`、`MediaLoader`、`LegacyDURLPlayback`、`AVPlayerItem` 及其观察者

mpv 路径为：授权播放信息 → 清晰度／音质／语言选择 → 视频 CDN URL + `audio-files` → `CMPV` → libmpv。普通 MP4 直接打开；旧版多片段 DURL 使用 mpv EDL 拼接，维持整片时间轴。CDN 候选失败时按有限的备用地址列表重试，换清晰度和音轨保留播放位置与暂停状态

`PlayerModel` 继续管理 `seconds`、`duration`、`playing`、`ready`、`rate`、seek/quickSeek、字幕、弹幕分段、空降／片头片尾、播放记忆、云端心跳、互动视频结束、循环和续集。界面通过协议操作暂停、倍速、音量、时间、缓冲和画面尺寸。AVPlayerViewController、AVSynchronizedLayer 等系统专用组件仅在 AVPlayer 适配边界使用

## 线程、渲染与长按倍速

- `MPVCore` 的专用后台队列执行 mpv 命令和事件循环，观察 `time-pos`、`duration`、`pause`、`speed`、`paused-for-cache`、`demuxer-cache-time`、尺寸及 EOF
- 每轮最多处理 256 条事件；普通状态快照每 100 ms 合并一次，主队列待处理区只保存最新快照，避免积压
- `MPVRenderer` 在独立串行队列维护 EAGLContext，使用 `MPV_RENDER_API_TYPE_OPENGL` + CAEAGLLayer，VideoToolbox 帧由上游 `ios-gl` 路径导入。渲染回调只唤醒合并后的任务，不同步调用 SwiftUI
- 全屏过渡沿用原有动画；一个 mpv render context 可给过渡期间的多个 drawable 输出同一画面。比例、拉伸、裁切、镜像和缩放继续使用原界面选项
- 长按和键盘临时倍速写入 mpv `speed`；松手、取消手势、切换媒体或离开页面后恢复默认速度。命令从主线程投递到后台队列
- `PlayerModel` 采样保持固定墙钟频率，`PlaybackProgress` 和进度条最多每 250 ms 普通更新一次。弹幕行按 250 ms 接纳／回收，Core Animation 的父层时钟跟随 mpv 时间和速率，缓存暂停时停止移动
- seek 带媒体身份和请求标识，等待播放重启并检查目标位置，旧请求不能结束新请求；错误、停止及超时会释放等待者
- 非活动状态释放 GLES 资源，有画中画会话或自动进入等待时切换软件 render context 与 VideoToolbox-copy，继续输出小窗画面；普通后台收听关闭视频轨道。恢复前台重新创建 GPU context，并重选视频轨、按播放时钟对齐进度。后台播放开关、音频中断、拔耳机暂停、回前台恢复和睡眠定时器均接到统一控制接口

## 与 Flutter 原版的配置对应

当前 Flutter 源码的 `lib/plugin/pl_player/controller.dart` 使用 media_kit/libmpv，并已使用 EDL 组合音视频。本次按任务指定用 `audio-files` 传独立音轨，通过 mpv node 数组传递，URL 中的冒号和逗号不会被当成分隔符

| 原版／功能 | 原生 mpv 对应 |
| --- | --- |
| `hwdec` | 默认 `videotoolbox`；设置关闭硬解时 `no`，拷贝选项映射 `videotoolbox-copy` |
| 请求头 | 桌面浏览器 User-Agent + 当前视频 Referer，对视频和外部音轨均生效 |
| 缓冲 | `cache=yes`、`cache-secs`、`demuxer-max-bytes`、`demuxer-max-back-bytes`，读取原生现有缓冲设置和内存上限 |
| 倍速 | `speed` + `audio-pitch-correction=yes`，暂时倍速不覆盖默认速度 |
| 起播／跳转 | `loadfile` 的 `start` 和 `seek absolute+exact` |
| 同步 | `play.videoSync` 映射 `video-sync`，默认 system 映射 audio；`play.autosync` 映射 autosync |
| 音量与均衡 | `volume`、`mute`、现有音量均衡链通过 `af=lavfi=[...]` |
| 仅音频 | `vid=no`，恢复画面为 `vid=auto` |
| 截图／动图 | `screenshot-to-file` 输出 PNG；动图沿用限时、限帧率的 GIF 生成与保存界面 |
| Anime4K | 使用 `assets/shaders` 原版效率／画质 GLSL 链，随应用打包；AVPlayer 保留 Metal 实现 |

## 功能与限制

| 功能 | mpv | AVPlayer |
| --- | --- | --- |
| UGC／番剧／课程、分离音轨、切画质／语言 | 直接播放 | 保留本地桥接 |
| 倍速、进度、字幕、弹幕、心跳、续集 | 共用业务接口 | 共用业务接口 |
| 截图／GIF、全屏动画、键盘／手势、超分 | mpv 实现 | 原实现 |
| 锁屏／控制中心、后台音频、睡眠定时 | 保留 | 保留 |
| 手动／自动画中画 | Sample-buffer PiP | 保留 |
| AVPlayer 系统视频控件 | 使用应用控件 | 保留 |
| AirPlay 视频 | 禁用入口 | 保留 |
| 系统音频输出／音频 AirPlay | 可选音频设备 | 保留 |
| DLNA 投屏 | 顶栏／菜单进入投屏页 | 同一投屏页，另有隔空播放入口 |
| 直播、离线文件播放器、听视频队列 | 本次保持原 AVPlayer 路径 | 保留 |

mpv 的系统音频选路继续保留，视频 AirPlay 使用 AVPlayer。两种内核的顶栏“投屏”均为 DLNA，不再用 AirPlay 选择器替代

当前 mpv drawable 为 RGBA8，HDR/Dolby Vision 内容走 mpv 的显示转换，尚未实现 EDR/HDR 元数据直通。需要系统 HDR 输出时可切 AVPlayer。iOS GLES 已被 Apple 标记为弃用，此处使用 mpv 上游现成的 iOS VideoToolbox/OpenGL ES 实现；没有引入未经实现的原生 Metal render API

## mpv 画中画

参照完整的 `ios/Runner/PipPlugin.swift` 和 `lib/utils/ios/pip_helper.dart`，原生实现分为 `MPVPiPSession`、`MPVPiPFrames`、`MPVPiPPolicy`，由每个 `MPVPlayer` 持有会话

- 前台仍由现有 GLES renderer 上屏。在 `presentRenderbuffer` 丢弃 drawable 之前，ES3 使用 `glBlitFramebuffer` 复制同一画面到 `CVOpenGLESTextureCache` 支撑的 FBO，按 CVPixelBuffer 顶部扫描线方向翻转；ES2 后备路径向缓冲 FBO 再渲染一次
- 缓冲由独立的 BGRA／IOSurface `CVPixelBufferPool` 分配，最长边不超过 1920，并按 PiP `renderSize × screenScale` 缩小。每个样本持有自己的缓冲，分配阈值为 4，池满跳过供帧，不回写显示层仍在使用的画面
- 小窗未打开时每 0.25 秒预热一次，打开后随视频帧供给。ES3 复制不再执行第二遍 mpv 着色器，也没有前台 CPU 像素回读
- `CMSampleBuffer` 使用 `DisplayImmediately` 和 host-clock `CMTimebase`；iOS 17+ 经 `sampleBufferRenderer` 入队、失败时 flush，并检查背压。时间基按 mpv 当前时间、暂停／缓冲和速度更新
- `AVPictureInPictureController` 使用 sample-buffer content source，源视图置于窗口根视图后方，保持挂载。小窗播放／暂停、时间范围、暂停状态、尺寸变化、快进／快退全部回调同一个 mpv。设置 `play.autoPiP` 与 AVPlayer 共用，`dm.quietPiP` 同样生效
- 手动启动沿用 Flutter 的启动超时和 `UIControl.sendAction(suspend)` 退到后台方式；返回应用停止小窗并恢复当前播放界面。后台直接关闭小窗时，只有未启用后台播放才暂停；主动停止和恢复界面不作为用户关闭处理。停止播放会关闭 PiP，会话销毁时清空 `contentSource`，解除 AVKit 对播放代理的持有

后台不能继续调用 GLES，见 [Apple OpenGL ES 后台限制](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/OpenGLES_ProgrammingGuide/Introduction/Introduction.html)。因此在 `willResignActive` 返回前完成 GPU 工作并释放 GL context，换成 mpv 的 SW render API。硬解启用时使用 `videotoolbox-copy`，色彩转换／缩放使用 `sws-fast=yes`、bilinear，直接写入小窗像素池，不渲染主界面；关闭硬解时沿用软件解码。恢复前台重建 GPU context 并恢复用户硬解配置

切换过程中不重开 URL、不新建播放器。实际运行检查发现，mpv 0.41 释放 context 后仅再次设置 `vid=auto` 不会恢复视频；`pili_mpv_rebind_video` 明确执行 `vid=no → auto`，再按切换前的播放时钟及已推进时间精确对齐，保持独立音轨同步。这一切换已通过同版本 mpv 的运行验证，GPU／VideoToolbox／AVKit 的表现列入下方真机清单

## DLNA 投屏及局域网权限

复用原生现有 `CastGrantAPI`、`CastDiscovery`、`CastProtocol`、`CastHTTP` 和 `CastSession`，不另造协议栈。顶栏 `PlayerCastButton` 与菜单 `CastButton` 对两种内核均打开 `CastView`；设备列表、搜索进度、刷新和选中状态采用原版 DLNA 页面布局，选中后显示播放／暂停、进度、音量、停止和回到本机的控制。仅 AVPlayer 显示独立“隔空播放”入口

- TV 地址：`/x/tv/playurl`，UGC 为 `playurl_type=1` + aid，PGC 为 `2` + epId，携带当前 cid、qn、`fourk=1`、`is_proj=1`、`protocol=0`，与原版一致使用 `mobi_app=android`、`platform=android` 和 AppSign。登录时携带视频账号的两种 access-key 参数，返回前核对账号仍相同
- 只接受完整单文件 DURL，保留试看／DRM 授权检查及 CDN 线路选择，支持 TV 服务返回的 HTTP／HTTPS。和 Flutter 一样把 TV URL 直接交给接收端，不依赖手机持续运行本地媒体转发；原有 relay 模块未删除
- SSDP 请求 `MediaRenderer:1`／`AVTransport:1`，解析设备 XML 的 AVTransport、RenderingControl 服务，使用 SOAP SetAVTransportURI、Play、Pause、Stop、Seek，以及支持的音量／静音动作。保留切设备、状态回读、重连、回本机和 URI 归属检查
- `Info.plist` 已有 `NSLocalNetworkUsageDescription` 和 `_ssdp._udp`、`_upnp._tcp` Bonjour 服务声明，`UIBackgroundModes` 含 audio；正式权限配置含 `com.apple.developer.networking.multicast`
- 本任务的个人开发签名不支持 multicast entitlement，打包脚本只对 staging 移除该权限，并把 `PiliMulticastDiscovery` 设为 false。此包自动搜索使用 Bonjour；“手动连接”可输入电视 IPv4，通过发往该 IP 的 UDP 1900 单播 M-SEARCH 获取设备描述，不加入多播组；不响应单播的设备可填写完整设备描述 URL。仍须用户允许本地网络访问。正式获批多播权限的签名包使用完整 SSDP 搜索

## 构建和产物

```sh
# 在 WSL 的仓库根目录
python3 Native/MediaKit/build-mpv.py
bash Native/build.sh --sign-dev

# 本地生成媒体与 HTTP Range 服务，不使用账号或手机
python3 Native/Checks/mpv_runtime.py
```

指定的 PowerShell 验证入口仍为任务提供的 `fastbuild.sh`。脚本调用现有 `Native/build.sh --sign-dev`，沿用开发签名，不安装设备、不提交 Git

依赖构建方法、固定版本与许可证见 [MediaKit/README.md](MediaKit/README.md)。`build.sh` 导出：

- `Native/dist/MPV/libmpv.a`、`libplacebo.a`：iOS device arm64 静态库
- `Native/dist/MPV/include/mpv/`：上游 C API 头文件
- `Native/dist/MPV/build-receipt.json`：版本、依赖前缀、SDK 与编译选项
- `Native/dist/PiliNative-dev-signed.ipa`：双内核开发签名应用
- `Native/dist/mpv-runtime-check.json`：本地播放验证结果

## 验证记录与真机重点

画中画／投屏修改通过任务指定的 `fastbuild.sh` 完整非 WMO 构建，`exit=0`，IPA arm64 与开发签名检查通过。完整日志为任务 scratchpad 内的 `b.log`，最终副本为 `Native/dist/pip-build-final.log`。未安装到手机，未提交 Git

Linux 上使用同版本 mpv、同一份 `CMPV/PiliMPV.c` 实际打开本机 HTTP 视频与独立 AAC 音轨，服务端要求正确的 Referer 和 User-Agent。验证了 1.5 秒起播、2.5 秒精确跳转、3 倍速、暂停冻结、EOF，以及 8 次重载后没有遗留外部音轨。0.8 秒等待期间的媒体推进记录为 2.208～2.375 秒，最新结果见 JSON。此检查覆盖实际 mpv 客户端行为，GLES／VideoToolbox／AudioUnit 与系统视频功能需要真机操作

现有 `Checks/media_system.sh`、`Checks/player_keys.sh` 和 `Checks/setting_search.sh` 均通过，覆盖 16 种 PiP 关闭／恢复／后台／播放器组合、21 条 CDN 线路规则、键盘与手势状态机、88 条操作对应记录及 312 个设置搜索锚点。媒体验收索引中的旧 PiP 文案和两个旧图库引用已更新为实际代码位置，行为测试保持不变

上述键盘／设置检查属于双内核交付记录；本次重跑 `media_system.sh` 并通过。新增 `Checks/mpv_pip_runtime.c` 使用生产 `CMPV` 桥接和真实视频／独立音轨，检查 SW 帧输出、4 次播放中 context 重建、音轨及位置保留、暂停图像稳定、2.5 秒 seek、3 倍速和连续变化的画面；结果见 `dist/mpv-pip-runtime-check.json`，运行日志见 `dist/mpv-pip-runtime.log`

`Checks/cast_receiver.py` 本次通过本地 UDP 定向发现／NOTIFY、XML、87 次 SOAP 交互、双设备交接、进度与 seek、重连、回本机、外来 URI 保护、UGC／PGC TV 参数及授权规则，另保留旧 relay 的 HTTP Range 回归。日志为 `dist/cast-pip-check.log`。这些检查不请求真实视频账号，也不连接用户的电视

`Native/dist/MPV/verification.json` 记录静态库架构、大小和 SHA256。导出库包含 `ao_audiounit`、`libmpv_gl`、`hwdec_ios_gl` 对象，最终应用资源包含原版 GLSL 链和新增许可文本

Claude 真机验收：

1. 默认 mpv 播放 UGC、番剧、课程各一个，验证 AVC／HEVC／AV1、音视频同步、起播记忆和音轨
2. 连续长按 3 倍速、松手、滑动 seek、双击快进、键盘临时加速；开启大量弹幕及字幕，检查画面、声音和控件是否流畅
3. 连续切画质、音质、语言、分 P／分集；播放末尾自动续集、单集循环、互动视频分支、睡眠定时结束
4. 内联／全屏反复切换、旋转、拉伸／裁切／镜像；截图、GIF、效率／画质超分，HDR 内容颜色
5. 后台音频开／关各验证锁屏、控制中心播放暂停和拖动、蓝牙／耳机切换、来电中断、重新前台恢复
6. 设置为 AVPlayer 后退出重进：DASH 桥接播放、长按、截图／GIF、全屏、字幕／弹幕、手动／自动 PiP、AirPlay 视频及后台播放
7. 直播、离线播放、听视频队列各做一次回归，确认与点播之间的声音接管和恢复
8. mpv 下分别测试手动 PiP、自动 PiP、自动关闭设置；横／竖视频、分 P／换画质、暂停时进入、小窗播放暂停／快进快退／缩放；检查方向、色彩、黑帧和延迟
9. 小窗中来回前后台、锁屏／解锁、点击返回应用与直接关闭；后台播放开／关两组验证声音规则、音视频同步、恢复界面，检查多次关闭播放页后资源释放
10. 1080p／4K、正常速度／长按 3 倍速各测试前台预热与后台 PiP，关注 CPU、发热、掉帧，特别是 VideoToolbox-copy 到软件缩放路径；前后台转换处重点听是否有短暂音频重定位
11. 两种内核分别从顶栏投 UGC 和番剧，确认清晰度、TV 地址兼容性、选设备、播放暂停、拖动进度、音量、停止和回本机；手机锁屏后确认电视继续直接拉流
12. 个人签名测试本地网络首次授权／拒绝后重开、Bonjour、手填电视 IP 单播及 XML 地址；具备多播权限的包再测自动 SSDP。AVPlayer 页内另测“隔空播放”
