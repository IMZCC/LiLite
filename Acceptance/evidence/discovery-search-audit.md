# 发现与搜索操作核查

基线：固定 Dart `d9e9626f`。本表覆盖发现/搜索本身；从卡片跳转后的播放器、直播间、完整 UP 主空间另行验收。界面使用 SwiftUI 的菜单、列表、日历分段、系统文件和分享组件

| 用户操作 | 上游入口与原生实现 | 核查证据 |
|---|---|---|
| 切换推荐/热门、上拉续页、下拉刷新、失败重试 | `rcmd`、`hot` → `Feed.swift`、`MobileFeed.swift`；应用/网页数据源，按 BV 去重，可保留上次推荐，点分界回顶并刷新 | 访客移动推荐前两页 8 / 10 个可播放项目、共 18 个不同项目，18 个返回反馈菜单；见 `PILI_MOBILE_FEED=1 bash Checks/public_services.sh` |
| 过滤与切换推荐身份 | `recommend_filter.dart` → `RecommendationFilter`；推荐/热门使用各自规则，切换推荐账号或规则重建列表 | 归属见 `AccountServices.swift`，已有 PortBehaviorCheck；无新账号写入 |
| 卡片视频、作者、封面、BV、稍后再看、总结 | `video_popup_menu.dart`、`video_card_{h,v}` → `ArchiveCovers`、`ArchiveCardActions`；普通稿件详情、原生作者空间、封面浏览/保存/复制、复制 BV、主账号稍后再看。启用总结且有 CID 时显示只读摘要与分段时间 | 对照入口并经 iOS SDK 类型检查；没有发送稍后再看写入 |
| “不感兴趣”、撤销、本地屏蔽和账号拉黑 | 移动推荐使用服务下发的原因和推荐身份；普通稿件点踩使用主账号授权，点踩/撤销值为 0/1。账号黑名单 `act=5,re_src=11` 与仅本机屏蔽分开；服务认可后才移除。移动 GET 反馈和 POST 点踩都只发送一次 | 对照 `http/video.dart` 与 `utils/accounts/api_type.dart` 的字段、身份、结果码；实名服务写入留待实机。签名差异见下方 |
| 热门三个快捷入口、切换分区、排名卡和封面 | `hot/view`、`rank/zone`、`rank_type.dart` → `Rankings`。保留 15 个 UGC rid 与 6 个 PGC 类型；番剧取 `/pgc/web/rank/list`，其他 PGC 取 `/pgc/season/rank/web/list`，按返回 URL 原生跳转，展示更新和统计 | 离线检查 21 个唯一分类；访客番剧榜 99、电影榜 100 |
| 选择每周必看任一期、入站必刷翻页、从某条连续播放 | `popular_series`、`popular_precious` → `Rankings`、`CloudLibraryKind.curated`、`LibraryPlaylist`；服务给出的期号、期名、标签、提示；取实际条目排序，点选行直接定位，不允许修改公共片单，支持切换方向和跨页 | 访客响应 397 期；SDK 检查贯通条目、页码、队列与推荐身份。入站必刷遇到空页才结束 |
| 普通关键词、分享文本、编号直达 | `search/controller` → `SearchView`、`SharedResolver`。支持粘贴站内链接及 BV/AV 号，普通词进入分类结果。纯数字可显式打开 UID；仅在首条视频的真实 aid 与输入相符时自动打开该稿件 | 离线检查搜索命中、非首条、非数字、课堂占第一位等；短链只解析站内允许的主机 |
| 默认词、实时联想、热搜和猜你想搜 | `search`、`search_trending` → `SearchView`、`MoreSearch`。尊重各自开关、按当前推荐身份更新、取消旧联想；首页 10 条，榜页 30 条，另列服务的置顶、角标、直播和理由，点词搜索；支持刷新/换一换、失败重试 | 完整热榜访客响应 30 条、置顶 1 条；热搜点击回到同一搜索任务 |
| 搜索历史开关、逐条删除、确认清空、列表导入导出 | `search/view.dart` → `SearchView`。文件/剪贴板均支持原版 JSON 字符串列表；非关键词跳转不记历史，开启记录后去重置顶，无痕模式不写，删除不依赖联网 | 逐一核对存储、手势、确认框和文件编解码；系统文件选择器/剪贴板需实机 UI 验收 |
| 综合、多域搜索、筛选后的第一页与续页 | `search_panel/all`、`http/search` → `UnifiedSearch`、`DiscoveryContracts`。无筛选首屏取 all/v2，以后取 video；启用任一视频筛选时从第一页取真实 video。视频、用户、专栏、番剧、影视、直播间独立显示计数，使用服务分页与读身份 | 本次正常匿名 WBI 请求：综合/视频/用户/专栏/番剧/影视/直播间各解析 20 项；对应返回总数 1000 / 1000 / 1000 / 1000 / 81 / 94 / 115 |
| 视频排序、分区、发布时间、时长 | `common/search/video_search_type` → `SearchFilterForm`、`VideoSearchOptions`。6 种排序、22 区（含全部）、5 时长；不限/今日/一周/半年/自定义日期；发送 `order, duration, tids, pubtime_begin_s, pubtime_end_s` | 访客“音乐”按播放+音乐分区+短视频返回 20 条；包含夏令时的当天/七天窗口检查到了日终 23:59:59 |
| 用户与专栏筛选 | `search_panel/{user,article}` → `OtherSearchOptions`。用户默认/粉丝或等级正反序和 4 种身份；专栏 5 排序、9 分区。用户/直播/专栏/视频按对应 mid 或 uid 过滤屏蔽名单 | 两类真实筛选均返回 20 项。离线实际 Swift 模型检查粉丝正序、认证类型、笔记分类、按喜欢排序，以及已屏蔽的专栏 |
| 点击混合结果和分类卡 | `search_panel/{all,user,pgc,article,live,video}` → `SearchHitRow`。作者主页、该用户正在直播和最近投稿；番剧/影视、直播间、专栏、课堂、站内活动、赛事分别路由到实际资源；支持结果封面浏览 | 离线实际 Swift 模型检查作者/上传视频/直播信息、课程、赛事、带 HTML 的标题、视频时长与统计；各分类另有访客回包 |
| 番剧影视首页、追番/追剧和索引 | `pgc`、`pgc_index` → `PGCHome`、`SeasonCatalog`。推荐与主账户订阅各取自己的身份，横向分页/进入全部；索引按番剧、全部影视、电影、剧集、纪录片、综艺取服务下发的排序及筛选，支持展开、重置，按 has_next 继续 | 番剧 9 个条件组/5 个排序，全部影视 2 组/3 个排序；连续 2 页各 21 个不同页结果 |
| 更新日历：日期、番剧/国创、已追和延期、打开指定集 | `pgc/controller`、`widgets/pgc_card_v_timeline` → `SeasonSchedule`、`PGCHome`、`SeasonCalendar`。前后各六天，以日期合并番剧和国创，展示今天、更新、延播和已追；有集号进入该集，无集号进入作品，长按封面 | 匿名实际合并 13 天共 74 集，已有 PortBehaviorCheck 覆盖缺日/重复集；个性化关注标识需登录账户实机检查 |

