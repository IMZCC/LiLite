原版 lib/pages/live_room/controller.dart、view.dart 和 lib/pages/member/widget/user_info_card.dart：直播页资料、实时观看文案与直播分享操作

- LivePlayer 从 getH5InfoByRoom 按真实房间 ID、观看记录角色读取主播、头像、标题、封面和 watched_show.text_large；后续采用该房间 WebSocket 的 WATCHED_CHANGE 文案，而非把房间人气当观看人数。换房或换号会清空旧值，读失败仍能重试，不打断已经打开的节目
- 直播上方可进入主播空间，房间菜单提供复制链接、iOS 分享、用浏览器打开、分享到站内消息。节目标题/主播/封面还会更新当前系统媒体会话，不需为更新元数据停播。2026-11-12 匿名读取公开房间 6 的 H5 服务返回 0，有标题、主播信息及 watched_show 文案
- 空间资料里的「粉丝勋章」只在作者拥有勋章时出现（空间 medal==1），点击才查询 Master/info.medal_name、再点可拷贝。与该用户自己佩戴的勋章墙是两个不同的动作，分别保留
- 整套直播标题、聊天事件、原生主播资料和元数据更新路径已过 iPhone SDK 类型检查；没有对主播或真实账号执行写操作
