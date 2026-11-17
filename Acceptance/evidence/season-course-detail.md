# 番剧、影视、点评与课堂二次核查

固定上游 `d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`。原版记录与实际操作如下；这里不包含发现首页与索引条件

| 记录 ID | 上游调用 | 原生路径与核查结果 |
| --- | --- | --- |
| `screen:video/introduction/pgc` | `video/introduction/pgc/{view,controller}.dart`、`widgets/{season,episode,section,intro_detail}.dart`、`PgcInfoModel.findEpisode` | `SeasonCatalogView / EpisodeLink / EpisodePlayer` 枚举服务实际给出的季、正片及每个预告/花絮组，选定组内连续播放、切换集数和全屏目录；可返回完整目录。EP 链接按 `ep_id` 优先于 `id` 精确定位，跨到附加分组时不混播正片；季入口提供上次观看集。评分、地区、上映时间、更新、播放弹幕数、演职人员、简介和可搜索标签均取自服务 |
| `page:pgc_review`、`screen:pgc_review/child` | `pgc_review/{view,child/view,child/controller}.dart`、`PgcHttp.pgcReview[Like/Dislike/Del]` | `SeasonReviews` 默认长评，长/短评独立请求，默认/最新排序、服务游标及总数。长评跳专栏并展示获赞数，短评可切换赞同/不赞同、进作者空间、按原版 URL 举报。仅本人可改删，确认删除评分，写请求受打开时主账号约束 |
| `screen:pgc_review/post` | `pgc_review/post/view.dart:_onScore/_onPost` | 新评需选 1–5 星，按原版换算 2–10 分；可以只评分，正文最多 100 个字符。新发可分享到动态，编辑不发送 share_feed。写长评用原版官方 member 网页及主题、media_id，短评由 SwiftUI 编辑 |
| `screen:fav/pgc` | `fav/pgc/{child_view,controller,widget/item}.dart`、`FavHttp.favPgc` | `FollowedSeasons / SeasonFollow` 读取季状态、追番或追剧、想看/在看/看过、单项移除、多选已加载及批量改状态。看其他用户公开追番列表时将对方 mid 作为 vmid，浏览者负责认证，只显示自己的管理操作；换号会清除选择并重新取状态 |
| `screen:fav/cheese`、`page:member_cheese` | `fav/cheese/controller.dart`、`member_cheese/widgets/item.dart`、`PageUtils.viewPugv` | 原生课程列表读取课堂收藏或公开投稿，支持封面、标记、课时状态、收藏时间和确认取消收藏。课程详情展示老师/共同作者并跳空间、课程介绍图、封面和所有课时。课程深链用课时 `id` 而不是 PGC 的 `ep_id`；历史支持精确 aid 或 ep、传入播放时间。元数据、收藏状态与历史恢复区分视频、主账号及记录观看账号 |
| `page:video`（PGC/PUGV）、`screen:video/download_panel` | `lib/http/video.dart:videoUrl`、`lib/models/common/video/video_type.dart`、`video/download_panel/view.dart` | `EpisodePlayService / EpisodePlayPayload` 优先使用相同视频账号的标明 ogv/pugv 的普通 `/ogv/player/playview`，读取明确错误、服务提供的分轨、语言、片头片尾；只在传输超时/中断时按原类型用旧版服务端接口，同账号、同 EP/CID。付费、地区、DRM、业务错误或没有可播放数据不触发回退。明确试看只用服务返回的片段，可播放但禁缓存；未提供许可的 DRM 内容不处理 |
| `screen:video/download_panel`（缓存实体） | `pgc_intro` 及分集下载面板 | 正片、附加组和课堂均可单集选画质/音质、选择多集加入队列、选字幕和弹幕。单集预览与每次实际下载/恢复均重新校验视频账号、EP/CID、下载许可；批量逐项记录成功或失败。节目与课时明确拒绝、地区限制、仅 VIP 但无 VIP、仅试看、受保护流（含 Dolby/FLAC 音轨）均不会生成离线计划。在线和缓存读取相同的服务端播放授权，缓存还要求独立下载许可 |

没有向真实账号发起追番、投币、评分、点赞、举报、收藏或下载，所有验收输入为本地样例

- `cd Native && bash Checks/season_detail.sh` 通过：两个季、正片/花絮独立队列、PGC 与课堂不同的 ID、按实际端选择、续看/缺集、试听和离线单独授权、拒绝/中性状态、有保护的音轨、作者归属、评分分值与长评和举报目标
- 18 个关联 Swift 源文件已用 iPhoneOS 27.1 SDK 对 arm64 iOS 17 独立通过 swift-frontend typecheck，包含完整播放器、DASH 模型、下载、历史、深链与新 UI
- 没有用真实付费账号或票据核验商业内容，也没有改变设备的授权状态；官方网页、可用剧集、清晰度与授权以服务实际返回为准
