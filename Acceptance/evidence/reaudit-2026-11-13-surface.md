# 发现、阅读、设置与原生交付复核

日期：2026-11-13
固定原版：`d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`
复核起点：`daa2ea629cc15584ebcad032c7275424dbc4700f`
本文件记录此后工作树的增量审查与修复，正式交付仍须在全组最终提交冻结后重新捕获执行收据

## 结论与清单边界

本轮从原版按钮、页面状态、设置保存值及实际网络消费者反查 Swift 路径，发现并修复下表八项行为问题或操作遗漏

初始 `parity.py --summary` 读回 655 条索引：114 page、70 route、249 preference、56 screen、15 subsystem、4 platform、147 upstream；当时状态为 633 implemented、3 partial、16 not-ios、3 source-note。这些索引相互重叠，不能作为 655 个独立功能或完成百分比。比如“账号用途 API 说明”是隐私页内的普通按钮，并不单列为 preference；搜索标签保活、刷新失败后重试也不由条目数量表达

16 条 not-ios 的原版条件均在固定源码内指向 Android 或桌面专属操作，包括系统 DocumentsProvider、桌面窗口/托盘、Android 旋转阈值和音频驱动等；播放器音量、主题种子、亮度等 iOS 对应能力仍有独立实现。屏幕模式选择在原版 `style_settings.dart` 明确由 `Platform.isAndroid` 守卫，原生版的弹幕/动图刷新率选择另有实际消费者，没有把 Android 的显示模式枚举当成 iOS 设备模式

三条 source-note 仅是固定 README 120/136/141 行的裸总结，原文、章节、无子项与同一 blame 来源由门禁校验。本轮已向根审查明确指出此前 mobile 登录/设备列表的“发证方条件”不能替代公开源码内已有客户端协议，根审查已撤销此豁免并另行补齐；本文件不以这三条 partial 作为完成结论

## 本轮修复

| 具体操作与触发 | 原版与修复前差异 | 现在的实际路径 |
| --- | --- | --- |
| 推荐已有列表、刷新失败、点重试 | 原版刷新从首页重查；Swift 用 `videos.isEmpty` 推测刷新模式，会请求旧页的下一页 | `FeedModel.Request` 保存失败的 page/reset；retry 重放该请求，主动刷新清空旧失败状态；初次失败、已有列表刷新失败和加载更多失败分别保留其请求 |
| 移动推荐屏蔽分区，作者又已关注 | `VideoHttp._filterAppRcmd` 在关注豁免之前按 `args.tname` 过滤；Swift 曾仅对热门/排行应用分区规则 | `RecommendationFilter.Source.mobileFeed` 先做分区过滤再做关注豁免；Feed 新页及保留历史统一使用同一来源；一次捕获的 mobile 值同时传入 `BiliAPI.recommendations`，避免 actor 间设置变化造成端点/规则不一致 |
| 已翻页的话题刷新失败、点重试 | 原版 `onRefresh` 清空 offset；Swift 曾按旧 next 是否为空推断重试，会使用旧分页游标 | `TopicTimelineState.Request` 保存 topic/owner/reset/cursor/sort，重试保留真正失败的刷新或分页请求；新刷新/排序清理旧失败状态 |
| 搜索已翻页后切其他分类再切回 | 原版 `CommonSearchPanelState` 用 `AutomaticKeepAliveClientMixin` 保留列表；Swift 的单个 PageList `.id(domain...)` 每次重建 | `SearchView` 用 `RetainedDeck` 保留访问过的分类、列表和滚动状态；每类独立 VideoSearchOptions/OtherSearchOptions；筛选只重置该类，关键词/账号变化才整体失效 |
| 设置中主动查看账号用途 | 原版隐私页“了解账号模式”列出用途对应 API；Swift 只有用途选择器 | `AccountRolesPanel` 新增“账号用途说明”，主动点开后按真实只读 `AccountRoutes.services` 分组展示，不复制一份会漂移的表 |
| 评论屏蔽提及人数输入 0 后保存 | 原版将 0 存为 null 以禁用；Swift 存 threshold=0，使 `mentions.count >= 0` 屏蔽所有评论 | `ReplyFilterPanel` 将 0 保存为 nil；正数阈值保留，负数和格式错误继续拒绝 |
| 阅读中打开原网页、复制链接 | 原版文章顶栏与菜单具有两个直接操作；Swift 曾只有分享/私信/卡片 | `ArticleReader.publicURL` 优先使用已解析文章/opus 身份，加载失败仍可从输入编号打开原网页；原生 Safari 图标入口和菜单复制链接均已补齐 |
| 显式允许无效 TLS 证书 | 原版有全局可选开关；旧原生证据将其缩成仅私有 WebDAV/SponsorBlock 导入锚点，却标为 implemented | 恢复同义默认关闭的“允许无效证书”开关，实际 URLSession、NW HTTP/1.1、WK 与 AVFoundation 认证消费者共用策略；纳入原版/原生备份及设置搜索，旧证据同步修正 |

