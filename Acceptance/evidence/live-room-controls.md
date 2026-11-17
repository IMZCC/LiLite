固定来源：lib/http/live.dart::liveRoomInfo/liveFollow，lib/pages/live_room/controller.dart 与 widgets/{header_control,bottom_control}，lib/plugin/pl_player/view/view.dart 和 lib/pages/live_follow

- 开启仅音频重新向当前直播间、同一观看账号申请 only_audio=1；普通模式不带该字段。两种均保留 qn、format、codec、panorama、dolby。只在该次服务授权返回的线路中选择；音频 HLS 使用系统 AVPlayer，FLV 通过已有原生转封装（已验证纯音频 FLV）。如果授权结果仍包含视频，当前播放器禁止渲染其视频轨。模式、清晰度、房间、观看账号改变均取消上一请求；不沿用其他账号的结果
- 应用内横竖全屏保持同一房间和媒体：首次真正播放按“自动全屏”设置，方向按当前视频/屏幕策略；左右两侧分别调亮度/音量、中央上下滑切换、锁定、截图/动图、电量、直播聊天、定时和真实播放状态在全屏均可达。直播不响应点播的快进/长按倍速。返回或换线路不重发观看记录
- ROOM_CHANGE 实时更新导航、站内分享与系统媒体标题；ONLINE_RANK_COUNT 用在线人数；WATCHED_CHANGE 用累计看过的文案。三者与心跳人气值独立。服务给出的开播时间按分钟更新；播放信息显示当前真实线路/格式、音轨、画面尺寸、码率或丢帧，有值才显示
- 游戏赛事进入原版同一官方 H5 赛程，使用当前外观；从网页的赛事链接去原生详情。关注直播按主账号分页，带 ignoreRecord/hit_ab，按 live_count 与服务页数终止；保留上播状态、主播、封面、分区与热度，支持查看和保存封面
- Checks/LiveInteractionCheck.swift 验证请求变体、房间事件、区分在线 0、类型错误、去重和翻页边界；相关界面通过 iPhoneOS 27.1 arm64 类型检查。匿名视听对照试验在目录入口得到 -352 后停止，未将它计作真实直播流回放。实际声画切换与系统 PiP/方向仍需最终设备测试
