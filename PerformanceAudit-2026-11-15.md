# 原生 iOS 性能排查与修复记录

范围：`native/ios` 分支的 `Native/Sources/PiliNative`，重点检查首页、动态、评论、频道切换、图片和播放器

本次修改 13 个 Swift 文件，仅做性能处理，未构建、安装或提交，也未新增测试用例
下列行号为本次复核时的位置，播放器和评论界面代理继续修改后可能移动

1. **高 · 已修：动态瀑布流滚动重复计算完整布局**
   - 位置：`Social/FeedWaterfall.swift:18`、`Social/FeedWaterfall.swift:33`、`Social/FeedColumnPlan.swift:11`
   - 原因：滚动区间 `region` 与布局规划在同一视图，跨越每个 128 pt 区间都会遍历全部条目、重新分列，再扫描全部矩形找可见卡片
   - 修改：把滚动状态移到独立可见窗口子视图，保留原布局规划与测量；每列保存索引，通过二分查找定位窗口内卡片，再按原条目顺序展示
   - 保持：列宽、间距、预加载边界、卡片 ID、从右到左布局和无障碍顺序

2. **高 · 已修：评论富文本在 body 中重复解析**
   - 位置：`Social/ReplyRichText.swift:52`、`Social/ReplyTextLinks.swift:5`
   - 原因：每次表情图片到达、展开/收起或父视图更新，都重新执行链接检测、时间戳正则、文本范围搜索及节点排序
   - 修改：增加随行视图保留的解析缓存，比较正文、表情元数据、提及、跳转链接、话题、投票、词语搜索开关和视频时长，输入不变时直接复用文档
   - 保持：翻译或链接元数据变化时重新解析；缓存不发布额外视图更新

3. **中 · 待界面代理处理：评论批量转换和过滤仍在主线程**
   - 位置：`Social/Discussion.swift:1120`、`Social/Discussion.swift:1149`
   - 原因：`load` 被标记为 `@MainActor`，网络请求返回后，在主线程执行 `Reply(wire, includePreviews:)`、顶层及预览评论过滤、正则匹配
   - 建议：先捕获过滤设置、隐藏 ID、介绍文本及请求身份，再在后台任务转换和过滤整批数据；回主线程后检查取消、账号、排序和请求身份，再更新页面状态
   - 此文件属于禁止修改范围，本次没有编辑

4. **中 · 已修：高能进度 JSON 在主线程解析**
   - 位置：`Playback/TimelineAssets.swift:111`
   - 原因：`TimelineState` 的主线程任务下载后直接调用 `ActivityTrend.parse`，数据上限为 2 MB / 200,000 个采样值，包含 JSON 解码和全量校验
   - 修改：解析放到后台任务，传递取消信号，保留原有播放来源检查，最终只在主线程发布结果

5. **中 · 已修：评论本地缩略图同步读盘及原尺寸加载**
   - 位置：`Social/ReplyComposeAssets.swift:110`、`Social/ReplyComposeAssets.swift:134`、`Social/DynamicPhotoDraft.swift:18`
   - 原因：评论图片条在构建每张缩略图时直接调用 `UIImage(contentsOfFile:)`，输入或排列更新会重复经过文件读取路径
   - 修改：用独立缩略图视图后台读盘、按 75 pt 与屏幕倍率降采样，并立即解码；同一文件和尺寸复用已加载图片，离开视图时取消任务
   - 保持：原缩略图尺寸、填充方式、占位色、裁剪、移动和移除操作

6. **中 · 已修：倍速播放放大进度发布频率**
   - 位置：`Playback/ViewportTimeline.swift:97`
   - 原因：AVPlayer 的 0.25 秒周期观察器按媒体时间回调，原逻辑每次都发布进度，因此倍速越高，进度控件更新越密集
   - 修改：普通时钟回调按系统运行时间间隔 0.25 秒发布；拖动跳转、时间跳变和播放状态变化仍立即更新
   - 保持：`PlayerModel` 中用于片段跳过和弹幕切段的采样精度

