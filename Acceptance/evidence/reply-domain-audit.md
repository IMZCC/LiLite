# 评论与楼中楼逐功能复核

基线 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。对照 lib/grpc/reply.dart、lib/http/{reply,video}.dart、lib/pages/{main_reply,my_reply,common/reply,video/reply,video/reply_reply,video/reply_new,video/reply_search_item}、lib/common/widgets/context_menu/reply_menu_helper.dart 和 lib/utils/{latex_to_unicode,latex_unicode_data}.dart。本轮未改总表。下面的“已接入”指原生可到达的功能；线上读证据与尚未实机的动作另列

| 记录 | 已接入的路径与操作 |
|---|---|
| page:main_reply、route:/mainReply、screen:video/reply | Discussion → ReplyGateway.MainList。去重主置顶/管理员置顶/投票置顶（只有作者自己的普通主楼可操作置顶）、实际主列表投票卡（仅首页，使用 voteCard.voteID / count / title）、最热/最新与精选、分页、计数、简介/作者/规则筛选、折叠区、主楼到楼中楼。未登录能读、查看作者、保存评论海报或本地屏蔽 |
| screen:video/reply_reply | 从楼内预览、通知或已存评论传原 root/anchor。DetailList 首屏包含根楼且子楼按 rpid 定点，后页不重复主楼；DialogList 使用真正 dialogID，从对话可按 parent 跳回原回复；FoldList 复用接口下发的整份分页对象。楼内预览的作者、富文本内链、查看回复入口各自可点。普通稿件和影视读 aid/type 1；课堂用课时 id/type 33 |
| screen:video/reply_new | 原生输入框与光标、表情包、输入 @ 或点“提到用户”、可多选用户、插入当前光标、保留未编辑的内容 URL / 提及帐号、支持选中区替换。对二楼以下回复补上原版的“回复 @姓名 :”前缀，同时独立发送 root/parent。所有楼层允许显式同步动态；只给主楼开放最多九张图，受服务返回的图片/截图状态约束。照片可裁剪、排序、去掉；可插当前视频进度、预览当前帧再加入（截图绑定当前主体、CID 并排除试看）。取消后草稿在当前评论页面按账号、主体、根楼、父楼隔离恢复；离开页面并不是全局永久草稿箱。公式用 $ 或 $$ 包住后可转成 Unicode 并还原，保留现有 @ 与引用的范围；无法识别的宏保留可见文本 |
| screen:video/reply_search_item、screen:video/reply_search_item/child | 原版是发表评论时“插入内容”的视频/专栏搜索，不是搜索全站评论。SearchItem 按 oid、type、keyword 与视频/专栏分类查询，保留两个栏目的结果与续页；UGC 展示真实时长，影视展示类别，专栏给封面/作者。选择行后显示标题、发布使用服务那一项的 URL；当前账号变化时结束选择 |
| page:my_reply、route:/myReply | 我的 → 我的评论，按当前账号加载客户端真实保存的回执。单行可查看富文本、作者、图片、原讨论定点及视频/专栏/图文/动态/课程来源；可保存或分享海报、复制正文、检索本机记录、检查自己评论的公开可见性、确认后删云端或仅移除本机。文件或剪贴板导出 / 合并和清空按账号隔离。原版使用的 protobuf JSON 可保留未知字段原样转出；新发 REST 回复映射图片、成员、@、表情、链接和投票。云端删除重新按 root/rpid 读取并核实 oid/type/mid；旧记录没有作者信息只给本地操作 |
| route:/replyMe、screen:msg_feed_top/reply_me | “回复我的”通知类型/删除通知/未读属于 [消息域核对](im-inbox-audit.md)，这里只覆盖进入具体主楼/子楼后在 Discussion 的定点，通知与本机“我的评论”不是同一种数据 |

**逐行菜单。** 点击作者进空间；行内进度、@、关键词、站内链接、话题、投票、表情和可选译文复用 ReplyRichText / InlineDocument。标题、正文、投票选项标识均来自当前行。点踩/点赞、取消、本人或稿件作者删除、稿件作者置顶主楼都绑定当前主账号及真正的 rpid、oid、业务 type，只有服务接受后才更新本地；不会把访客或另一角色看到的“未点赞”拿来反向切换主账号状态。举报理由与可选同时拉黑、网页举报与访客的本地屏蔽沿用 CommunityReport。跨内容类型上报携带当前实际 type（固定 Dart 原生表单此处写死为 1，原版 H5 仍带真实 pageType）；未尝试用另一类型重试。仅自己能检查公开可见性，检测只读。复制全词、自由选区、选择后站内搜索/打开和确认加入过滤（正则转义为文字）、表情 token 与源 URL 均可用。保存评论的海报保留整组附图，评论链接只在确为子楼时带二楼编号。原版调试专用“写 1000 份本地记录”没有纳入发行版

**账号与发布回执。** AccountContext / AccountJar 校验主账号；gRPC 详情使用本账号已有的移动认证或访客，HTTP 简洁列表另绑定既有的 heartbeat 角色；无法确定本人的点赞状态时提供明确的点赞/取消选择。写操作校验账号不变；发表会校验响应 code 及真实 rpid，并比对返回的 oid、type、mid、root、parent 后才能本机归档和发起公开可见性检查。服务拒绝或认证失败保留正在编辑内容。没有回报评论编号的 code=0 响应会告知不能核对，不伪造归档或向用户提示找到公开评论。只读状态阻止发布；未改授权、验证码或审核策略

**本次验证（2026-11-12）。** 在 WSL SwiftUI-Noble 运行 `PILI_PUBLIC_REPLY=1 swift test --package-path Wire --scratch-path /tmp/pili-creator-im-wire --filter ReplyGatewayTests`：5 项通过。一次匿名公开读取 oid=170001：MainList HTTP 200 / gRPC 0，20 条；DetailList 21 条；另一排序携原子楼编号能定位；DialogList 20 条。该公开样本没有折叠卡，不把它用作真实投票或折叠的证据。独立 protobuf 回包装配验证首页/下一页投票卡区别、置顶去重、fold offset/pageSize 不变、本楼/对话/目标翻译、视频/专栏独立分页、时长、兼容未知 JSON 字段及 64 位编号。备用 HTTP 的匿名旧接口在同一稿件这次返回 code 0、页计数 0，不用作评论正文证据

在 Native 目录运行 `bash Checks/reply_domain.sh` 检查实际提交字段、不同楼层与账号、错误回执和归档、插入 @ 与引用后可来回转换公式、多行矩阵、结构错误、文字过滤的转义，以及独立目录的富文本归档导出合并。原生相关源文件用 iPhoneOS 27.1 SDK / arm64 iOS 17 目标独立类型检查。实际 Apple Photos 取图裁剪、真机截帧/键盘选择与触感、投票/举报/发布/置顶等登录写操作须留给授权的设备验收；这次没有发真实评论、图片、举报、投票、点赞、删除或屏蔽账号请求

相关细项：[评论读写](discussion.md)、[正文链接](reply-text-links.md)、[筛选](comment-filter-audit.md)、[公开可见性](public-visibility.md)、[举报](community-report.md)
