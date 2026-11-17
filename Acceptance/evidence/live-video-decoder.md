# 原生直播视频解码

- 上游 lib/pages/live_room/controller.dart 按房间接口返回的协议、封装、视频编码、清晰度和线路取流；lib/plugin/pl_player/controller.dart 从 enableHA/hardwareDecoding 选解码方式。原生直播同样从房间实际返回的线路选择。普通直通仍由 AVPlayer 播 HLS 或从 FLV 原包重封装；系统拷贝与软件模式有独立的连续视频解码器，不把严格软解悄悄变成系统直通
- 路径：直播间 → 播放线路。保持优先格式/线路，在同一条服务授权的线路上按设置尝试直通、VideoToolbox 解码并拷贝或软件解码；错误或断线再尝试房间返回的其他线路。修改视频解码设置后重建当前线路。软件分支使用固定 LGPL FFmpeg AVC / HEVC / VP9 或 BSD dav1d AV1 解码。原 iOS 画面输出使用系统 H.264（SDR）/ HEVC Main10（PQ、HLG）；原音频不进入 PCM 滤镜，保留音轨、声道、媒体时基，音频-only 房间不虚构视频轨道
- 直播视频帧被实际解码、转换像素格式和重新编码，在 iOS 上使用 H.264 或保留静态色彩元数据的十位 HEVC。对 Dolby Vision、HDR Vivid、动态 HDR10+、受保护的视频样本等不做无提示降级。HLS 窗口以两秒左右为一个关键帧片段、清单保留六个片段；文件只在本会话的临时目录和 127.0.0.1 随机会话地址使用，播放结束按已有生命周期清理
- 软件 HLS 支持明文、音视频在同一媒体流的 CMAF/fMP4 与 MPEG-TS。实现主清单选择、普通资源和显式/隐式 ByteRange、地图头、序号、滚动刷新、结束、断点/时间线重启及取消。MPEG-TS AAC 用 aac_adtstoasc 转换封装，压缩音频内容不变。只允许已取得的 HTTPS 媒体来源，拒绝越域跳转和凭据 URL，不向派生媒体请求添加账号 Cookie。401、403、412、429 会停下并显示原因
- 控制语义参见 [RFC 8216](https://www.rfc-editor.org/rfc/rfc8216)。软件路径对加密 KEY/SESSION-KEY 在请求媒体和密钥前就拒绝；内嵌 CENC 元数据及加密样本也拒绝。主清单中的独立音频 rendition 现支持原包选择、独立更新和跨容器时间同步，详见 [独立直播音轨](live-alternate-audio.md)。LL-HLS 等到完整片段，不承诺部分片段低延迟；需要专用密钥、独立 I-frame 清单或 delta-only 清单时不会猜测资源
- 验证入口：WSL 运行 python3 Checks/live_decode.py。连续的 AVC、HEVC、AV1 FLV 各实际软件解出 66 帧再编码，独立参考解码与输出原始像素的 RMS 差为 1.38、1.50、1.33（满幅 255），各自 259、259、258 个 AAC 压缩包逐包匹配，并比较共同音画时钟。fMP4/TS 两组从真实生成的单文件 HLS ByteRange 清单走 Swift 读取后交给 C 连续解码，各输出 66 帧和相同的原声音频；另验证音频-only、错误编码、没有实际硬件时拒绝硬拷贝、中途取消、加密标签/样本、错误音轨标记/外域 URL、错 Range、403 和响应大小上限。22 秒的连续源产出 220 帧，清单序号前进，六段可见、磁盘最多九段
- 同一 C 核实际编译为 arm64 iOS 17+ Mach-O，直播源、回环桥与播放器通过 iOS 27.1 SDK 独立类型检查。主机输出用 LGPL MPEG-2 测试编码器；iPhone VideoToolbox 拷贝、HDR 显示、实际直播权限、长时间耗电、直播台切流/断线需要最终真机验收。测试未使用真实账号，也没有向真实直播地址重复试取