7. **中 · 已修：隐藏页面分页继续运行，空推荐页反复首刷**
   - 位置：`Library/PageList.swift:95`、`Library/Feed.swift:345`、`Settings/MainNavShell.swift:244`
   - 原因：分页哨兵和按钮创建的非结构化任务没有持有句柄，页面离开后仍继续；底部标签未向目录传播活动状态；首页把“列表为空”当成“从未加载”，空结果会随标签切换重复请求
   - 修改：持有分页任务并在离开或隐藏时取消；向子页面传播当前标签是否活动；用成功加载状态区分空结果与未加载；分页触发条件包含忙碌/活动状态，取消后重新进入仍能恢复自动加载
   - 保持：已加载内容、滚动位置、下拉刷新和手动重试

8. **中 · 已修：远程图片首次测量前请求及多尺寸重复下载**
   - 位置：`Library/RemoteArtwork.swift:127`、`Library/RemoteArtwork.swift:249`
   - 原因：默认 384 px 请求可能早于实际几何尺寸发出，随后被取消重启；同一 URL 的不同尺寸原本只能共享完全相同的任务键
   - 修改：等待首个几何尺寸再加载；同 URL、同下载字节上限的小尺寸请求可以加入已在进行的大尺寸解码，共享原有等待者计数及取消逻辑
   - 保持：已有内存/磁盘缓存规则、公开图片判定、字节限制、后台解码、分档尺寸、2048 px 上限和淡入方式

9. **中 · 待界面代理处理：播放器已完全折叠后仍接收逐帧无效通知**
   - 位置：`Playback/PlaybackPanels.swift:135`、`Playback/PlaybackPanels.swift:236`、`Playback/PlaybackPanels.swift:247`
   - 原因：滚动偏移每次都写入可观察的 `PanelFold.offset`；`progress` 到渲染阶段才夹到 0...1，播放器已经完全折叠后，继续滚动仍使折叠头部、栏和状态条失效
   - 建议：原始偏移用不参与观察的字段保存，单独发布夹到 0...limit 的有效偏移，只在有效值变化时通知；limit 改变时重新计算，折叠阈值也单独去重，保留暂停时的跟手折叠
   - 此文件属于禁止修改范围，本次没有编辑

10. **低 · 已修：列表日期格式化反复创建 DateFormatter**
    - 位置：`Library/MediaRow.swift:103`
    - 原因：视频、历史、收藏等行每次调用 `MediaStats.published`，都会为较旧日期新建格式化器并配置 locale/dateFormat
    - 修改：复用两种固定格式的格式化器，使用自动更新时区；相对时间分支和输出格式保持不变

11. **低 · 待界面代理处理：逐行解码评论设置**
    - 位置：`Social/Discussion.swift:282`
    - 原因：`lineLimit` 每次求值都 `JSONDecoder().decode`，各评论行创建 `TranslatableReply` 时都会读取
    - 建议：按 `replySettings` 的 Data 缓存解码结果，可复用 `DecodedSettingCache`，设置改变时刷新一次
    - 此文件属于禁止修改范围，本次没有编辑

其余已检查的主路径：

- `PlayerModel` 已把进度发布拆到 `PlaybackProgress`，正常进度不会通过整页模型发布，未重复改造
- `ArtworkStore` 已使用后台 ImageIO 降采样、NSCache 和受缓存策略控制的 URLCache，未发现主线程整图解码路径
- 首页、动态、评论主体已有 Lazy 容器或 List，主条目使用服务端身份，未把账号/筛选变化导致的有意重建当成错误
- `BiliAPI` 为 actor，常规网络 JSON 解码已不在 UI actor；评论主文件返回后的映射和高能进度解析是另外的主线程路径
- 播放器、视口时钟、弹幕层的周期观察器已有解绑路径；滚动折叠的大部分高频观察也已限制在子视图，剩余问题见上文

验证与交接：

- 13 个修改文件通过 `swiftc -frontend -parse -swift-version 5` 纯语法解析，没有编译、链接或调用构建脚本
- `git diff --check` 通过，13 个修改文件均通过严格 UTF-8 解码检查
- 修正了所编辑 `ReplyRichText.swift` 内一处原有的 UUID 初始化与带类型属性混合声明；本次新增存储属性均逐行声明
- 没有构建、安装、提交、注入真机，也没有新增测试文件；类型检查和真机性能复核由界面代理后续统一构建处理
- 工作区同时出现了界面代理对播放器等文件的修改，这些改动未被覆盖，不属于本次性能修复清单