复测（WSL，目录 `Native`）：`python3 Checks/discovery_readback.py` 离线运行实际 Swift 搜索/筛选模型；加 `--live` 读取公开搜索、排行榜、索引、周次和日历。样本数量记录于 2026-11-12，会随站点内容变化

单次反馈合同：`Checks/CardPreferenceCheck.swift` 给实际 `CardPreferenceMutation.sendOnce` 注入本地传输，没有发包。主账号与推荐账号角色与上游分别核对；不同身份或缺少授权时回调为 0 次；模拟丢失回执超时，GET 推荐反馈和 POST 稿件点踩各只调用一次；业务码 -400 抛错、不会被当作成功。取消原因使用 `/x/feed/dislike/cancel`，普通稿件撤销传 `dislike=1`；撤销后列表按原位置插回，列表已变短时安全插尾，已有同 BV 不会重复。上游交互与现有原生界面都在收到成功回执后才移除或恢复

剩余验收：真实账号点踩与撤销、黑名单、加入稍后再看和个性化追番标识没有在线写入；系统相册、文件选择器、页面实际触底和连续播放需真机。原版应用域拦截器还会附客户端应用签名，本分支移动反馈使用用户已授权的移动令牌；站点是否接受这两种移动写入尚未实测。发现页所用的只读服务已按上表分别验证，不以通用覆盖率计数代替这些验收项
