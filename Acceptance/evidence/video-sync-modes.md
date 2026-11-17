# videoSync / autosync 原生音画呈现

固定上游 lib/pages/setting/models/video_settings.dart 列出九个 videoSync 值，lib/utils/storage_pref.dart 的默认值为 display-resample。autosync 在备份中是数字字符串，iOS 默认为“0”，Android 为“30”；lib/plugin/pl_player/controller.dart 在非“0”时显式传给 mpv。原生实现使用相同值，存储键分别为 play.videoSync 和 play.autosync。有效因子 0…10000，与 [mpv 选项范围](https://github.com/mpv-player/mpv/blob/master/options/options.c) 相同；播放策略见 [mpv 手册](https://mpv.io/manual/stable/#video-sync)，本实现没有链接 mpv、Flutter 或新增第三方组件

| videoSync | 实际呈现和声音行为 |
| --- | --- |
| system（原生默认） | 同一 AVPlayerItem 管理画面和音轨，不启动额外的逐帧输出或 PCM 引擎；选择下面九种同步方式时才启用独立呈现器 |
| audio | 读取真实音频渲染回调发布的样本位置，扣除音频链输出延迟，按此时间选画帧。autosync 大于 0 时用上次音频时钟和名义速率预测，按因子融合新测量；跳跃、停播、合作轨道更换时清空历史 |
| display-resample | 按实际屏幕刷新和片源帧率调度画面，在 1% 以内匹配刷新分频；按音画差微调 PCM 重采样（额外修正限 ±0.125%） |
| display-resample-vdrop | 让音频采样速率匹配显示；额外偏差通过选择后续画帧或继续显示当前帧修正 |
| display-resample-desync | 让声音重采样匹配刷新速率，不追踪两轨的剩余相位差 |
| display-tempo | 以屏幕为主时钟，伸缩 PCM 的时间并保留音高。常用速度在同一实时输出环内做多声道波形相似性重叠相加；极高或极低的允许速率交给 AVAudioUnitTimePitch |
| display-vdrop | 音频以用户选定的速率运行；按测得的音画差选择、丢弃或重复已解码画帧 |
| display-adrop | 视频匹配屏幕，音频保持名义速率；需要纠偏时删掉或重复 1024 个原始采样帧 |
| display-desync | 让画面匹配屏幕刷新分频，声音按自己的钟运行 |
| desync | 以单调 host time 和用户速率决定画面，不做刷新分频匹配或音频漂移反馈；显示硬件仍在物理刷新时呈现 |

**点播与缓存。** DashBridge 注册它已授权的本机播放地址；PCM 读取复用原账号检查、轨道索引和片段窗口。SIDX 的起始时间用于保留原始音画差。已启用的声音增益或响度处理复用处理过的 ALAC 片段，避免叠加。分轨、可解析的渐进 MP4 及 App 缓存使用同一呈现器。允许交给系统解码的普通 MP4 缺少可用索引时继续播放原地址；强制软解、受保护媒体、外部引用与访问拒绝不会变成另一种授权来源

**直播。** FLV、软解/硬解复制的 HLS 和可无损重封装的系统 HLS 均由当前播放会话提供私有滚动 fMP4，原生 AVKit 解码时只是搬运原压缩包。程序日期关联当前 AVPlayer 的 item time/date；音频样本保留相对同段视频首个 PTS 的提前/滞后。切解说、清晰度、线路与重连使用新会话；旧环释放。多档自适应、其他机位、内嵌字幕、低延迟扩展、受保护和特殊轨道保留原系统呈现；没有索要密钥。对于这些必须保留的原始源，不宣称可以从 AVPlayer 强制重采样或删音频块。普通账号或服务拒绝直接结束该次请求

**渲染和边界。** PresentationSession 从 [AVPlayerItemVideoOutput](https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput) 提取有实际 PTS 的原生像素，并在 CADisplayLink 目标时刻呈现；尊重当前 PictureFit、重力、旋转与镜像。超分使用同一呈现时间。声音由 AVAudioSourceNode 读取有限环，CPU 路径不在实时回调里申请内存或加锁。额外持有一个待填片段（最多 32 MiB 原始 PCM）和不超过 8 MiB 的环，内存警告释放并延迟重建。AVKit 在独立音频和图像都有输出前继续发声；进入画中画、后台、外放映射或音轨不受支持时还原 AVKit。暂停、拖动、账号/轨道更换和中断取消旧任务。触控、键盘、鼠标音量读写同一有效音量，恢复系统时保留用户选择。每个 AVPlayer 同时最多有一个前景音画输出

**实测。** Windows/WSL 的测试使用本地生成的媒体，生产 Swift 时钟、生产 C 环/保调器和固定 FFmpeg 解码器。未连接公网，不需要账号

- Checks/presentation_timing.py：23.976 fps H.264 逐帧解码，所有画帧具有不同哈希。60 Hz 回放时连续 143 个源帧间隔恰占 2 或 3 次刷新，实际选用 1.001 速率。倒退到 2.460 秒后以 2× 运行一秒，选中源帧 106
- 双声道 48 kHz ALAC 的五段乱序 seek 输出覆盖原始帧 0…393599，左右声道均与独立 FFmpeg 参考逐字节一致。环绕回以后的插入/删除恰为 1024 原始帧。719 Hz 源 1% 重采样后为 726.190 Hz；保调模式 0.5×、1.01× 和 2× 输出分别为 719.000、719.019、718.997 Hz，每组输出 48000 帧，分别消耗源 24000、48480、96000 帧
- 九种策略驱动实际 C 音频环；向测量注入 48 ms 阶跃时，display-adrop 确实产生两次完整块改动，resample/tempo 只调整速率。7 ms 音频测量抖动在 autosync=0/30 的画面时间误差 RMS 分别为 7.000 和 0.236 ms
- 两组各七段 H.264/AAC 直播使用真实 PCM 和复用器 PTS；分别保留 +186.0 ms 与 −271.0 ms 音频偏移。不同片段继续使用同一个源时间原点，逐段输出衔接误差小于 0.05 ms。将同一窗口重新定位到 803.5 秒仍取到正确片段，停止后拒绝继续读取
- Checks/live_decode.py：clear CMAF 和 MPEG-TS 的系统解码线路均保留 66 幅原始压缩 AVC 图像切片及声音；外置英文/法文分别保留 261/262 个所选 AAC 包，测得相对视频 0.000 / −0.250 秒。软解、音频专场、33 位打包时间戳、连续滑窗及取消的既有回归通过
- Checks/audio_segments.py 与 Checks/native_decode.py 的既有增益、响度、兼容解码和渐进文件回归通过。TimingRing、AudioSegment、LiveDecoder、LiveRemux 通过 iPhoneOS SDK 的 arm64 对象编译；相关 SwiftUI、AVKit、CoreMedia、AVFAudio 代码通过同一 SDK 的类型检查

**真机待验。** 扬声器/蓝牙端到端延迟、ProMotion 实际物理刷新、系统 PiP/前后台交接、极端速度下苹果 TimePitch 的听感和 HDR 亮度，需要最终整包后一起在 iPhone 验收；上面的毫秒和频率来自可重复的样本测试，未把 WSL 当作真机