本次修改文件：

`Library/Feed.swift`、`Library/MediaRow.swift`、`Library/PageList.swift`、`Library/RemoteArtwork.swift`、`Playback/TimelineAssets.swift`、`Playback/ViewportTimeline.swift`、`Settings/MainNavShell.swift`、`Social/DynamicPhotoDraft.swift`、`Social/FeedColumnPlan.swift`、`Social/FeedWaterfall.swift`、`Social/ReplyComposeAssets.swift`、`Social/ReplyRichText.swift`、`Social/ReplyTextLinks.swift`

## 第二轮：其余页面、直播长连接与任务生命周期

范围：继续检查 `native/ios` 分支，以下路径均相对 `Native/Sources/PiliNative`

本轮修改 21 个 Swift 文件，其中新增 3 个辅助文件；未修改第一轮列出的 13 个 Swift 文件，也未修改约定由 Claude 负责的文件
行号为本轮完成时的位置，协作中的文件后续可能移动

### 按严重程度列出的发现与修复

1. **高 · 已修：直播压缩包与事件 JSON 在主线程连续解析**
   - 位置：`Live/LiveChat.swift:143`、`Live/LiveChatBatch.swift:14`
   - 原因：`LiveChat` 为 `@MainActor`，原接收循环在网络返回后直接执行 `LivePackets.decode`，随后逐条执行 JSONSerialization、弹幕字段转换和醒目留言解码；协议允许解压后总计 8 MB、最多 32,000 帧，热门直播间的突发包会占用 UI 线程
   - 修改：每个 WebSocket 数据包由一个可取消的后台任务顺序解包和解析，返回 Sendable 值类型事件；主线程只处理状态与列表合并，回写前检查连接 generation 和取消状态
   - 保持：认证、心跳启动、服务端错误、消息顺序、普通弹幕去重、醒目留言删除和未知事件的裁剪语义；未增加并行接收者或无界消息队列

2. **中 · 已修：直播列表逐条发布、复制及反复过滤**
   - 位置：`Live/LiveChat.swift:150`、`Live/LiveChat.swift:179`、`Live/LiveViews.swift:361`
   - 原因：一个包中的每条弹幕都修改 `@Published lines`，追加后还可能再次修改以裁剪；聊天行 onAppear、滚动定位和末条 ID 查询分别调用完整的屏蔽过滤
   - 修改：在局部数组中按原顺序应用整个包，发生变化时只发布一次；仍逐条保持最近 250 条的去重与裁剪窗口；房间标题、人气、观看数相同时不再发布；一次 conversation 求值只过滤一次列表
   - 保持：已有“阅读旧消息 / 回到底部”行为、列表上限和屏蔽规则

3. **中 · 已修：私信正文和卡片随着视图更新反复解析**
   - 位置：`Social/Inbox.swift:34`、`Social/IMMessageContentCache.swift:5`、`Social/IMContentView.swift:6`
   - 原因：`DirectMessage.payload` 每次访问都将 content 转 Data 并解析 JSON，text、image、转发信息和卡片渲染都会走此路径；卡片内部的嵌套 JSON 与链接转换也在 body 中重复执行
   - 修改：每条消息持有自己的解析缓存，复用 payload 和渲染卡片；状态变化时按消息类型 / 撤回状态刷新卡片；显式 CodingKeys 保持原网络字段不变
   - 缓存生命周期：仅由消息对象持有，随消息 / 会话释放，无全局私信缓存；用锁保护并发读写，解析在锁外执行

4. **中 · 已修：专栏每张图片都重新扫描全文并创建图库**
   - 位置：`Discover/ArticleReader.swift:228`、`Discover/ArticleReader.swift:565`、`Discover/ArticleReader.swift:767`
   - 原因：articlePhoto 每次构建都对全部 blocks 做 compactMap，再线性查找图片索引，图文越长开销越大；分享菜单也反复扫描正文寻找首图
   - 修改：加载文档时建立图库数组和图片到首个索引的字典，正文图片与分享菜单直接复用；正文 ForEach 改为遍历原数组索引，避免额外创建 enumerated 数组
   - 保持：原图顺序、重复图片点开时定位到首个匹配项、实况照片和分享封面优先级

