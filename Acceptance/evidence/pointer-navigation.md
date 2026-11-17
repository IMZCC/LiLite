lib/plugin/pl_player/view/view.dart 的滚动偏移除以 4000 后调节音量。原生播放容器用 UIKit 的 UIPanGestureRecognizer.allowedScrollTypesMask 接收鼠标滚轮和触控板，allowedTouchTypes 为空，覆盖层只命中 UIEvent.scroll，点击/手指拖动仍送到下方控件。各类播放画面共用 Theater；可关闭并从 enableScrollVolume 备份还原。参考 [UIKit scroll event recognition](https://developer.apple.com/documentation/uikit/uipangesturerecognizer/allowedscrolltypesmask)

设置里的宽松底栏用强调区和较大的行高；切换为紧凑底栏保留 44pt 触控区域；悬浮和侧栏独立。enableMYBar 在原项目表示 Material3 与较窄 Material 底栏切换，这里按 iOS 风格保留对空间占用与当前项突出的选择。系统亮度与自动定向的安卓开关分别不参与原版 iOS 亮度写入与设备方向阈值；原生 iOS 手势按原行为直接调节屏幕亮度并用 UIKit 管理展示方向。指针、方向与屏幕显示仍需最终设备核查
