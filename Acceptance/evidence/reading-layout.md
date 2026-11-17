# 动态详情、互动名单与文章阅读

基线：固定版 lib/pages/dynamics_detail/view.dart 的正文与转发/回复/点赞三个面板；lib/pages/article/view.dart 的正文、回复、头图和互动栏；lib/pages/common/dyn/common_dyn_page.dart 的横屏比例；lib/pages/dynamics/widgets/author_panel.dart、lib/models/dynamics/result.dart 的头像挂件、装扮卡、粉丝编号与作者权限

- DynamicDetail 将条目 ID 与 basic.comment_id_str/comment_type 分开：前者用于转发、点赞名单，后两者用于评论。相册入口先按 rid 查询，再使用服务返回的实际动态 ID。转发打开对应转发动态，点击名单作者打开其空间。初始数量来自 module_stat，回复与互动列表可提供新数量。没有评论目标的动态仍可浏览正文及其他互动
- 竖屏使用一个原生 List 连续滚动正文、互动选项、排序和回复；文章支持从工具栏或底栏跳到评论。横屏使用独立滚动的双栏，按当前窗口宽高判断，可在工具栏调节正文 10%…90%，默认 60%；动态、专栏和 Opus 共用 reading.bodyPercent。备份的 setting.dynamicDetailRatio 是 [正文百分数, 100−正文百分数]
- Info 本身不当作评论 ID。专栏按原版使用 CV 和类型 12；Opus 从 basic 中获取有效目标，无法解析时隐藏评论。fallback 切换到实际专栏。支持顶部相册与实况图、作者、话题社区、文集、HTML/结构化正文；正文和讨论共页。转发、点赞、收藏、跳评论均有原生入口。动态操作栏偏好也控制文章底栏。读取文章时按历史角色及本地/云端暂停状态决定是否调用 type=5 阅读记录
- 动态作者、被转发的原作者、文章作者、点赞/转发名单复用头像和认证显示；区分普通头像、挂件、卡片、粉丝编号、会员与认证，遵守装扮偏好。网页动态详情按记录观看角色读取，写操作使用指定主账号，两者分离时不以另一个账号的赞状态自动决定取消赞。只有动态本人的账号可更改公开/仅自己可见、评论精选和开放状态；评论操作须先读取服务端 can_modify
- 验证：解析实际 Swift 源，主机合成 REST 记录使用互不相同的动态 / 评论 ID、作者及被转发作者、两类卡片字段、挂件和会员，校验无效 comment_id/type 不会打开评论。Wire 的现有 LikeList/RepostList 夹具通过，检查认证、标号前导零和游标，未对真实账号发送点赞、转发、收藏、历史或评论写请求
- 后续设备验收：横竖屏或 iPad 分屏后滚动位置、按比例后超长文章和图片排版、VoiceOver 焦点、弹出评论编辑器与互动菜单。账号写操作仅做了代码和协议层核对