5. **中 · 已修：专栏公式的逐字节读取与响应解析占用主线程，回看时重复下载**
   - 位置：`Discover/ArticleFormula.swift:22`、`Discover/ArticleFormulaStore.swift:4`、`Discover/ArticleFormulaStore.swift:35`
   - 原因：视图 task 在 UI actor 上累计响应字节、解析 SVG 头和正则高度，单个响应允许达 1 MB；已离开懒加载窗口的相同公式再次出现时重新请求
   - 修改：用独立 actor 负责响应读取与解析，成功结果放入 NSCache，设置 64 项 / 4 MB 成本上限；视图只发布 data 和高度
   - 保持：原请求地址、8 秒超时、1 MB 响应限制、无 Cookie 请求、公式长度限制、SVG 校验和深浅色 WebView 呈现；取消后不发布或缓存旧结果

6. **中 · 已修：收藏夹封面在主线程降采样，草稿预览在 body 中解码**
   - 位置：`Library/FolderCover.swift:137`、`Library/FolderCover.swift:169`
   - 原因：照片选择器返回原始 Data 后，在视图任务中直接调用 ImageIO；已裁剪草稿每次重绘都重新调用 UIImage(data:)
   - 修改：选图降采样和立即解码放到可取消的后台任务，继续使用 2048 px 上限；草稿使用独立预览视图，按 Data 身份后台解码并保留结果，解码上限与现有裁剪输出的 1280 px 一致
   - 保持：原文件大小限制、裁剪比例、缩放及定位、上传 JPEG、预览最大高度

7. **中 · 已修：私信历史与通知列表的专用分页在离开后继续工作**
   - 位置：`Social/ConversationTimeline.swift:57`、`Social/ConversationTimeline.swift:69`、`Social/GroupedNoticeList.swift:56`、`Social/GroupedNoticeList.swift:67`
   - 原因：这些页面未使用第一轮修过的通用分页任务，按钮、首行和底部哨兵直接创建没有句柄的 Task
   - 修改：持有手动 / 自动分页句柄，离开或首刷替代分页时取消并失效旧请求标记，完成后清理句柄；请求入口与回写处检查取消，防止刚退出页面的任务继续启动或写回
   - 附带减少通知列表工作量：分组数组和动画 ID 数组只在加载结果变化时生成，body 不再每次遍历全部通知
   - 保持：首刷、重试、更早消息、分页合并及原滚动锚点

8. **中 · 已修：消息中心多来源通知触发脱离视图生命周期的未读请求**
   - 位置：`Social/Inbox.swift:164`、`Social/Inbox.swift:231`
   - 原因：首次进入、未读通知和回前台分别启动请求；onDisappear 主动发出的未读通知还会被本页收到并再次创建 Task
   - 修改：统一为由账号、授权类型、可见 / 前台状态和通知 revision 驱动的视图 task；状态改变取消旧请求；页面退出前先标记不可见，忽略本页退出通知和隐藏期间的通知
   - 保持：首次进入、回前台、通知到达和用户下拉刷新的刷新入口

9. **中 · 已修：独立请求被不必要地串行等待**
   - 位置：`Social/Creators.swift:308`、`Social/CreatorVideoPanel.swift:121`、`Live/LiveChat.swift:72`、`Discover/SeasonAccess.swift:11`
   - UP 主空间：空间主体与关注关系并发请求
   - UP 主视频面板：粉丝 / 关注统计与获赞统计并发请求，游客仍不请求需要登录的获赞接口
   - 直播：最近聊天记录与弹幕服务器配置并发请求，仍先应用历史记录再进入实时接收
   - 番剧：播放账号与历史账号不同时，两份独立资料并发读取；只从历史账号提取观看进度，播放权限和剧集列表仍来自播放账号
   - 实现：使用结构化 async let，沿用原账号核验、错误显示和取消检查；没有新增自动重试或提高分页并发数

