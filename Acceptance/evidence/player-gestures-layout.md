# 播放画面、底部进度条与辅助操作

对照 lib/plugin/pl_player/models/bottom_progress_behavior.dart、view/view.dart、controller.dart 和 lib/pages/video/view.dart、lib/pages/live_room/view.dart

- 录像、剧集和离线播放的细条按 upstream 枚举顺序保留四种选择：始终、隐藏、仅全屏、仅内嵌。完整播放控件显示时让出位置；在透明画面上横拖定位时，即使细条设为隐藏也可显示临时位置。直播是持续流，不显示点播进度。全尺寸与细条都按 AVPlayerItem 的真实 loadedTimeRanges 绘制缓存区间，不把范围间的空洞误画为已缓冲。拖动、点按和 VoiceOver 调整都通过所属播放器定位
- 细条和大滑条可显示现有空降标记和已取得的同一 CID 章节刻度。VideoExtras 将 /x/player/wbi/v2 返回的起点送入已有的 TimelineState，无额外请求。切换 CID 时清空不属于该内容的刻度
- 应用控件按 3 秒或 30 秒收起，交互中不收起；启用 VoiceOver 时保留可访问控件。全屏可单独锁定。系统控件按钮切换到真实 AVPlayerViewController，可继续使用 iOS 的画中画、路由和原生播放菜单。系统自己的控制条按 iOS 规则显示
- 上游 minScale 为 0.75（关闭缩小时 1）、maxScale 为 2。原生使用双指起始焦点和实际窗口尺寸约束放大偏移，缩至画框内时居中，支持一键复位。应用模式下只有不带系统控件的 AVKit 视频容器改变尺寸，弹幕/字幕及命中区域始终位于未缩放的外层。进入系统控制模式先复位至 1 倍。内嵌与自定义全屏交接时只保留当前渲染容器，AVPlayer 与媒体源仍由原有页面管理
- 支持普通视频、番剧/课程、离线和直播。直播同页展开、收起，保留正在播放的 AVPlayer、房间和弹幕连接；继续沿用原先的 SystemMediaControls。设置中可让点播/直播画面延伸到屏幕边缘；关闭时遵循系统安全区域
- 存储/备份：btmProgressBehavior ↔ player.bottomProgress（整数 0…3），enableLongShowControl ↔ player.longControls（默认 false），enableShrinkVideoSize ↔ player.shrink（默认 true），removeSafeArea ↔ player.edgeToEdge（默认 false）
- 验证：主机执行实际策略源的 24 个进度条可见性分支组合（四种模式、内嵌/全屏、控件/拖动），检查双指边缘焦点、2 倍上限、0.75/1 倍下限、无效值。UIKit/SwiftUI 部分按 iOS 17 API 编译；刘海/灵动岛布局、系统画中画、走 AirPlay、屏幕阅读器焦点和真实手势冲突仍留在最终设备场景核对