推荐分区设置的分组改为“分区过滤”，并同步真实 settingAnchor 与生成的搜索索引，避免仍只称“热门与排行”而遗漏移动推荐范围

## 实际审查的操作链

以下按用户操作归组，既追页面入口，也追实际参数、保存值和消费位置

| 范围 | 审查的具体操作 | 原版与原生消费链 |
| --- | --- | --- |
| 首页与主导航 | 六频道顺序、隐藏/恢复/重排、默认推荐频道、默认启动主栏目、头像个人页、消息入口、当前栏目重选回顶/刷新 | `HomeTabType`、home/main 控制器 → `NavigationLayout` / `NavigationRules.firstChannel` / `FeedView` / `MainNavShell.NavigationChrome`；主栏目和首页频道分别保留访问状态，账号变化失效 |
| 推荐 | web/app 来源切换、过滤广告/不可播放卡、黑名单、标题正则、分区正则、时长/播放量/点赞率、已关注豁免、刷新保留内容与分界提示、自动/手动更多 | `http/video.dart`、`recommend_filter.dart`、rcmd 控制器 → `MobileFeed` / `BiliAPI.recommendations` / `RecommendationFilter` / `FeedModel` / `VideoShelf`；web、mobile、hot/rank、related 的过滤范围分别核对 |
| 推荐反馈 | 选择服务端理由、不感兴趣/不推荐作者、撤销、账号归属与失败不重复写 | `http/video.dart` 原版 dislike/cancel → `FeedFeedback` / `CardPreferenceMutation.sendOnce` / `DiscoveryCard`；离线真实行为检查覆盖拒绝与超时后单发、独立 undo 及恢复顺序 |
| 热门与分区 | 热门快捷入口开关、21 个 UGC/PGC 榜分类、分类保留、PGC 三日参数、封面/作者/作品跳转 | hot/rank/zone 页面 → `FeedView` / `Rankings.chartBody` / `DiscoveryRanking`；普通视频进 DetailView，作品榜进入解析后的 season/episode 路径 |
| 每周必看/入站必刷 | 周次列表、选期标题/标签/提醒、全部列表与分页、点选起播位置、媒体来源供听视频 | popular_series/precious → `Rankings` / `curatedEdition` / `LibraryPlaylist`；页码与 rowID 共同构成起点，媒体 ID 进入 `.media(...kind:4)` |
| 搜索首页 | 默认词开关、热搜/置顶完整榜单、猜你想搜、200ms 联想、UID 访问、关键词历史保存/无痕、单条删除/清空、文件/剪贴板导入导出 | search 页面 → `SearchView` / `SearchSuggestionsSection` / `MoreSearch`；建议与查询走推荐用途账号，历史按同一 `search.history` 键消费 |
| 搜索结果 | 综合第一页/后续视频页、视频/用户/番剧/影视/直播/专栏、分类总数、BV/AV/短链/搜索分享链接、数字 AV 精确匹配跳转 | search_panel 各控制器 → `UnifiedSearch.searchPage` / `SearchHit.decode` / `SearchNumber` / `LinkDestination`；综合首屏和 type 分页用不同端点，课程/直播嵌入卡不误当 AV 自动跳转 |
| 搜索筛选 | 综合和视频独立的排序/时长/分区/日期，用户粉丝数/等级/顺序/类型，专栏分区与排序，筛选重置及换分类返回 | search_panel 的各自控制器 → `DiscoveryContracts.VideoSearchOptions` / `OtherSearchOptions` / `SearchFilterForm` / 每分类独立 PageList identity；日期按本地日历处理 DST 与自定义结束日 |
| 番剧/影视发现 | 我的追番/追剧预览与全部入口、追番时间表开关、国创/番剧合并日历、延迟更新信息、索引服务端筛选及分页 | bangumi/cinema/timeline/index 页面 → `PGCHome` / `SeasonCalendar` / `SeasonSchedule.merge` / `SeasonCatalog` / `SeasonIndex`；可播放 episode 优先，缺失时进 season，未把索引返回空页无限分页 |
| 话题 | 头图/统计、推荐账号读与主账号个人状态、服务端排序、展开折叠内容、游标去环、点赞/收藏、参与发布、分享/举报、失败重试 | dynamics_topic 控制器 → `TopicFeed` / `TopicTimelineState` / `TopicService`；写前读取本人状态，推荐账号与主账号不同仍分开核对，折叠请求不冒用推荐身份 |
| 阅读内容 | cv 跳 opus 与 fallback、旧 HTML/Quill/opus 正文、标题/作者/时间、引用/代码/公式/富文本链接、图集/实况/资源卡/投票/社区/文集 | article/ArticleContentModel → `ArticleReader.reading` / `ArticleBody` / `ArticleHTML` / `ArticleFormula` / `ReplyRichText` / `GalleryLink`；正文区与评论使用实际 commentID/commentType |
| 阅读布局与操作 | 竖屏正文评论连贯滚动、横屏分栏比例、图片侧预览、收藏/取消、点赞/取消、转发、评论定位、站内私信分享、分享卡片、复制/网页 | article/common dyn → `ReadingSplit` / `ArticleReader` / `linkedDiscussion` / `DynamicComposer` / `IMShareButton` / `SharePoster`；设置与消费都用 `images.sidePreview`，历史记录尊重 heartbeat 身份和 history.sync |
| 隐私与账号设置 | 黑名单管理、buvid 按账号查看/生成/修改、主账号切换、用途账号/游客/跟随主账号、用途说明、批量退出本机或服务端 | privacy_settings / setting/view → `DeviceIdentityPanel` / `SettingsAccountActions` / `AccountRolesPanel` / `AccountRoutes`；账户撤销与可选服务端退出按用户动作执行，复核中未执行真实写入 |
| 动态与评论设置 | 关键词正则、带货过滤、争议/互动内容、底部动作栏、默认动态类别、UP 面板位置/全部关注/直播展开、瀑布流、公开可见性检查、评论排序/行数/@阈值/装饰/表情预览/历史 | dyn_settings/reply_settings/style_settings → `FeedDirectory` / `DynamicFeed` / `DynamicModules` / `DynamicCard` / `ReplyFilterPanel` / `ReplyFilter` / `Discussion` / `ReplyRichText`；本轮只修 @ 阈值保存，未改并行代理的评论行为 |
| 未读设置 | 动态/消息隐藏红点数字、消息类型掩码、隐藏赞、定时动态检查周期与进入动态清理 | style/dyn 设置 → `BadgePreferences` / `UnreadTotals` / `UnreadIndicators.track` / `PiliNativeApp`；隐藏的赞也从统计掩码排除，账号切换与代次校验阻止旧结果回填 |
| 外观及交互 | 字体导入/系统字体/字重、界面缩放、横屏布局、侧栏标签/平板侧栏/悬浮底栏、深浅/纯黑/种子色/调色板、图片夜间叠色、提示透明度、触感反馈 | style/extra 设置 → `Typography` / `CustomTypefaces` / `NativeInterfaceScale` / `NavigationLayout` / `NativeTheme` / `NightCanvas` / `NightImage` / `ToastAlpha` / `TouchFeedback`；动图与弹幕刷新率消费 `display.fps` |
| 页面与图片设置 | 切页动画、系统交互返回、滚动弹簧、横向滑动阈值、刷新指示高度、缩略/大图质量、图片菜单、静默保存、实况预览与保存位置 | style/extra 设置 → `MotionSettings` / `NavigationMotion` / `ScrollRebound` / `ThresholdPager` / `NativePullRefresh` / `GallerySettings` / `GalleryFeedback` / `PictureLocationSettings`；不是只把数值存在设置表 |
| 网络设置 | HTTP 协议选择、代理、读重试次数与线性间隔、显式无效证书开关、外部浏览器偏好 | extra_settings / http/init → `ConnectionSettings` / `BiliServiceSession` / `HTTP11Connection` / `APIProxy` / `ConnectionRetry` / `ServerCertificatePolicy` / `SitePage`；读重试不重复写，重定向/来源/Cookie 规则保留 |
| 设置发现/备份/关于 | 搜索原版名称/当前值并定位控件、条件隐藏项先定位前置开关、导入导出设置、WebDAV 版本冲突、数据包恢复、清理缓存/日志、重置、版本检查/源码许可 | setting_search/about 页面 → `SettingSearchRow` / `NativeSettingsResults.destination` / `SettingsRestore` / `BackupFormat` / `WebBackup` / `DataPack` / `AboutPanel` / `ReleaseUpdates`；本轮扩展 TLS 字段的真实双向迁移与错误类型拒绝 |

