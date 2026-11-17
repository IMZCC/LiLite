# 番剧、影视与课堂全链复核

固定基线 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a，和[上次详情与点评核查](season-course-detail.md)、[首页](pgc-home.md)、[离线](episode-offline.md)互补。逐项核对的是这些路由的 PGC / PUGV 分支，没有替其他页面的普通视频、空间、搜索等分支签收

| 验收记录 | 原版来源与行为 | Swift 入口/处理 |
|---|---|---|
| page:pgc | pgc/controller.dart、view.dart，番剧/影视推荐分页，最近追番/剧、总数/“全部”、封面、刷新，番剧首页可展示排期 | PGCHome、SeasonTile、SeasonSubscriptions；播放数/上榜信息或更新标签、徽章、个人观看进度与新集文本按已返回字段展示。PageList 下拉时重载列表及表头；推荐账号和登录主账号分开 |
| page:pgc_index | pgc_index/{view,controller}.dart，番剧按 season_type、影视按 index_type；影视全部 102 / 电影 2 / 电视剧 5 / 纪录片 3 / 综艺 7，各自保留筛选和列表 | SeasonCatalog → SeasonIndexBody；读取服务可选条件和排序，传回服务实际 field/keyword，21 部/页。各分类首次打开才初始化，回来保留选择及已载入页面；切换账号清理旧目录 |
| preference:SettingBoxKey/showPgcTimeline | pgc/controller.dart，番剧首页 types=1 与 4，前后各六天；只有首页由设置关闭 | discovery.pgcTimeline；首页和完整日历按 date_ts 合并去重、定位今天，显示已追、更新集、播出时间或延期原因。已播且 ep_id 存在可直接开该集；预排/延期开所属季。全库没有找到“追剧提醒”单独订阅写接口或推送设置，原版实际功能是云端追番状态和更新日历，未另造远程推送 |
| screen:search_panel/pgc、screen:rank/zone、page:member_pgc；route:/searchResult、/member 的相关分支 | search_panel/pgc/widgets/item.dart、rank/zone/widget/pgc_rank_item.dart、member_pgc，搜索卡显示类别/地区/评分/上映年/进度，可进入季 | 搜索 media_bangumi、media_ft 保留 score 与有效 pubtime 年份；排行榜、空间的服务 season_id 与索引全部进入 SeasonView。详情展示作品原名、别名、上架日期、连载与评分人数、角色配音与制作人员分开列，资料没有人物 ID 时用姓名搜索，不捏造演员空间 |
| screen:video/introduction/pgc、page:video、route:/videoV、/videoWeb 的 PGC 分支 | video/introduction/pgc/{controller,view,widgets/season,section,episode,intro_detail}.dart，当前季度、剧集/花絮与预告、切集、回作品、角色信息、标签、推荐续播 | SeasonOverview/SeasonCatalogView/SeasonCatalogEntry/EpisodeLink。按季与预告分组定位准确的 ep_id，若原版允许播放但目录只缺 cid，沿上游 SearchHttp.ab2c 对应公开的 /x/player/pagelist 查同一稿件/分P（明确的分P未匹配就报错）。播放资格按视频账号读取，历史账号只提供续看集和位置。viewer 的 user_status.area_limit 与 can_watch 控制不可播；全季的地区位图不是当前人的禁播证明 |
| page:episode_panel；screen:video/introduction/pgc | episode_panel/view.dart 的 UI 倒序与 UGC 专有“倒序播放”是不同操作；跳顶部、底部、当前项，切集 | SeasonEpisodeSelection 提供列表显示反转、首末/当前定位、正在播放标记及不可选课/集。分组内顺序继续由实际播放列表控制，反转显示不会更改下一集。播放器可选当前服务正常下发的主/备用线路、音轨、清晰度，继续由共同 PlayerModel 选择服务授权的轨道；未实现任何代理换区 |
| screen:fav/pgc、page:pgc_review、screen:pgc_review/child、screen:pgc_review/post | fav/pgc、pgc_review：想看/在看/看过、批量移动、追/不追；长短评、最新/默认、作者、赞踩、评分、改删、官方长评编辑器 | SeasonFollow、FollowedSeasons、SeasonReviews。仅本人可以管理清单、编辑删除自己的短评；allow_review=0 时显示点评但不开放新增或编辑。同一剧集可明确加入或移出稍后再看；分享原集链接、私信/动态及图片海报；课程分享链接保持 /cheese/play/ep 的业务身份 |
| page:member_cheese、screen:fav/cheese、route:/fav、/history 的课堂分支 | member_cheese、fav/cheese、SearchHttp.pugvInfo、PageUtils.viewPugv、video/introduction/pgc。收藏/取消、查看讲师团队/介绍图、课堂课时与学习状态 | CoursesView/CourseDetail/HistoryCourseLink。先正常读取固定原版 /pugv/view/web/season，成功后以同一视频账号用官方网页的 /pugv/view/web/season/v2 补齐 sections；没有用 v2 重试原版的拒绝。自定义章节、单个默认章节的 ep_catalogue（从 1 开始的首尾索引）、重叠去重与未归组课时均保留。课时按自己的 id 选播，其他组的课时不混进播放队列。展示已学、学到的位置、课程有效期/停售状态。若服务明确还有未返回的条目只给官方目录入口。阅读进度取配置的历史账号；关闭记忆时不会自动套用历史秒数 |
| screen:video/download_panel、preference:SettingBoxKey/showBangumiReply、preference:SettingBoxKey/pgcSkipType、preference:SettingBoxKey/CDNService | video/download_panel、video/introduction/pgc、video/widgets/header_control.dart、pl_player/controller.dart 的共用能力 | 已缓存/可缓存、播放/试听、弹幕与评论按实际剧集；只有合格正片参与缓存/投屏，试看不能变为缓存实体或投屏正片。PGC 评论用 aid/1、课堂用课时号/33；片头尾用该视频授权回包的片段处理“一次/总是/手动/显示/关闭”。区分 PGC 心跳 type=4 与 PUGV type=10，并携带真实 sid、epid、cid 和服务已给的 sub_type，仍由同步历史及账号暂停状态决定是否发送 |

