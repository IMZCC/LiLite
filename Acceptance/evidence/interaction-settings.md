# 播放时机、界面缩放与触摸交互

固定上游 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。复核时按用户实际触发路径处理了五项设置

| 上游键与来源 | Swift 实现 |
| --- | --- |
| preInitPlayer，默认 false；lib/pages/video/controller.dart 的 initPlayerIfNeeded、view.dart 的手动播放与播放页恢复 | play.preinitialize。UGC、影视和课程先读详情与历史定位；未开自动播放或提前载入时只显示封面，没有请求播放源、解码或挂接 AVKit 播放画面。点封面/下方播放按钮才加载，保留之前选中的分集与进度。仅开启提前载入则准备为暂停态；自动播放、加入播放队列、接下一集按播放意图直接开始。仅预热不会打断已在听的音频队列，不会自动全屏。离线列表本身的「播放」为用户明确播放，直播进房按直播逻辑处理 |
| pauseOnMinimize，默认 false；lib/utils/desktop/window_controller.dart 的 _hide/show 只恢复自己在隐藏时暂停的播放 | play.pauseWhenBackground。绑定实际显示 AVPlayer 的 UIWindowScene；短暂失活只记状态，确实进后台才暂停，回到同一窗口且仍是同一 AVPlayerItem 才按原速度恢复。忽略主动暂停、画中画、允许后台播放的影片以及独立的听视频/音乐队列。系统遥控操作、睡眠截止、耳机拔出、音频中断、播放器替换会撤销恢复意图，应用不会重新唤起它们 |
| touchSlopH；lib/common/widgets/gesture/horizontal_drag_gesture_recognizer.dart、image_horizontal_drag_gesture_recognizer.dart | gesture.horizontalThreshold。图库与文章头图翻页读取实际横移距离（iOS 默认 24 点），要求 abs(dx) 大于 3×abs(dy)。缩放照片保持自己的平移/捏合，只有移到对应图片边缘才让出翻页。视频内容、历史和稍后再看的栏目控件支持同一阈值左右划动，选择模式保留行操作；动态侧抽屉也应用阈值 |
| refreshDisplacement，移动端默认 20；lib/common/widgets/flutter/refresh_indicator.dart | list.refreshDisplacement。原版 kIndicatorSize=49、拖拽上限为 1.5 倍，颜色到达饱和值便可触发，实际松手阈值为 displacement+49。13 个刷新入口调用共同的 UIKit 观察器；它观察用户实际触到的 UIScrollView 自己的 pan，在顶部下拉并松手后执行原页面刷新函数，同一次操作只触发一次。指示器停留位置与触发距离随设定 10–100 点一同改变，VoiceOver 可调用「刷新」 |
| uiScale；lib/main.dart 对视口宽高按比例除、像素比例乘，独立于字号，style_settings 的范围 0.50–2.00 | layout.interfaceScale。原生 SwiftUI Layout 在主导航与应用自有 sheet/fullScreenCover 为内容提供倒数比例的布局尺寸，再按选定倍数显示，字体、图标、行、栅格与点按坐标一起调整。嵌套模态的像素倍率只应用一次；系统分享面板、相册/文件选择器与系统键盘保持 iOS 自己的大小 |

入口为 PlaybackEntryOptions 与 InteractionScaleOptions；现有设置备份分别映射两个布尔值和三个数值。Host 验证：用 swiftc 编译 Settings/InteractionPolicy.swift 与 Checks/InteractionPolicyCheck.swift 并运行，覆盖 16 种播放入场组合、暂停恢复状态、房间/内容身份、方向与角度、刷新距离及无效缩放输入。用应用的实际 Release SDK/显式模块和 SwiftUI 宏对本组 Swift 改动做隔离 typecheck；对应原生 Protobuf 模块从当前 Wire 源在隔离路径生成

未向账号发写请求。iPhone/iPad 上的真实 PiP 切入与退回、锁屏和耳机事件、照片放大后边缘分页、极端缩放下的键盘与触控感受仍应在整体验收包上操作
