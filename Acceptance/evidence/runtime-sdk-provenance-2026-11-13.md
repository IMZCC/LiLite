# 真机外观与 SDK 构建信息修复

用户反馈包为源码 `b7e128c121c1b18fd72c4ae7261e8e34333f1b87`，已核对原交付 IPA 的 SHA-256 与安装回读记录

## 已确认的问题

原包在 iPhone 15 Pro Max / iOS 27.3 上使用旧式系统标签栏和导航样式，直接读取主 Mach-O 的 `LC_BUILD_VERSION` 得到 platform=2、minimumOS=17.0、SDK=17.0；但实际编译使用的是已安装的 iPhoneOS 27.1 SDK

SwiftPM 的部署目标 `.iOS(.v17)` 被 Linux Swift 驱动同时用于链接 SDK 信息，原构建没有覆盖该信息；Info.plist 也没有保存 DTSDKName、DTSDKBuild 和 DTPlatformVersion

Apple 的 [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) 与 [Build a UIKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/284/) 说明系统新外观随使用新版 SDK 重新构建启用，这个构建错误使之前的源码设计检查无法可靠反映真机系统外观

## 修复后的构建路径

- `build.sh` 在 Linux 读取 SwiftPM 实际选择的 darwin/arm64-apple-ios SDK 配置，在 macOS 读取 xcrun 选择的 iPhoneOS SDK
- `Tools/build_stamp.py` 核对 SDKSettings 与该 SDK 的 SystemVersion，保存真实 DTSDKName、DTSDKBuild、DTPlatformName 和 DTPlatformVersion
- 自定义 `PILI_IOS_SDK` 必须与实际 Swift 编译 SDK 的规范路径相同，否则在构建前拒绝，避免只改变版本标记
- `Package.swift` 将实际 SDK 版本交给链接器的 `-platform_version ios 17.0 SDK`，最低运行版本继续为 iOS 17
- `Checks/inspect_ipa.py` 对最终 IPA 的主程序核查 linked SDK 与 plist 的 SDK 信息相等，并拒绝旧 SDK 误标及旧外观兼容开关；签名前后均执行同一检查

没有修改 xtool 安装、全局 Swift SDK 配置、已签名程序或已冻结的旧交付包

## 实际验证

1. 临时 C 程序在本机 ld64.lld 上证明 `-sdk_version` 尚未实现而被忽略，追加实际 `-platform_version` 可以保留 minimumOS=17.0 并设置 SDK=27.1
2. 独立临时 SwiftUI 工程经过真实 xtool release → IPA，得到 minimumOS=17.0、linked SDK=27.1、DTSDKName=iphoneos27.1、DTSDKBuild=24A94232；使用生产包检查器通过
3. 同一临时工程连续构建未清理缓存：未设置 SDK 参数 → SDK17（检查器拒绝），设置27.1 → SDK27.1（通过），设置27.2但plist仍为27.1 → 拒绝，恢复27.1 → 重新链接并通过
4. 既有 `Checks/interface_signoff.py` 加入 SDK 元信息、部署目标误作 SDK 的拒绝及不同 SDK 路径拒绝回归，与原有接口签收一并通过

整包的真机更新、系统新外观截图和播放/滑动对照另记在本次交付运行记录中
