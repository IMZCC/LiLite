基线 lib/utils/page_utils.dart 的 showVideoBottomSheet，以及 lib/pages/video/view.dart 与 controller.dart 中选集、章节、笔记、空降标记的全屏入口；定时停止见 lib/services/shutdown_timer_service.dart

UGC、番剧和课堂在同一 AVPlayer 上打开独立的 SwiftUI 栏，宽屏使用右侧半屏（上限 500 点），竖屏保留上方画面和下方工具。旋转时 AnyLayout 改变排列方向，播放画面仍是相同子视图。关闭工具、选择画质、倍速、语言、音质、章节、弹幕时间点都使用当前 PlayerModel。选集和合集沿用详情页的实际 CID/BV 及播放顺序，课程评论传类型 33 和课程分集 ID，普通视频/番剧评论用类型 1 和稿件 ID。下一条不会沿用上一集的章节请求。笔记、空降和定时器各保留各自服务与确认流程。锁定会关闭工具

改动已由 Swift 编译器使用 iPhoneOS SDK 对入口、面板、章节和定时器做类型检查。旋屏、弹出系统键盘、画中画时的布局和横屏触控留在最后的设备验收清单
