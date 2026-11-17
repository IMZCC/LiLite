# 原生点播解码选择

上游 lib/plugin/pl_player/controller.dart 在 enableHA 关闭时不设置硬解；开启时使用 hardwareDecoding 的有序 mpv 字符串。iOS 默认 auto；no、auto、auto-safe、auto-copy、videotoolbox、videotoolbox-copy 在原生设置有对应项。导入其他平台的枚举名时保留备份，运行时跳过不适用的后端。键：enableHA → controls.flags.decoder.hardware（默认 true），hardwareDecoding → decoderChoices / decoder.choices（默认 auto）

- 取流仍由原有 UGC、PGC、课程接口和账号决定。直通路线由 AVFoundation 与实际硬件能力判断；发现原设备不能处理的 AVC/HEVC/AV1/VP9 表示时可选软件解码。拷贝使用 FFmpeg 的 VideoToolbox hw-device 与硬件帧传输；软件模式用原生 CPU 解码器，其中 AV1 是固定版本的 BSD dav1d
- 兼容路线从当前授权的 DASH 表示读取初始化头和 SIDX 定位的片段，必要时回到前一个独立关键帧。拷贝与软件路线把像素送入 iOS 的 H.264 或 HEVC 编码器，输出同一个本地 HLS 播放器使用的 fMP4。首段先试解，后续按需转换；不混音、不变更用户选中的原声轨、字幕或弹幕时钟。输出使用原始显示时间及独立片段序号，每段附匹配的初始化头，依据真实 avcC/hvcC、分辨率和传递函数生成主清单。AVPlayer 最后的呈现仍是系统视频播放
- 普通 SDR 输出使用 YUV420P；HDR10 与 HLG 保留十位 P010，iOS 用 HEVC Main10、原来的颜色属性和可用的静态色量/亮度元数据。杜比视界、HDR Vivid 不会被这条路线默默降级，仍按系统能否直接播放处理。原服务不提供分轨时也可在合法渐进 MP4 上使用软件/拷贝偏好，见 [在线渐进解码记录](progressive-native-decode.md)。离线分轨缓存及普通单文件 MP4 复用同一实际解码路线和原声，具体文件索引、权限和中段跳转验证见 [离线解码记录](offline-native-decode.md)
- Swift 编解码任务在独立 worker 运行；同时到来的 HEAD/Range 请求只转换一次，按用户跳转取消过时的网络和编码任务。C 接口只收到有界字节和位置，没有 URL、Cookie 或用户标识；不读取外部 dref，拒绝加密样本，按设备内存限制输入像素、单段内存和耗时。应用链接的是 LGPL FFmpeg 9.0.2、BSD dav1d 1.5.4，不含 x264/x265 等 GPL 编码器
- Checks/native_decode.py 在主机离线合成 AVC、HEVC、AV1、VP9，各 36 帧。四种源的全部 YUV 帧哈希与独立解码匹配；13 个片段按单段和关键帧预热路径读取，核对真实画面、绝对显示时间、输出 fMP4 可独立解码及取消。PQ、HLG 各 12 帧的 P010 平面逐帧哈希匹配。Swift 层另实际合并 8 个相同片段请求、重新拼出可解码的视频、取消过时 seek，解析原始 AVC/HEVC 配置和编号。Checks/live_remux.py 的既有直播封装测试也通过
- 主机输出测试编码器是 LGPL MPEG-2；iOS 编译了 arm64 版本的 VideoToolbox H.264/HEVC 编码路径，桌面测试不能替代 iPhone 对系统编码、HDR 效果、长时间温度功耗、拷贝、后台及 PiP 的验收。FLV 与明文同轨 HLS 另见 [直播视频解码记录](live-video-decoder.md)。独立 HLS 音轨的选择和时钟另见 [独立直播音轨](live-alternate-audio.md)，动态导出未在此项记作已实现软件解码，仍保持移植项 partial
