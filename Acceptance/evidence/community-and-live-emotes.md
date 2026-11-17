固定来源：lib/pages/bubble、lib/pages/live_emote、lib/pages/live_room/{send_danmaku,contribution_rank}、lib/tcp/live.dart。完整界面按原生控件重新组织

- 泡泡社区首屏读取标题、分类及当前排序；第一分类使用社区首页查询，其余分类携各自真实 ID。已访问分类分别保留列表、排序、页码与滚动，再点当前分类回顶。换主账号重置，点击帖子按真实 dyn_id 打开 opus 文章。2026-11-12 匿名实读社区 1，生产 BubblePayload 解出 9 类、2 种排序、20 条首页帖子
- 直播表情按服务器的包、封面和尺寸显示。3 型包插入普通弹幕草稿，保留正文、光标、同一房间的回复对象，可组合多枚表情；其他包由用户点按时按 emoticon_unique 发送独立弹幕。服务标识无权限时不发送；失败保留选择和草稿；键盘发送键与按钮使用同一提交入口，中文输入法组字时不发送空稿，输入框可直接清空。Checks/LiveInteractionCheck.swift 核对类型、重复/空项、锁定及 emoji 占两个 UTF-16 单元时的替换。未真实发言，匿名查看表情服务返回 -101
- 直播贡献榜绑定本房间和当前主账号，区分在线/今日/本周/本月，按固定源码只有在线榜显示分数。各榜独立翻页，合法 UID 可打开空间，保留勋章
- TCP 子系统在原版用于直播 WebSocket。Swift 使用官方房间与观看账号的 token/端点、WSS、心跳，认证后处理压缩与多包，换房和角色切换会取消旧连接；网络回包类型、房间身份和历史/实时显示分离。PiliWire 的 LivePacketTests 实际运行解包；普通聊天/醒目留言/更新事件分别见 live-interaction.md、live-superchat.md 和 live-room-controls.md