10. **中 · 留给 Claude：我的页面横向资料卡分页没有传播取消**
    - 位置：`Account/ProfileShelf.swift:103`、`Account/ProfileShelf.swift:131`、`Account/ProfileStore.swift:132`、`Account/ProfileStore.swift:152`、`Account/ProfileStore.swift:177`
    - 原因：ProfileShelf 不读取根标签传入的 activeCatalogPage；SwiftUI task 取消后，ProfileShelfState 内部另建的 Task 仍由共享 store 持有，只 await task.value 不会把取消传给它，返回后的合并和发布可以继续执行
    - 建议：在视图层按标签活动状态管理首刷 / 分页，离开时解除加载需求；模型对没有其他等待者的请求取消底层 flight，同时保留已加载条目、游标和滚动位置；后台合并任务也要接收取消
    - 此路径不属于第一轮 PageList 修复，本轮只记录，没有编辑 Profile 相关文件

11. **低 · 已修：番剧与合集面板重复整理完整目录**
    - 位置：`Discover/SeasonCatalogView.swift:5`、`Discover/SeasonModels.swift:84`、`Playback/ArchiveCollectionPanel.swift:33`
    - 原因：番剧 body 多次读取 info.groups 和 info.resume，每次重新过滤去重、应用权限并生成选集数组；没有命中继续播放项时 resume 还会再次重建 groups；合集的图片判空和 GalleryLink 各遍历一次全部分集封面
    - 修改：番剧视图由同一组目录计算继续播放项并复用，resume 支持传入已整理目录；可缓存数量只查到第二个匹配项，标签名预先转 Set；合集每次 body 只生成一次图库
    - 保持：选集顺序、不可播放状态、继续播放优先级、分 P 和倒序操作

12. **低 · 已修：设置搜索每次输入都重新归一化全部固定词条**
    - 位置：`Settings/SettingSearchRow.swift:114`、`Settings/SettingSearchRow.swift:120`
    - 原因：每次查询都重复对所有标题、分区和别名做 Unicode 折叠与大小写转换
    - 修改：固定词条的归一化结果预建索引，仅对当前查询和动态设置值进行转换；“已开启 / 已关闭”等当前状态仍实时读取
    - 保持：匹配条件、结果评分、排序和跳转锚点

### 页面与高频路径覆盖记录

