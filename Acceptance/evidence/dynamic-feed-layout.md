# 动态流布局和 UP 主面板

基线：lib/pages/dynamics/view.dart、dynamics/widgets/up_panel.dart、dynamics/controller.dart、dynamics_tab/controller.dart、dynamics_tab/view.dart 以及 lib/utils/waterfall.dart。动态条目来自原有名单、直播和动态服务；选择 UP 主过滤当前账号订阅流（feed/all + host_mid），打开空间和直播会进入对应原生页

- 「动态 → 动态筛选」的 UP 主面板五项按原顺序是顶部、左侧常驻、右侧常驻、左侧抽屉、右侧抽屉。前者横向滚动，常驻侧栏独立滚动；抽屉可点侧边按钮或从边缘轻扫打开，点背景、反向滑动、选人后关闭。面板包含全部动态、我、更新标记和可展开直播，长按头像打开空间，长按直播入口查看关注的直播
- 首屏 portal 能同时返回直播和 UP 主；后续根据“全部已关注”开关走 uplist 的不透明游标或关注接口的页号。按 MID/房间号去重，保留首屏在前，终止重复游标，有独立网络错误重试。切账号时重建名单和动态，异步响应按请求世代检查。五种分类按需挂载，切换分类保留各自列表及折叠记录；换 UP 主只重建该 UP 主的列表，下拉同时刷新列表和面板
- 「瀑布流布局」使用两倍小卡片宽度计算列数。每张卡片按实际高度排入最短的列，添加下一页连续排列；视口外只保留尺寸和位置，避免同时创建整份动态的图片和交互。关闭后居中一列；VoiceOver 和辅助大字号也提供单列。关注动态、话题动态、空间动态和空间搜索的动态结果共用 PageList 的布局与分页
- 设置键：upPanelPosition → controls.numbers.social.upPanelPosition（0...4，默认 1）；dynamicsWaterfallFlow → controls.flags.social.waterfall（Bool，未手动指定时跟随 layout.horizontal，默认 iPad 开启）。现有 dynamicsShowAllFollowedUp、expandDynLivePanel、smallCardWidth 继续使用
- 独立主机检查 Checks/FeedColumnCheck.swift 用实际列分配函数验证改变宽度、最短列、隐藏项零占位、跨页追加、列内无重叠和单列辅助阅读。账号私有订阅与直播名单未用真实用户凭据验收；真机旋转、侧滑、文字缩放和长列表滚动留待整体验收
