固定原版 lib/pages/match_info/widgets/match_info_item.dart 依比赛状态区分：未开始显示 VS、进行中进入实时直播、已结束显示比分及回放；没有回放地址时不显示按钮。原生赛程详情展示赛段、时间、两个队徽、名称、比分及状态，直播间/回放走已实现的资源路由，讨论打开比赛编号的 27 型评论。支持下拉刷新和请求失败重试。登录状态变更会丢弃旧读取

2026-11-12 以匿名身份实际读取 /x/esports/match/info?cid=28&platform=2，返回 code=0、状态 3、两支队伍、比分 2:1，没有回放。搜索结果到比赛详情的资源映射另由 Checks/discovery_readback.py 验证
