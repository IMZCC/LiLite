# 动态、转发、编辑与互动的二次核查

基线：PiliPlus d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。以下记录分别核对上游实际页面、Swift 从入口到业务接口的调用及可取得的回包；HTTP 常量是否出现不作为单独验收标准

| 原版记录 | 本轮核查与结果 |
| --- | --- |
| page:dynamics、page:dynamics_tab、route:/dynamics | 全部、投稿、番剧、专栏、选中 UP 的列表；关注/直播 UP 面板、账户、翻页、过滤、折叠与栏数见 dynamic-feed.md、dynamic-feed-layout.md。非详情卡片的 module_interaction 保留 rich_text_nodes，type=1 画评论图标、其余画点赞，@ 保留原 UID 可点击。卡片菜单临时屏蔽作者会刷新同账号的动态流，可在筛选菜单解除；未写入设置。固定源码刻意不把本次隐藏用于特定 UP 分栏（models/dynamics/result.dart）。访客也保留另一个持久的本机屏蔽入口 |
| page:dynamics_detail、route:/dynamicDetail、page:member_dynamics 的共用卡片 | 正文、表情、话题、图集/实况、置顶、争议、图文阅读、AV/合集/影视/课程及评论原已有入口。补普通/推荐/订阅直播、音乐、专栏、活动、播单、商品、赛事、充电抽奖、UGC、关联动作/奖品和预约。转发嵌套内容使用原作者、原动态 ID、原图集、资源/投票/话题，不拿外层编号投预约。受限或删除的附件只显示服务给的说明和权限入口。详情的评论按 comment_id_str + comment_type，转发和点赞分别按 RepostList 和 LikeList 的真游标 |
| page:dynamics_create、page:dynamics_repost | 动态、评论与转发共用可编辑文字和账户身份。图片、标题、表情、@、投票、预约、话题、评论权限、定时、转发后评论、草稿/附件隔离见 dynamic-editor.md、dynamic-edit.md。转发原帖的作者和上下文按主账号重新读。提交成功无有效 ID 显示“已提交发布”，没有伪造详情；受理的定时任务单列，私密帖的查看链接用发布主账号，只有普通公开帖才有匿名可见性检查 |
| page:dynamics_mention | 上游 dynamics_mention/controller.dart → DynamicsHttp.dynMention。原生 ComposePickers 改用分组搜索，空关键词建议、300ms 内防抖、头像、粉丝、原作者快捷项、单选和按选择顺序多选；插入光标上的 @，选择 UID 而非按显示名推断。评论单独生成 at_name_to_mid；手动改名或者将原名继续改写不保留选中人的 UID，同名两账号不会无意关联到其中一个 |
| page:dynamics_create_reserve | 原版的创建/编辑面板、默认次日 20:00、标题/直播或首映类型、5 分钟至 90 天、已有关联卡的真实 SID、当前账号。创建需要肯定的 SID，更新若未返回 SID，用同 ID 再读预约信息；原始 info 回包不总含 sub_type，此时沿用编辑面板已知的类型，不能靠该回包独立确认类型变化 |
| page:dynamics_create_vote | 动态详情/原文的投票跳到 VoteView；编辑器按 type=4、biz_id 恢复并原位编辑或移除，支持文字/图片选项和选择数，见 native-polls.md。创建和修改投票是单独服务操作，不把编辑草稿等同于已更新动态 |
| page:dynamics_select_topic、page:dynamics_topic、page:dynamics_topic_rcmd、route:/dynTopic、route:/dynTopicRcmd | 选择器搜索、推荐目录、收藏、话题顶部、排序、折叠、列表卡、参与话题和举报上下文见 topic-timeline.md；参与打开同一动态编辑器。此次再次匿名 GET 公开话题 1028161，实际 Swift 模型解出 20 张普通卡、20 张折叠卡，替换后 21 个唯一项目；推荐服务以 data=null 返回空目录 |
| page:save_panel（动态入口） | “保存动态图片”将正文、图集、转发原文及资源信息一起排版，使用原版二维码/页脚开关，照片或用户授权的图片目录、系统分享。Files 使用单独 PNG、临时写入、不覆盖同名文件；撤销目录授权报错，不把失败称为已保存。动态菜单可将原帖/转发内的 AV 或合集 BV 加入稍后再看；资源封面长按可进图库 |

