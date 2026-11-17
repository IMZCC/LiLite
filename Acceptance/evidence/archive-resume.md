# 多 P 续播和分享定位

固定版本 VideoDetailController 用 /x/player/wbi/v2 的 last_play_cid 提示继续观看，不会直接切到上次分 P。详情优先打开明确的 CID、分 P、队列历史或分享时间，普通入口从首 P 开始。服务给出另一个有效分 P 时，“继续看 P…”显示四秒，点按后才切换；本机分 P 记录按账号分开，访客单独保存。回到同一 CID 可以恢复服务时间，链接显式给出的零或非零时间优先。偏好 continuePlayingPart 控制提示，不改变链接含义；见 [详情逐项核查](archive-detail-audit.md)

分享参数沿用 lib/utils/app_scheme.dart 的优先顺序：start_progress 为毫秒，dm_progress 向前定位三秒且不低于零，t 为秒。普通视频、AV 链接和番剧集链接都把时间交给 AVPlayer。云端进度不会借给另一个分 P

主机检查覆盖指定第一 P、服务 CID 已失效、关续播、无效时间戳、零时间戳，以及时间参数冲突。xtool 已编译 arm64。公开服务实测 BV1WEp8zwE6d 返回 1 个分 P、游客进度 0；另两个样本返回 62002。登录账号产生的跨设备多 P 记录留在整体验收中验证
