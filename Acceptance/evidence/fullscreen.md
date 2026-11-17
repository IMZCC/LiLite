# 全屏方向与手势

对照 lib/plugin/pl_player/models/fullscreen_mode.dart、播放器视图的中心三分之一区域和进入/播完退出设置。普通视频、番剧和课程支持手动全屏及自动进出；按作品方向、保持当前方向、强制竖屏、横屏和屏幕比例五种设置均实际接入全屏视图。Android 专属的重力强制模式在导入 iOS 设置时转换为保持当前方向

使用当前 UIWindowScene 的 requestGeometryUpdate 与视图控制器的 setNeedsUpdateOfSupportedInterfaceOrientations（Apple UIKit），按场景保存和撤销方向约束；系统拒绝旋转时仍能使用全屏。中心区域上下滑切换全屏，可反转方向；两侧保留亮度/音量，横滑仍是进度。全屏锁定期间不接受滑动退出

主机已验证竖屏视频、近方形屏幕、保持模式、正反向手势和中心/侧边界。iPhone 和 iPad 的实际旋转、系统方向锁和 AVKit 手势冲突属最终设备验收