## 原生系统集成与仓库/交付

- `PiliNativeApp` 是 SwiftUI `@main`，`Package.swift` 从本机 Wire、ArchiveKit、MediaKit、ColorKit 依赖构建，界面没有嵌入 Flutter。原项目 Dart 保留用于固定基线与追溯，不参与原生包运行
- 自定义 `piliplus`/`bilibili` URL → `onOpenURL` → `SharedLink` → `IncomingRoute` → `LinkDestination`；根路由回首页，收藏、历史、下载、搜索、直播、阅读与播放资源有实际 destination。站内外页面由 `SitePage` 与用户外部浏览器偏好处理
- `DownloadLifecycle` 挂到 UIApplicationDelegate，后台 URLSession 完成事件归还系统 completion，场景变化与账号变化通知现有音频、投屏、睡眠和视频状态模块。本轮 TLS 基类明确保留后台完成事件的虚函数，避免覆盖下游处理
- 所有 package/check/evidence 输入由 `review_receipts.current_fingerprint` 按内容绑定，包含新建未跟踪输入与删除；final.json 自身单独排除，允许只提交结论。14 域指定证据、三组真实执行日志/未签名包、完整提交及指纹必须同源
- 签前门不能用 passed 字符串代替执行收据；签后 `review_delivery` 要核对完整 IPA 哈希、冻结 unsigned 的实际业务包内容、原生 Mach-O、团队/开发 profile、Apple profile 根链、签发证书和目标设备。合法 `XTL-{同一已验证团队}.base` 前缀仅在签章/profile 身份验证后规范化，其余元数据和资源精确比较
- 本轮只读 `Native/dist/PiliNative-signed.ipa` 沿真实 inspect 路径通过 native arm64 / signed personal development profile / package 校验。该保存包的代码早于本轮修复，正式新源码包须由根审查冻结后重新构建；本轮没有签名、安装或使用真实账号发送操作

