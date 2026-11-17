# 动态、评论和阅读终签增量

固定 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。完整的逐项结论在同目录 social-reading-signoff.json；空间、资料库、搜索和播放器的交界记录标有 ownership，跨服务账号权限不变

**带货和正则。** lib/models/dynamics/result.dart 的 DynamicsDataModel.fromJson 是首页、自选 UP、空间动态及空间内搜索都会用到的列表解析器：当前模块与 orig 模块分别匹配（不把两个来源拼成一个正则匹配范围），只从相应 major.type 取档案/合集/季或课程标题，从 additional.type 判断商品。Native 的 MomentFilterFields / MomentListFilter 接回 DynamicAPI.dynamics 及 CreatorSearchResults；首页保留自己临时隐藏 UP 的例外。空间搜索按 recommend 角色读取，而普通空间动态按其实际登记角色，写权限仍限主账号。直接打开详情不应用浏览列表屏蔽规则

**查看动态内的图片资源。** lib/pages/dynamics/widgets/rich_node_panel.dart 的 RICH_TEXT_NODE_TYPE_VIEW_PICTURE 以及 lib/http/dynamics.dart 的 dynPic：内嵌 pics 存在即实地画图组，可逐张进入图库；当节点只有资源 rid，用户点后才 GET /x/polymer/web-dynamic/v1/detail/pic，提交 id、web_location=333.1368。按当前授权展示返回的图片组，已载入结果按账号与 rid 缓存，错误/空/重试单独处理；稀疏响应不猜测动态编号，也不把服务拒绝当可见。NativeGallery 保留原图、实况信息、系统分享和本机保存

**验证。** Checks/moment_domain.sh 复用真实转换器，用同名图文/原帖边界、原文带货、非当前 major.title、独立 64 位图资源 ID、直接提供 pics、正常/空/拒绝回包检查列表和图库行为；同时覆盖动态首次/编辑/转发、草稿冲突、@ 和预约身份。Checks/notebook_domain.sh 和 Checks/reply_domain.sh 分别复核原生阅读/笔记及楼中楼、富文本与账户权限。本次没有发帖、回复、投票、发信、写笔记、填票据或发送验证码。已有访客公开读取证据见相应专项文档，没有把独立图片资源的模拟回包说成真实访问


同一轮富文本逐分支比较还修复了动态抽奖：原版节点不是用节点 rid，而是拿承载该节点的动态号打开官方结果页。原帖和转发原文分别绑定各自业务号。离线夹具检查了两者不相同时的 URL；打开结果页不会参加抽奖

最终数据核验：执行 Checks/social_signoff.py，154 条不重复记录、59 个固定上游源码锚点、90 个原生来源；账号/消息 52 项 implemented、3 项如实列 partial、1 项上游仅桌面；动态/评论/阅读 97 项 implemented、1 项仅 Android。IM 7 项回包测试通过。可选的访客网络复测实际看到公开 UP 的 OpusSpaceFlow 两页（第一页 20 条），但 LikeList 在这次匿名会话返回 gRPC 2 / -403，故该次联查整体没有通过；未换身份或重试探测。该项的原生授权调用、64 位 ID 精度、游标和拒绝分支由本地夹具核查，线上授权结果需由相应账户决定
