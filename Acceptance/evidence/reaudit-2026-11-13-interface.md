# 原生界面与 Liquid Glass 重审

本轮在固定上游功能范围内保留原生导航和可配置布局，专门核对当前 SwiftUI 层，而非把浏览器图片当设备验收

## 已改动的实际界面

- `Settings/NativeGlass.swift` 集中使用系统 `glassEffect` 与 `GlassEffectContainer`，所有新 API 均在 iOS 26 可用性分支内；更早的系统使用兼容材质，“降低透明度”使用实色背景
- `Settings/MainNavShell.swift` 默认使用真实系统 `Tab`、同一栏中的独立搜索页、系统标签栏和滚动最小化，交由 iOS 27 呈现原生玻璃及自适应布局。用户配置的侧栏、只显示图标、浮动、紧凑、动画及即时收起保留兼容壳；`NativeTabReselect` 转发系统原委托，同时处理新旧 UITab/controller 回调及去重，保留重选回顶/刷新
- 搜索采用 Apple HIG 为丰富内容推荐的标准标签页模式，热搜/历史/分类作为搜索首页；原生搜索标签将 `SearchView.searchable` 显式置于顶部导航栏下，独立搜索窗口保留默认位置，不上提业务状态或自动弹键盘。默认标签顺序为发现、动态、我的、搜索，自定义顺序原样保留，参考[当前搜索指引](https://developer.apple.com/design/human-interface-guidelines/search-fields)
- 宽屏侧栏配置隐藏搜索或我的标签时仍走保留快捷入口的兼容壳，避免仅显示动态等自定义配置丢失全局搜索、个人页和消息入口
- `Library/Feed.swift` 默认由独立系统搜索标签提供搜索，不重复堆叠搜索框；开启默认搜索词或使用兼容导航时仍有首页搜索入口。频道为普通内容选择，推荐首条为主卡片，其余保持自适应网格及原反馈/删除/刷新边界，不把玻璃铺在内容卡片上
- `Settings/NightAppearance.swift` 不再在新系统默认导航/工具栏上强制覆盖旧 `.bar` 材质；用户主动选择的纯黑外观保留
- `Playback/PlayerViewport.swift` 与 `Playback/Theater.swift` 的播放条、锁定/截图/面板等悬浮控件使用真实玻璃 API；字幕及弹幕不套玻璃材质
- `Library/GalleryView.swift` 的实况切换控件接入同一系统材质
- `Playback/DetailView.swift` 将标题和元数据前置，两排次要控制移入 `ArchivePlaybackOptions` 原生 Form，画质、线路、截图、音轨、音质、字幕、音量、AirPlay、倍速和播放行为均保留；弹幕、列表及播放入口仍直接可达。BV/AV/标题复制移入 `ArchiveMetadata` 原生菜单
- `Account/ProfileView.swift` / `ProfileOverview.swift` / `ProfileComponents.swift` 使用 64 点资料头像、主次文字、四列快捷入口和系统分组列表；大辅助字号改两列。所有账号、资料库、订阅与社交入口均保留
- `Settings/Settings.swift` / `SettingsRow.swift` 按外观、阅读、播放、内容、账号、存储分组，采用原生 Form/NavigationLink/Label 与 SF Symbols 图标。全部 45 个定位目标均保留，SwiftSyntax 索引解析及实际控件检索再次核对，不改设置键与备份内容

原生界面源码实际调用 Apple 公共 API，参考[自定义视图应用 Liquid Glass](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)与[SwiftUI 更新](https://developer.apple.com/documentation/updates/swiftui)

## 验证及预览

`dist/reaudit-2026-11-13/glass-sdk.py` 复用实际 iPhoneOS SDK 编译参数，对导航/详情/材质包装执行 arm64 iOS 17 目标类型检查，已通过，日志同目录 `glass-sdk.log`；个人页/设置 SDK 与设置检索、界面验收的结果见 `dist/profile-layout-sdk-run.log` 和 `dist/settings-profile-*`。可用性检查同时覆盖旧部署目标，未为纯样式改动新建测试套件

`Tools/Previews/render.ps1` 从源码对照生成发现、视频详情、搜索、我的、设置、深色首页和横向全屏播放预览，`provenance.json` 逐页记录参考 Swift 文件与摘要。输出位于 `dist/Previews/2026-11-13`，使用本地虚构标题、图片、账号与计数，无真实账号请求

PNG 是 Windows Chrome 渲染的本地 HTML 布局预览，系统控件和玻璃光学效果为 CSS 示意。真实动态折射、滚动、触控反馈、VoiceOver、降低透明度及设备耗电在真机验收清单内核对
