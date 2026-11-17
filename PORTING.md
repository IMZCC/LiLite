# iOS 功能迁移对照

基线：PiliPlus 2.2.0.2。上游页面目录和命名路由是核对入口；同一页面内的设置项、手势、权限及异常路径也要单独验收。安卓和桌面专有行为不直接照搬

| 功能线 | 上游实现 | 原生范围 |
|---|---|---|
| 发现与搜索 | rcmd、hot、rank、search、pgc_index | 推荐、热门、排行、搜索、筛选、分区与番剧索引 |
| 视频与弹幕 | video、pl_player、danmaku、episode_panel | 详情、分 P、播放、画质、倍速、字幕、弹幕、画中画、投屏 |
| 账号与个人库 | login、mine、history、fav、later、subscription | 多账号、历史、收藏夹、稍后再看、订阅和账号安全 |
| 社区与消息 | dynamics 系列、main_reply、whisper 系列 | 动态浏览与发布、投票、评论互动和私信 |
| 创作者与直播 | member 系列、follow、live 系列 | 用户空间、投稿、关系分组、直播间与直播弹幕 |
| 离线与偏好 | download、webdav、settings、storage | 下载队列、离线播放、备份、设置、屏蔽和数据迁移 |
| 音频、专栏及其他 | music、article、pgc、match_info | 音乐、专栏、番剧、课程和赛事的差异化体验 |

本次核对的具体发现、命令与公开接口抽样见 [核查记录](AUDIT.md)

## 如何判断完成

[parity.json](parity.json) 使用锁定提交中的页面、路由、功能说明、249 项持久化设置和底层模块、嵌套页面和 iOS 集成入口做交叉索引。记录之间有重叠，不能用条目比值计算已完成的功能百分比。每项都需要检查正常流程、失败后的恢复、账号权限和平台差异。构建与签名使用下列不同检查；未结的客户端功能会阻止交付。当前复核资料见[跨领域索引](Acceptance/evidence/cross-domain-review.md)

| 状态 | 含义 |
|---|---|
| pending | 尚无对应的原生实现，或尚未建立对照 |
| partial | 原生代码已接入，但仍有功能差异或缺少验收 |
| implemented | 此项的行为已对齐，且在记录中附有对应证据 |
| not-ios | 基线中明确属于其他平台的行为，保留排除原因 |
| source-note | 固定上游仅写“其他”或“bugs”的三条裸行，保留来源，不计作已实现功能 |

## 两个交付检查

`python3 Checks/parity.py --complete` 与签名入口使用的 `--client-complete` 均执行严格完成检查：任何 partial/pending 都拒绝通过，14 个领域的最终复核、源码/证据指纹和三类真实执行收据须完全一致。2026-11-13 重审确认原版 AppSign 使用固定上游已公开的普通客户端签名，不需要特殊签发身份，之前对登录及设备列表的三行豁免已撤销，必须以正常原生实现验收，详见[账号协议](Acceptance/evidence/account-grant-scope.json)

`build.cmd --sign-personal` 使用个人签名和声明过的 Bonjour 服务。具备 Apple 组播授权才可签完全组播配置。当前普通签名、标准投屏和全部代码均保留；[包与授权校验](Acceptance/evidence/personal-device-signing.md) 记录两者差异

## 开发早期的核查范围

下表保留初期排查方向。逐项当前状态以 parity.json 及对应的证据文件为准

