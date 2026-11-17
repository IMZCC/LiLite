# 直播醒目留言

对照版本为 PiliPlus 2.2.0.2，来源包括 lib/http/live.dart、lib/pages/live_room/controller.dart、lib/pages/live_room/superchat、lib/pages/setting/pages/fullscreen_sc.dart 和 lib/utils/storage_pref.dart

- 先通过 room_init 把短号还原为房间号，再向 /av/v1/SuperChat/getMessageList 读取初始列表。此次游客实读短号 6 对应 7734200；正式房间号的结果为 HTTP 200、业务码 0、data.list 为 null，按空列表处理
- 实时事件与初始列表按留言 ID 合并，删除事件优先。价格、头像、头像框、背景、勋章、颜色、起止时间、账号和举报参数分别读取。关闭醒目留言时不请求列表，普通聊天仍能使用
- 列表支持当前、常驻和关闭三种显示方式；全屏只展示实时到达的留言，显示时间不超过 10 秒或原留言截止时间。显示宽度、透明度及缩放可调，并可恢复默认。访问发送者、复制留言信息、保存卡片到系统照片与举报均有独立入口
- Checks/LiveChatCheck.swift 用独立数据验证大 UID 和数字字符串、列表缺行、实时与历史乱序、删除后不再出现、重复事件、过期边界和全屏时限。未向真实直播间发送举报或购买留言。系统全屏转场、照片授权和实际高价留言卡片的视觉效果留待整体验收