## 特别容易错判的五个服务入口

| 固定接口名 | 实际入口/请求与结论 |
| --- | --- |
| createReserve、updateReserve | lib/pages/dynamics_create_reserve/controller.dart → lib/http/dynamics.dart:636/660。原生 LiveReservation 的 /x/new-reserve/up/reserve/ + create/update 是真实路径拼接，表单随账号 CSRF 发送 type=2、sub_type、from=1、title、live_plan_start_time，只有更新才发 id。并非未移植 |
| dynReserve | lib/pages/dynamics/widgets/additional_panel.dart → lib/http/dynamics.dart:525。原先只有创作者端，此次补观众端：/x/dynamic/feed/reserve/click，主账号读回卡片、本次点击携 reserve_id、cur_btn_status、dynamic_id_str 与存在时的 reserve_total。button.jump_url 优先跳转；uncheck.disable=1 禁止写。只按 final_btn_status / reserve_update / desc_update 更新；模糊回包先读回，不自动重复点击。切换主账号或 RID/按钮变化时不沿用另一个上下文 |
| dynMention | lib/pages/dynamics_mention/controller.dart:38 → /x/polymer/web-dynamic/v1/mention/search，关键词可省，web_location=333.1365。解 groups/group_name/items，不是简单列出关注/粉丝 |
| dynReaction | lib/http/dynamics.dart:856 的 HTTP 聚合方法在本基线没有 Dart 调用点。真正的动态详情通过 lib/pages/common/dyn/like_list/controller.dart 和 repost_list/controller.dart → gRPC，原生 DynamicActivityList/Wire 实现这两条。故该未出现的 HTTP 字面量不是缺失用户入口 |

## 身份、可见性与编辑边界

- 主账号与推荐/观看身份可以不同。点赞、预约、原帖转发、修改可见性、编辑/删除/置顶的信息读取都按当前主账号检查；普通浏览继续按原来配置的角色。点赞先读目标状态，必要时才明确发 up=1/2；删除/置顶再核对作者和 dyn_id，删除成功才移除卡片。举报仍走 CommunityReport 真实原因、作者/动态编号、可选黑名单的独立回执，见 community-report.md
- 动态模型真实可见范围是 module_author.icon_badge.text（上游对标 badgeText），兼容旧 badge_text。私密帖进入编辑不会重置为公开。“改为公开”先确认，在写入前再次读真实作者和状态。评论精选/关闭依据服务 up_reply_selection/up_reply 的 can_modify 和实际 status 决定动作
- 可无损重建的图文/转发保留既有图片/实况、投票、预约和话题。本人已发布的视频、音频、影视、课程、直播等资源动态可原生编辑说明：与上游相同调用 edit/dyn，只传动态编号和编辑内容；源资源 ID 参与旧版本核对，不更新视频/节目/直播本体。独立长专栏正文和无法还原的商业专用编辑卡仍走创作中心；没有用普通动态编辑器覆写原稿。对此类编辑和商业活动的线上服务具体开放条件不能划为已验收
- 图片动画、中文输入法的实际光标、相册/文件和动态隐私、审核、举报及多账号实时回包仍需综合真机验证。本轮没有向真实账号点赞、转发、投票、保存预约、发评论、举报或删除动态

## 可重跑的证据

- WSL：cd Native && bash Checks/moment_domain.sh。独立 Swift 编译并执行预约表单/服务回执、禁用/跳转/状态、受限资源、转发图片/直播/音乐/影视/话题、权益、作者所有权、资源说明编辑、发布编号、@ UID/同名冲突/UTF-16 修改；并重跑现有账户与目标隔离的图文草稿、转发、编辑附件和定时检查
- WSL：cd Native && python3 Checks/topic_readback.py，只读匿名网络样本，验证真实响应能被当前 DynamicEntry/TopicPage 接受。公开话题可随时变化，不装入必跑离线测试
- 隔离目录执行 swift test --package-path Wire --filter DynamicGatewayTests：点赞/转发翻页与动态未读两个本地测试通过；可选公开账号网络抽查默认跳过，零失败
- 本次用 iPhoneOS 27.1 SDK、arm64 iOS 17 对 18 个动态、评论、海报、数据模型和请求文件做独立类型检查，不占用主集成 Release