| 领域 | 可以从源码追踪的路径 | 尚需核对的例子 |
|---|---|---|
| 发现和播放 | 推荐、排行、搜索、分 P、候选线路、分轨 DASH、软件及系统解码、互动视频、章节/空降、Metal 超分、内联/全屏与锁屏控件 | 真机验证 HDR 画面、编解码切换、受保护片源、PiP 和长时间播放 |
| 独立听视频 | 单独选择音轨、分 P 播放队列、后台/锁屏、播放顺序与进度 | 不同音轨和外接设备的兼容性；音效设置 |
| 账号和资料库 | 官方同机登录/扫码、Cookie 和令牌绑定、角色切换、观看记录、收藏、稍后再看与订阅 | 异构条目、多账号批量操作、退出时的未完成请求 |
| 社区 | 动态正文、富文本与图库、瀑布流、话题的排序/折叠、图文投票、回复翻译、评论内搜索/跳转、私信和通知 | 草稿富文本编辑的完整行为、各类账号回执、图文渲染差异 |
| 影视与直播 | 番剧/课程播放和缓存、更新日历、影评；直播分区、HLS/FLV、普通弹幕轨道、SC、反馈、举报和房间互动 | 受限账号的实际返回、直播弱网/恢复、真机音视频同步 |
| 离线和设置 | 后台下载、分 P 暂停/恢复；iOS 文件夹授权和安全迁移；受限分集按所有者保护；本机与云弹幕规则、设置备份和 WebDAV | 新旧容器的随机 seek、不同行为的云端回执、断网和外置存储实机验证 |

可重复的本地检查见 [README](README.md)。开发产物不作装机交付；账号写入功能的验证、真机交互和局域网投屏应与编译及只读接口结果分开记录

局域网设备自动发现使用 SSDP 多播。[Apple 的权限说明](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast)要求应用及签名描述文件具有多播授权。原生工程已声明该权限；已装首版的开发描述文件不包含它。可手动填写设备地址，但这不满足自动发现的验收条件

## 原版页面目录
about · article · article_list · audio · blacklist · bubble · coin_log · common · contact · danmaku · danmaku_block · dlna · download · dynamics · dynamics_create · dynamics_create_reserve · dynamics_create_vote · dynamics_detail · dynamics_mention · dynamics_repost · dynamics_select_topic · dynamics_tab · dynamics_topic · dynamics_topic_rcmd · emote · episode_panel · exp_log · fan · fav · fav_create · fav_detail · fav_folder_sort · fav_panel · fav_search · fav_sort · follow · follow_search · follow_tag_sort · follow_type · group_panel · history · history_search · home · hot · later · later_search · live · live_area · live_area_detail · live_dm_block · live_emote · live_follow · live_room · live_search · log_table · login · login_devices · login_log · main · main_reply · match_info · member · member_article · member_audio · member_cheese · member_coin_arc · member_comic · member_contribute · member_dynamics · member_favorite · member_guard · member_home · member_like_arc · member_opus · member_pgc · member_profile · member_search · member_season_series · member_shop · member_upower_rank · member_video · member_video_web · mine · msg_feed_top · music · my_reply · pgc · pgc_index · pgc_review · popular_precious · popular_series · rank · rcmd · save_panel · search · search_panel · search_result · search_trending · setting · settings_search · share · space_setting · sponsor_block · subscription · subscription_detail · video · webdav · webview · whisper · whisper_block · whisper_detail · whisper_link_setting · whisper_secondary · whisper_settings

## 命名路由（70）

/ · /home · /hot · /videoV · /webview · /setting · /fav · /favDetail · /later · /history · /search · /searchResult · /dynamics · /dynamicDetail · /follow · /fan · /liveRoom · /member · /memberSearch · /blackListPage · /colorSetting · /fontSetting · /displayModeSetting · /articlePage · /playSpeedSet · /favSearch · /historySearch · /laterSearch · /followSearch · /whisper · /whisperDetail · /replyMe · /atMe · /likeMe · /sysMsg · /loginPage · /memberDynamics · /logs · /subscription · /subDetail · /danmakuBlock · /sponsorBlock · /createFav · /editProfile · /settingsSearch · /searchTrending · /dynTopic · /articleList · /barSetting · /upowerRank · /spaceSetting · /dynTopicRcmd · /matchInfo · /msgLikeDetail · /liveDmBlockPage · /createVote · /musicDetail · /popularSeries · /popularPrecious · /audio · /mainReply · /followed · /sameFollowing · /download · /dlna · /myReply · /videoWeb · /ssWeb · /memberGuard · /bubble
