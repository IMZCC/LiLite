# 起播、缓冲、后台与稍后再看类型

固定上游的 autoPlayEnable 默认关闭。普通详情准备好后等待用户播放；显式选择播放列表、片尾切到下一集或切到其他分 P 时继续播放。清晰度与语言切换保留原播放状态。视频与直播分别应用 bufferSec（默认 16 秒）和 liveBufferSec（默认交由播放器决定），视频缓冲按倍速调整。使用 [AVPlayerItem.preferredForwardBufferDuration](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration)，它是网络预缓冲目标，实际缓存量由 AVFoundation 决定

进入后台使用 AVPlayer 的播放政策；主动进入画中画时临时允许继续，结束或失败后恢复偏好。离线队列的片尾也遵循五种播放顺序，但不会切换到在线推荐。后台音频服务和系统远程控制是不同的功能，不纳入这一条验收

稍后再看区分普通稿件、番剧、课程与失效项。收藏分类/队列使用原始资源 ID 进行变更，显示服务进度和标签，番剧使用 ep_id 或服务给出的跳转。普通视频只有在已知 CID 属于该稿件时才采用列表保存的进度。主机检查混合条目、一条记录没有标题、番剧使用跳转、已失效条目和已看完状态；arm64 Release 已通过。后台/画中画的切换和本账号的列表进度需要整体验收的设备证据
