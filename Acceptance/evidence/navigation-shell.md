# 导航外壳和「我的」预览

依据固定上游 lib/pages/main/view.dart、main/controller.dart、common/common_page.dart、home/view.dart、mine/view.dart、mine/controller.dart 及 models/common/{mine_tab_type,bar_hide_type}.dart。首页、搜索、动态、我的各保留独立 NavigationStack；壳层延用原有账号重置、定时停止后返回首页、未读计数、URL 打开等入口

| 原偏好（存储值） | 原生行为 / NavigationLayout 字段 |
| --- | --- |
| useSideBar / hideSideBarLabel / optTabletNav | sidebar / iconOnly / tabletNav：横屏用侧栏，可令竖屏也用侧栏；宽 iPad 可用展开式，窄屏保留图标栏；图标仍有 VoiceOver 名称。侧栏按真实主栏目顺序展示，必要时提供搜索、我的或消息快捷入口 |
| floatingNavBar | floating：竖屏底部使用悬浮圆角栏；单栏目不保留多个入口占位 |
| hideSearchBar / hideTabBar | collapseTop / collapseBottom：分别控制发现页顶部的搜索入口和根页底栏，频道本身保持可选；侧栏不响应这两个收起设置。只监听选中根页的垂直滚动，不改变原 UIScrollView delegate，不拦截深层页面的返回、横向预览或播放手势 |
| barHideType | hideMode：0 收起/展开，1 按手指实际位移同步渐收，到达列表顶部恢复。VoiceOver 打开时不收起，减少动态效果时关闭位移动画 |
| mainTabBarView | animateTabs：开启时栏目切换有横向或纵向到场动画，关闭时立即切换；主 Tab 不引入和内容冲突的分页滑动。重选当前栏目可回到顶部，首页与动态有原生刷新控件时可触发刷新 |
| directExitOnBack | directBack：在有硬件 Escape 键且停留于非第一个主栏目根页时，关闭「直接返回」会转到首个栏目；开启后交由系统处理。iOS 的退回桌面保留系统手势，上游 main/view.dart 的 _onBack() 只有 Platform.isAndroid 分支执行 AndroidHelper.back() |
| mineTabs | mineTabs：收藏、观看记录、稍后再看、订阅以原序号 0–3 保存，默认只开收藏。可重排和隐藏所有预览，原有完整资料库、设置与账号入口仍可进入 |

首页收藏预览、收藏/订阅详情分辨 type 0/11 的文件夹与 type 21 合集；history/cursor 带 type=all，由历史角色账号读取。观看记录区分普通视频和分 P、番剧/分集、课程、文章、文集记录和直播，未开播或无有效目标的行不跳向视频。稍后再看沿用原生 LaterMedia 的授权结果和类型；每种预览独立翻页、去重、显示错误和重试，可点查看全部。刷新个人页会刷新启用的预览；账号切换后用新身份重新加载

实现：Settings/MainNavShell.swift、NavScrollAttachment.swift、NavigationRules.swift、NavigationLayout.swift，Account/ProfileView.swift、ProfileShelf.swift、ProfileShelfModels.swift，PiliNativeApp.swift 及各个 tab 的根视图。兼容老 navigation.layout，显式空 mineTabs 与未设置（默认收藏）分开；重复 ID、默认栏目不在可见列表等无效输入由 validate 拒绝

已运行 Checks/NavigationShellCheck.swift：验证旧版设置迁移、启用/隐藏/重排、空栏目与重复项边界、横竖屏决策、滚动收起计算及六类历史内容实际导航目标。使用本机 Release 的 SDK、SwiftUI 宏与显式依赖图，独立检查此次相关 iOS 源。尚需最终设备核查系统标签栏隐藏、iPad 分屏与旋转、读屏、键盘 Esc、实际滚动/返回/嵌套手势、真实账号混合内容与未读切换。本次没有调用真实私有账号接口
