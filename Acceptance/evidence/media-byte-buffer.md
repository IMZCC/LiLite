# 点播和直播缓冲容量

固定上游 lib/utils/storage_pref.dart 的 initBuffer / initLiveBuffer 分别配置 demuxer-max-bytes、demuxer-max-back-bytes 与 cache-secs。点播默认前、后各 4 MiB；直播默认前向是点播容量的两倍（可单独指定），无后向缓冲；秒数是另一个偏好

- 设置 → 播放器 → 缓冲容量支持小数，原版 bufferSize → controls.numbers.play.bufferMB、liveBufferSize → controls.numbers.live.bufferMB。保存范围 0...512 MiB；点播填 0 不保留额外字节，直播填 0 继承两倍。单方向实际驻留上限再取设备物理内存的约 1/48 和 128 MiB 两者较小值，低内存警告会进一步收缩。原有 bufferSec、liveBufferSec 继续独立设置时间
- MediaBufferWindow 按轨道、实际字节位置保存已读和预读两份窗口；声画轨共享容量但不共用偏移。同轨并发读取排队，可取消。命中支持子范围；取索引不额外读媒体，对有明确边界的连续片段按真实范围预读，前台需求优先，后台预读每次网络请求最多 512 KiB，每批最多 4 秒并受前向窗口容量约束。DASH 预读还受码率、时间偏好和最后一个可用片段的限制。内存压力清空缓存、取消预读，返回中的旧数据不能写回被清空的窗口
- DashBridge 把索引、初始化数据与音/视频片段接入缓存；显式拖动会取消偏离目标的在途分片，切换画质、语言或账号时不共享旧播放器的字节。渐进 MP4 与听视频的 MediaLoader 先从 206 的 Content-Range 获取真实文件长度和媒体类型；按最多 256 KiB 一次向 AVFoundation 供数，并验证后续范围的总长度。AVFoundation 取消已失效的请求时会取消相应任务。媒体只在内存中复用，RangeTransport 保留凭据隔离和响应校验
- 直播 FLV 输入用按实际流量分配的分页 FIFO 代替固定的大数组。达到阈值会暂停上游，读出后恢复；内存压力降低水位，缓冲中尚未被解复用器读取的连续媒体字节仍按顺序交付。直播 HLS 由 AVPlayer 管理内部缓冲；使用当前日志中的指示码率或已下载字节/分片时长，换算 preferredForwardBufferDuration，并同时遵守用户的直播秒数限制。必要数据出现前保留播放器原有设置。这里是时长提示，无法将系统解码器或系统 HLS 总内存硬限为指定字节数
- 独立 Swift 检查 Checks/MediaBufferCheck.swift：真实窗口的前向预读至 1 MiB 后离线命中、回退范围命中、声画不同数据、短读拒绝、同轨等候中取消、内存压力与在途返回交错、关闭后拒绝读取；还验证直播容量继承、HLS 换算、FIFO 连续 190,213 字节经过多次跨页、缩容量与读写交错逐字节相等。未用真实账号发起任何写操作，真机拖动、前后台切换、AVPlayer 直播缓冲行为与系统的内存压力事件仍需最终验收
