# 公共页面及混入逐动作审核

固定上游 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。lib/pages/common 有 14 个目录（计根目录）、31 个 Dart 文件，不是 31 个可独立打开的页面。[逐文件机器表](common-page-actions.json) 逐项列出固定 blob 的摘要、实际直接引用该文件的 Dart 调用方、源方法和具体 Swift 消费符号。总表对应 page:common、screen:common/dyn/like_list、screen:common/dyn/repost_list

|页面组|源与原生动作|
|---|---|
|根数据页、列表页与页脚|CommonController、Data、List、Page → PageList / PageBoundary / MainNavShell：本地首屏、追加、刷新替换、账号/请求失效、已到底、重试；重选标签时先回顶，已在顶部才刷新；主栏跟随当前竖向滚动。修复已加载数据后刷新失败误重试下一页；普通列表和网格使用可见页脚取下一页，离屏不会把远端目录拉光；游标重复、清空、没有添加新行时不连续自动触发，手动载入仍可处理过滤后的剩余结果|
|共用简介与会话|CommonIntroController / FavMixin：实际核对了 VideoActions、EngagementBar、ArchiveSharePoint、LibraryPlaylist、ListenMetadata；OnlineViewers 在前台每 10 秒按当前稿件、分 P、账号重读。CommonWhisperController 在 IMSessions 接私信普通/折叠区的置顶、移除、免打扰、整组标读与清理；使用服务返回的分组/会话身份|
|动态型详情、点赞与转发|文章、音乐、动态和赛事各用真实 OID/类型，比赛 type=27 的讨论与资料现已放在同一个页面，直播/回放仍可开。点赞行补签名、等级和硬核会员；转发按 Opus summary 优先，保留表情、URL、投票 ID、图片组与实况视频，旧 description 保留带链接文字和表情。转发上、下文仍可开作者空间或那一条动态，点赞与转发各自的游标/总数不混用|
|编辑与回复、投票、折叠|富文本选择范围、@多人、站内表情、图片预览/裁剪/移除、草稿、提交锁和回执见 Compose、Discussion、ReplyComposeAssets。原版直播和私信显式覆盖 onMention 返回 null，普通弹幕走自己的文本发布；不向每个编辑器强塞同一组能力。主楼、楼中楼、二级定位、折叠与投票由 ReplyGateway / Discussion / VoteView 使用具体服务身份。原生导航打开折叠列表并可以返回原阅读位置，独立空评论仍显示适用的投票。进入/退出编辑器使用系统 sheet、键盘与可访问按钮|
|多选、搜索、倒序|收藏、历史、稍后和缓存列表支持选结果、清除/全选、确认删除和部分失败提示。搜索多选期间的返回先取消选择，保留已加载结果/筛选；不向原版无批量选择的关注搜索加写操作。订阅详情与收藏夹根据真实总数按 20 条/页从末页倒序；目录顺序与普通搜索顺序区分|
|两侧边缘返回与浮钮|slide 的实际内容入口是二级评论、选集、AI 总结、番剧简介、播放列表、视频笔记、空降片段提交、分段信息。原生覆盖独立推入页和模态根，使用 UIKit 边缘识别器、原生导航的交互返回与设置开关；媒体侧栏内嵌页面不误关外层播放器。原版浮钮对应的回复、发布或关注入口由原生工具栏/行内入口承载，工具栏交互可访问，不机械复制 Flutter 的圆钮或颜色动画|

[README 文本范围](common-readme-scope.json) 单独记录固定行号、逐行 git blame 祖先和直接子项。feat/其他 第 120 行、opt/其他 第 136 行、fix/bugs 第 141 行均无子项、议题编号、链接或可执行标准；三行的共同引入提交 33b9a9362 只写 Update README.md。这三行只能计为原文备注。第 155 行“用户相关”恰好聚合 156–163 行八项，第 204 行“设置相关”只聚合 205–211 行七项；这些分组本身不引入资格、登录签发或未明示功能。后续若某一子项有实质差异，则相应分组不能据此独立标全

验证：WSL 在 Native 执行 python3 Checks/common_pages.py，核对固定 Git 对象、31 个源文件全部直接导入方、Swift 锚点、README 字面和祖先，使用生产 PageBoundary 验证刷新/续页失败、游标循环和页脚位置。Wire 的 DynamicGatewayTests 以真实序列化 protobuf 和 gRPC 帧验证服务节点及点赞字段；3 项本地测试通过，唯一匿名联网用例保持关闭。arm64-apple-ios17.0 / iPhoneOS 27.1 对本次跨页 Swift 源和重新生成的本地 Wire 模块做类型检查。系统两侧边缘手势与各尺寸实际呈现留整包真机，不发送点赞、评论、私信或转发请求
