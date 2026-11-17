# 直播互动核查

对照固定源码 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a，未发送真实弹幕、举报、屏蔽、反馈或点赞；没有进行房管写操作

| 原版入口 | 原生实现与核查 |
| --- | --- |
| lib/pages/live_room/widgets/chat_panel.dart 的普通弹幕菜单；controller.dart 的 DANMU_MSG；lib/models_new/live/live_danmaku/danmaku_msg.dart 的历史记录 | LiveMessageSource 从历史返回的 user/base、check_info 和原始 id_str 解析；实时消息从 info[0][15] 的 user、extra，以及 info[9] 的凭据解析。旧 UID/昵称可用于显示，缺少消息凭据或新旧身份冲突不能举报。房间以 room_init 的 room_id 为准，UI 的 UUID 不参加任何表单 |
| 举报弹幕 / 举报醒目留言 | 普通弹幕的 /xlive/web-ucenter/v1/dMReport/Report 提交原文、tuid、真实签名、ts、dm_type、未经数字转换的 id_str、数字 reason_id；SC 的 /av/v1/SuperChat/report 提交原始 UID、消息 ID、token、ts 和文字 reason_id。没有 ts 的 SC 仍可显示，不再把开始时间当作举报凭据。点击留言后再选择原因、明确提交；主账号与房间在打开操作时锁定 |
| 复制、发送者/被回复者主页、@TA、个人屏蔽 | 复制结构化留言信息；回复草稿保留 room、account、发送者 UID 和消息原 ID，提交使用上游拼写 replay_dmid 与 reply_mid；可取消，单独的表情发送不带回复信息。普通或付费留言可单独屏蔽发送者，确认后调用 /liveact/shield_user，成功后过滤列表和画面；保留关键词与用户管理。观看账号独立于主账号时，编辑和读取个人规则仍匹配主账号 |
| 实时弹幕显示与点选 | 仅实时到达的普通消息进入播放画面，历史预载不会被当作新弹幕。使用已有 BulletOverlay 的真实播放器时钟、字体、区域、滚动/定点、颜色、轨道避让与屏蔽；推流缓冲时位置随画面暂停。应用播放控件下启用弹幕点选后，由原生轨道的命中结果找回同一条 LiveLine，从原消息凭据打开操作；系统 AVKit 的只读画面仍可从聊天列表点选。聊天室支持原生富文本表情、点亮的勋章、主播标记、回复对象，阅读旧消息时可以回到底部 |
| lib/pages/live_room/controller.dart 与 lib/http/live.dart 的直播点赞 | 每次按钮点击只计一次，800 毫秒内的实际点击合并，上报 click_time、room_id、anchor_id、观看账号 UID 与同一账号 CSRF；按原始字段做 WBI 签名，不额外添加字段。离开前取消尚未发送的批次，没有自动点赞或自动重试 |
| lib/pages/live/widgets/live_item_app.dart 的推荐反馈和 live/controller.dart 的分区排序 | 直播列表可切换网页/移动端推荐；移动端读取 small_card_v1、my_idol_v1、area_entrance_v3、has_more，分区读取 new_tags 的服务排序。仅服务返回的 feedback.reasons 可选；提交原卡片实际房号、推荐页码、所选 id 和 id_type，不用展示字段 reason_id 替代。移动端授权与推荐账号绑定，使用 iOS 客户端参数；有副作用的 GET 不使用网络层读请求重试。封面可切换首帧、打开原生图库保存 |
| 主播关注、房管禁言和订阅分区 | 直播间菜单可进入真实主播主页，在既有 Native CreatorSpace 读关系和关注/取消。固定版本的 lib/pages/live、live_area、live_area_detail、live_room 没有「订阅直播分区」或房管对其他人禁言的入口。lib/http/live.dart 的 liveSetSilent 只有声明，表单无目标 UID、无房间，不作为房管接口；个人屏蔽不会冒充房管操作 |

本地验证：WSL swiftc 编译并运行 Checks/LiveInteractionCheck.swift（依赖 Network/ServiceError.swift、Network/ServiceID.swift、Live/LiveModels.swift、Live/SuperChatData.swift）。覆盖同一弹幕的两种原始格式、超大/带前导零 ID、旧消息与缺失或冲突凭据、跨账号/跨房回复、两种举报实际表单、推荐卡片字段和拒绝非本卡片原因、仅真实点击计数，以及预取消息不进入实时轨道。用当前 iOS Release 的 frontend、SDK、模块和宏参数，独立 typecheck 12 个变更/新增 Swift 文件

在线边界：在无 Cookie、无 token 的情况下，仅对移动端直播推荐列表做了一次只读请求，得到 HTTP 412；没有重试或模拟原项目 Android 设备指纹。保留可手动选择的网页列表。账号授权后的移动端推荐、服务是否接受原生写请求、真机触控命中和全屏显示仍待整体联测
