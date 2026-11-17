对照固定上游 ios/Runner/AppDelegate.swift、SceneDelegate.swift 和 Info.plist。应用保留原版启动时禁用摇动撤销、iOS 26 以上 iPad 窗口最小控制样式；由 SwiftUI 管理应用、导航和窗口。采用 [Apple 的 SwiftUI 应用代理与场景代理接入方式](https://developer.apple.com/documentation/swiftui/uiapplicationdelegateadaptor)，仅指定窗口代理，不更换场景类或 storyboard

iPhone 支持竖屏和两向横屏，iPad 额外支持倒转竖屏；进入全屏期间覆写只作用于播放器所在的 scene，关闭后恢复。指针、触控板滚动和 ProMotion 需要的应用标识随包检查。原生后台下载回调、系统 PiP、照片系统选择器和只写入照片权限分别由相应的系统组件负责，给本地网络的用途说明为发现投屏设备。iPad 窗口按钮、横竖屏及系统事件必须在最终实机验收中核查