## 本轮实际执行结果

| 现有检查/操作 | 结果 |
| --- | --- |
| 从 Checks/run.sh 提取既有 PortBehaviorCheck 编译命令并运行 | PASS；生产 RecommendationFilter 增量覆盖 mobile 分区过滤先于关注豁免、正常关注豁免与 web/related 不应用分区规则 |
| `python3 Checks/discovery_readback.py`（离线） | PASS；生产搜索筛选、DST、排行/分区、混合卡路由、屏蔽作者与反馈单次提交/撤销路径 |
| `bash Checks/setting_search.sh` | PASS；316 个真实控件锚点、唯一目标、原版名称、实时标量值、宽字符折叠、网络配置 |
| 从 Checks/run.sh 提取既有 BackupCheck 编译命令并运行 | PASS；含 badCertificateCallback=true 原版→原生→原版往返及错误数字类型拒绝 |
| `python3 Checks/backup_recovery.py` | PASS；密码互通/防篡改、两账号回滚、稀疏旧设置、敏感字段排除、真实本机 WebDAV 版本保护，新增 TLS 字段保留 |
| `python3 Checks/secure_network_loopback.py` | PASS；h2/http1.1 ALPN，四种坏证书拒绝，真实 REST/DAV 请求；生产策略默认关闭/主动开启/非 serverTrust/无 trust/重复挑战/关闭恢复 |
| `python3 Checks/vod_probe.py` | PASS；真实 Range 全量/短尾/拒绝/忽略范围/截断/取消及投屏同源镜像切换 |
| `python3 Checks/cast_receiver.py` | PASS；87 条真实本机 SOAP 交换，设备切换/控制/重连、seek、2.6MB 中继与来源撤销 |
| `python3 Checks/live_decode.py` | PASS；AVC/HEVC/AV1 CPU 真解码，HLS fmp4/MPEGTS、原压缩视频/声音保留、22s 连续滚动、外部音轨与拒绝分支 |
| `python3 Checks/media_system_signoff.py` | PASS；60 条账本、44 项设置，修正 TLS 真实实现与旧说明 |
| `python3 Checks/parity.py --summary` | PASS；只运行清单/平台来源校验，不将过期源码收据当成正式完成验收 |
| iPhoneOS27.1 SDK arm64-apple-ios17.0 typecheck | PASS；Feed/BiliAPI、SearchView、AccountRolesPanel、ReplyFilterPanel、RecommendationSettings、TopicTimeline/ArticleReader，以及本轮网络/WK/原生媒体/设置实际消费者均作为 primary 文件核对 |
| `python3 Checks/inspect_ipa.py --signed --discovery personal dist/PiliNative-signed.ipa` | PASS；只读旧实际保存包，没有生成新签章 |
| `git diff --check` | PASS |

类型检查复用本机已有 `dist/retained-sdk.py` 与 `dist/final-social-reading-sdk.py` 的 SDK/依赖参数，并在内存中扩展 primary 列表；没有新增跟踪的测试脚手架。初次回环曾暴露继承 URLSessionTaskDelegate 的默认协议见证截走派生完成回调，已补明确虚函数/override 后重跑并通过 VOD、投屏与直播完整现有检查，保留的请求完成/重定向/后台事件也一起经 SDK 编译核对

本文件的 UI/状态结论来自固定 Dart→Swift 调用链审查与上述本机检查；Apple NW/WK/AVFoundation 的实际认证回调、真机交互/无障碍/宽窄布局由最终用户验收清单继续覆盖。根审查还在并行整合移动登录和播放器工作，不能从本文件推断整仓正式完成收据已刷新
