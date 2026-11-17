# 播放页横屏、播放设备与系统播放控件

固定基线：lib/pages/video/view.dart 的 _shouldShowSeasonPanel、childWhenDisabledLandscapeInner，lib/pages/video/introduction/ugc/view.dart 的 UP 主 / 联合创作入口，lib/services/audio_handler.dart 的 setMediaItem、onUpdateState 和移动端后台音频服务开关

横屏布局以当前窗口可用尺寸为准，iPad 默认开启，iPhone 可手动设置。宽屏把视频和当前栏目并排；视频层不随简介、评论、选集和 UP 主空间的切换销毁。UGC 选集使用实际 CID、合集使用实际 BV，分 P 和合集的排序及倒序切换行为与简介共用状态。番剧与课程选集切换同一播放器的当前分集，单集不显示空的列表标签。横屏点开视频作者或联合创作中的主 UP，会在右栏打开独立导航栈；返回可继续看简介、评论。扩大竖屏画面根据 AVPlayerItem.presentationSize 判断：竖屏窗口接近正方形预览，横向并排用 9:16；横向片源保持宽屏比例

后台音频服务与进入后台继续播放是两个独立设置。当前活跃的系统控制发布者负责 MPNowPlayingInfoCenter 和 MPRemoteCommandCenter，切换视频、歌曲、直播、离线播放或账号时移除旧目标。锁屏展示实际标题、作者、可用封面、进度和速率；视频与音频允许跳转和快进退，有分集或队列时提供上/下一项。直播只提供可用的直播操作。关闭设置时清除当前元数据和遥控目标。AVKit 画中画沿用播放器本身的系统会话，不给 AVPlayerViewController 的播放器创建第二个 MPNowPlayingSession。点播与听视频另有系统播放设备选择入口

本基线的 audioOutput 对应 mpv 的 Android 输出驱动优先级，处理见 lib/plugin/pl_player/controller.dart:851 与 lib/pages/audio/controller.dart:394 中的 Platform.isAndroid 条件。原生版提供 iOS 实际可用的播放设备入口，不导入 Android 驱动名。横屏读屏和点选体验、锁屏远程按键焦点、耳机切设备和画中画仍需要最终 iPhone 验收
