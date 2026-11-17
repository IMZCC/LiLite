# 个人空间和资料库：按操作验收

上游 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。personal-library-signoff.json 以总清单 ID 为键，将每一行的原入口、Swift 消费者、行为及验证方式分开。命名路由表示用相同目标和参数可从应用进入原生页面；内部 Flutter 路由名本身并非网站公开 URL 规范。

| 操作 | 固定上游 → 原生实现 | 验证 |
|---|---|---|
| 空间内同时搜投稿和动态，切换结果、点当前标签回到首条 | member_search/child 的 SearchArchive 与 dynSearch → CreatorSearchResults、SpaceSearchGateway、PageList。投稿 pn/ps=20，动态 page/offset；各有计数，隐藏的结果只预取第一页。投稿按主身份，动态按推荐身份；换号/词取消旧回包；普通动态和转发的标签/正则复用 MomentListFilter | Wire 的隔离 transport 解码请求，检查 64 位 mid、页/关键词及 gRPC 拒绝；实际组装的 UGC 首 CID、PGC、课堂、未知/伪造目标在 PersonalLibraryCheck 运行，没有使用账号 |
| 收藏分类、跨夹复制/移动、清理 | fav_type.dart 的 video/bangumi/cinema/article/note/topic/cheese → FavoriteHub，资料库和分享链接都能带初始分类打开。在 CloudLibrary、FavoriteSearchAll 先从显示顺序收集选择，再在收藏转移时反序，稍后/删除不反序。收藏夹、稍后、搜索与共有播放列表保留各自分页/过滤 | PersonalLibraryCheck 的数字顺序特意不同于字典序，含重复资源与半途消失的项；CreatorPlaylistCheck 检查反向跨页、源身份变化、PGC 与失效资源 |
| 分组新建、改名、删除、顺序及为用户分组 | follow、follow_tag_sort、group_panel → ScopedFollowGroups、CreatorGroupEditor、CloudOrder。固定 0/-2/-10 不能改名删除/排序；原接口的 16 字上限；所有者在形成意图、发送和回包处核对。分组选择面板可新建并默认选中返回的 tagid，已有未保存选项不丢，保存才添加该用户 | 不联网的假 owner 10、20 测试名字验证、保留组、参数、确认后切号无请求和服务器拒绝无重试。保存真实账号的数据待本人验收 |
| 关注/粉丝/共同关注和横屏作者资料 | follow/controller 与 follow_type/controller 的 memberCardInfo 只消费 card.name；相应原生列表从 /x/web-interface/card 填回真实标题。video/member 的 memberInfo → CreatorPanelIdentity 的 /x/space/wbi/acc/info；实际头像可打开图库，昵称可复制、会员等级/硬核会员，按本人/他人/游客显示编辑资料、关注关系或登录。follower/following/likes 分别从 relation/stat 和已登录 upstat 读取；CreatorVideoPanel 向左右以当前视频定位翻页 | 原生 iOS SDK 检查这些页面、服务调用与导航；CreatorPlaylistCheck 单测真实游标算法、账号分离、拒绝时不换其他视频。来自服务的图片及关系状态待用户账号 |
| 本地/在线黑名单 | blacklist/view.dart → BlacklistManagement。本机可离线添加、预览、合并/删除、文件/系统剪贴板导入导出原版裸 UID 数组；定位参照的是完整 64 位 UID。远端按主号分页、看用户、确认移除，已读列表合并到推荐屏蔽集合。拒绝/未登录不修改云端 | 临时 UserDefaults 验证重复导入、超过 2⁵³ 的 UID、整数溢出、bool/负数/错误集合均原子失败，其余过滤偏好原样保留 |
| 空间资料、头图、推荐内容/支持者 | CreatorSpaceRecord 识别 card.relation.is_followed、space_tag、禁言、勋章、商业链接、头图昼夜和收藏背景（预览与原图分别保存）；elec、guard 面板展示真实数量、头像、排名、用户空间和充电入口。粉丝标识决定移除菜单。CreatorWorks 区别投币/点赞/音频/专栏并传首 CID，CreatorComics、CreatorGuards、SupporterRanks 保留相应前往路径 | CreatorSectionsCheck 将字符串/数值型字段混合、禁用项、无权限时缺字段、多张头图、错误图片及相同数字的不同媒体类型一起送入生产解码。打开系统相册、播放和付款未执行 |
| 观看历史、订阅与个人资料架 | ProfileShelf 按来源隔离账号，优先显示服务总数；HistoryLibrary 按 business+kid 删除并把进度传到正确分 P/课程；Subscriptions 区分收藏夹与合集、保留正反序与服务认可的所有者 | [上一轮逐操作与只读公开服务记录](personal-library-audit.md)；NavigationShellCheck 的 null/-1/0/正秒数和混合类型；PortBehaviorCheck 的临时/永久无痕和账号用途 |
| 重复记录归属 | member_article/opus/dynamics 及收藏的专栏/话题/笔记从空间和资料库可正确进入，正文交互、发布/私信及笔记编辑各自另签。上游 README 的“用户相关”为多域章节，单列 cross-domain；其余按行为逐项签核 | 不把路径数量或通过类型检查的视图数当作已经在真机执行的写操作 |

可重跑：在 Native 目录运行 bash Checks/personal_library.sh、bash Checks/creator_playlist.sh；在 Wire 包执行 swift test --filter SpaceSearchGatewayTests（使用仓库现有工具链和缓存）。第一项也检查 JSON 中的 ID、真实原版文件/符号和 Swift 符号；若是仅有 Native 目录的归档，则校验已有 native 数据和附件。没有操作真实 B 站账号，也没有签名或装机