- 启动 / 底部标签：读取 `PiliNativeApp.swift`、`Settings/MainNavShell.swift`、`Settings/NavigationLayout.swift`、`Library/RetainedDeck.swift`；底部标签使用稳定枚举身份，未发现把普通标签切换绑定到根视图 id；账号切换及明确返回首页的 id 保留
- 动态详情：检查 `Social/DynamicDetail.swift`、`Social/DynamicActivityList.swift` 的 body、资料加载、互动分页及阅读布局；已有 rich-text 缓存和通用分页继续使用，未重复第一轮评论处理
- UP 主空间：检查 `Social/Creators.swift`、`CreatorSections.swift`、`CreatorVideoPanel.swift`、`CreatorArchiveBrowser.swift`、`CreatorSearchResults.swift`；保留既有请求身份和已加载标记，修复独立资料串行加载
- 我的页面：只读 `Account/ProfileView.swift`、`ProfileOverview.swift`、`ProfileComponents.swift`、`ProfileShelf.swift`、`ProfileStore.swift`；资料已有短时缓存和同账号请求复用，新增交接事项为横向资料卡分页取消
- 收藏 / 历史 / 稍后再看：检查 `Library/FavoriteHub.swift`、`FavoriteFolderScreen.swift`、`HistoryLibrary.swift`、`CloudLibrary.swift`、`LaterMedia.swift`；列表复用 PageList，修改与筛选触发的刷新保持；大类切换同时承担页面工具栏与筛选状态重置，未只删除 id 或引入隐藏页面工具栏叠加；封面解码已修
- 搜索结果：检查 `Discover/SearchView.swift`、`UnifiedSearch.swift`、`SearchHit.swift`、`MoreSearch.swift`；结果使用 RetainedDeck 和分页，转换发生在 API actor，建议词有延迟与取消，未新增全局结果缓存
- 番剧 / 影视：检查 `Discover/Seasons.swift`、`SeasonIndex.swift`、`SeasonLibrary.swift`、`SeasonCatalogView.swift`、`SeasonAccess.swift`、`SeasonEpisodeSelection.swift`；索引页已有访问页保留和 active 分页限制，修复目录重复计算与双账号资料串行读取
- 直播：检查 `Live/LiveViews.swift`、`LiveChat.swift`、`LiveTrackView.swift`、`LiveModels.swift`、`SuperChatData.swift`、`LiveShield.swift`；本轮重点修复解包 / 解析 / 发布 / 列表过滤，原心跳、连接和覆盖层关闭路径保留
- 私信 / 消息：检查 `Social/Inbox.swift`、`IMSessions.swift`、`IMContentView.swift`、`IMCardBody.swift`、`ConversationTimeline.swift`、`NoticeViews.swift`、`GroupedNoticeList.swift`；修复正文缓存、请求生命周期和通知分组计算
- 设置：检查 `Settings/Settings.swift`、`SettingSearchViews.swift`、`SettingSearchRow.swift`、`SettingSearchTerms.swift`、`SettingsWidePane.swift`；AnyView 主要用于单个设置目标页，并非逐条大量擦除列表行类型；修复固定搜索索引
- 专栏：检查 `Discover/ArticleReader.swift`、`ArticleBody.swift`、`ArticleFormula.swift`；修复全文图库重复扫描与公式处理
- 合集 / 选集：检查 `Playback/ArchiveCollectionPanel.swift`、`ArchiveChapterPanel.swift`、`Discover/SeasonEpisodeSelection.swift`；保留 List 的行身份和分页 / 定位行为，减少合集与番剧目录重复计算
- 弹幕：检查 `Danmaku/BulletOverlay.swift`、`BulletLayerSurface.swift`、`BulletLayoutPlan.swift`、`BulletRasterCache.swift`、`BulletTrackFrame.swift`、`SegmentedComments.swift` 和直播时间线；已有后台排版与栅格化、32 MB / 512 项栅格缓存、常规 96 / 特效 24 条时间窗口和离窗解绑，未把它们改回逐帧 SwiftUI 绘制，也未重复重写
- 图片 / 缓存 / 生命周期：远程图片继续沿用第一轮的降采样与有界缓存；本轮只新增有上限的公式缓存和随消息释放的私信缓存，修复专用列表 Task 的取消与句柄清理

### 静态复核与交接

- 本轮 21 个 Swift 文件通过 `swiftc -frontend -parse -swift-version 5` 纯语法解析
- 本轮文件通过严格 UTF-8 解码、NUL / 行尾空白检查；`git diff --check` 通过
- 人工复核了直播认证与错误分支、普通消息去重 / 250 条裁剪 / 醒目留言删除、请求取消与连接身份、私信缓存字段与撤回状态、重复图片索引、番剧权限和继续播放顺序
- 新增存储属性逐行声明，没有引入 UUID 初始化与带类型属性的混合声明
- 未构建、安装或提交，未新增测试用例；类型检查和真机性能复核由 Claude 后续统一完成
- 工作区同期有 Claude 对播放器、Profile、网络和返回手势文件的修改，不纳入下列本轮文件清单，也没有覆盖这些修改

本轮修改文件：

`Discover/ArticleFormula.swift`、`Discover/ArticleReader.swift`、`Discover/SeasonAccess.swift`、`Discover/SeasonCatalogView.swift`、`Discover/SeasonModels.swift`、`Library/FolderCover.swift`、`Live/LiveChat.swift`、`Live/LiveModels.swift`、`Live/LiveViews.swift`、`Live/SuperChatData.swift`、`Playback/ArchiveCollectionPanel.swift`、`Settings/SettingSearchRow.swift`、`Social/ConversationTimeline.swift`、`Social/CreatorVideoPanel.swift`、`Social/Creators.swift`、`Social/GroupedNoticeList.swift`、`Social/IMContentView.swift`、`Social/Inbox.swift`

本轮新增文件：

`Discover/ArticleFormulaStore.swift`、`Live/LiveChatBatch.swift`、`Social/IMMessageContentCache.swift`