**课堂访问控制。** V1 明确的不可播/不可缓存不能被 V2 信息放宽；V2 的 episode_can_view=false、锁定课和 DRM 课程不发送 VOD 获取指令。实际直播课 play_way=2 不冒充普通点播，可打开相同课时的官方课堂。平台明确标记的试看（含访客课时的“试看中，购买即可观看完整内容”）仅使用明确返回的片段；课程和播放层都禁止把试看当可缓存正片。登录、购买、地域或 DRM 拒绝不触发其他账号、地区或播放类型的重试。正常播放权限仍以服务当次确认为准

**验证。** 2026-11-12，匿名只读 /pgc/view/web/season?season_id=33415，原生模型解析两组共 1,280 集、475 个制作人员文本字符；该季全局 rights.area_limit=328、当前访客 user_status.area_limit=0，证明不能简单把全季非零值当禁播。匿名课程 1 的 V1/V2 均 code=0；同一套原生合并模型得 1 章 15 课时、14 个不可播放、1 个标记可试看。未请求受限流，也未执行真机安装/付费/评分/追番/个人历史写操作。官方网页的 [公开课堂入口](https://www.bilibili.com/cheese/play/ss1)使用 V2 目录和同一章节索引结构

同次下载的索引条件，番剧有 9 个过滤组，影视“全部”有 2 个。时间表两个类型均返回 13 天、各 1 个“今天”，分别列出 43 和 31 个排期。确实没有拿这个公共样本充当已购课程、云端同步、成功下载或实机播放的证据

`bash Checks/season_detail.sh` 测真实字段的章节切分、重叠去重、既有拒绝不可放宽、DRM、试看、课堂特殊课型、不同地区字段、缺 CID 的行为、用户/课程/片单 ID 与历史参数、评分写入字段。可依次追加匿名保存的季、课程 V1、课程 V2 三个 JSON 数据对象路径，核对同份实际回包。受影响的 Swift 入口、播放器、搜索模型和服务代码通过 arm64 iOS 17 / iPhoneOS 27.1 定点类型检查，整机的购买后观看与学习进度回写仍留作最终设备验收
