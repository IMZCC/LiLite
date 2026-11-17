# 听视频、音频投稿、待播及后台

固定基线 PiliPlus `d9e9626f`。核对 `lib/pages/audio/{controller,view}.dart`、`member_audio`、`member_video/controller.dart`、`video/controller.dart::toAudioPage`、`lib/services/{audio_handler,audio_session,shutdown_timer_service}.dart`、`lib/models/common/video/source_type.dart` 和 `lib/utils/app_scheme.dart`。表中 Swift 路径相对 `Sources/PiliNative`。截至 2026-11-12：源代码/协议样本和 arm64 iOS SDK 类型检查完成；未使用登录账号、未操作 iPhone

|可操作项|实际入口、对象与行为|已验与待验|
|---|---|---|
|普通稿件选分 P，切到纯音频，再回视频|详情“听视频” → `Playback/DetailView`、`Audio/ListenQueue`；保留 BV、CID、当前秒和独立交接编号；只有发起交接的同条视频可取回进度。加入待播不抢播|SDK；前后台实际交接待真机|
|合集、作者投稿、稍后再看、收藏夹、每周必看|单稿 UP_ARCHIVE(5,aid)；UGC 合集 MEDIA_LIST(8,extra 8)；投稿目录“收听全部”用作者/合集/系列 ID、extra 1；稍后再看使用所属 uid、extra 2；收藏夹 USER_FAVOURITE(4,extra 2)；周刊用服务的 media_id、extra 4。普通投稿行仍按单稿打开。见 `ListenerCatalog`、`Social/CreatorArchiveBrowser`、`Library/LibraryPlaylist`、`Discover/Rankings`|首请求 protobuf 解包实测；登录各入口的实际队列内容待验|
|番剧/影视、课程|当前集“听本集”/“加入待播” → `Audio/EpisodeListening`、`ListenSource`；保留 EP、CID、AV/BV、试看/禁止标记。只走本集的 `episodeFormats/courseFormats` 和视频取流账号，拒播或 DRM 失败不会改走普通稿件；试听不标记正片已看完|SDK；服务授权、付费/试听、有声播放待实机|
|UP 音频投稿、音频卡/深链、收藏中的音频|空间 → 音乐投稿：数量、封面、标题、日期、播放与评论、刷新和分页、封面原图；点单条及“播放全部”传真实歌曲编号/空间 uid 与当前页。AU 卡走 AUDIO_CARD(3)，空间走 MEM_SPACE(1)，两者 itemType 3，稿件为 1。详情可单独读取，标题暂缺也可先请求音轨。见 `Social/CreatorLibrary`、`Audio/AudioCardEntry`、`Discover/LinkDestination`、`Library/FavoriteMedia`|SDK；本网络目录返回 HTTP 412；示例 AU123456 返回歌曲不存在 4511001；没有将它们算成可播样本|
|来源队列：上下页、排序、选中分 P|每页 20；首次真实 from+anchor，续页不重复 anchor，使用服务返回的 prev/next；无序/正序/倒序/随机重新向服务申请，按 BV/AU 合并去重、忽略过期页。列表显示/折叠分 P、切换当前分 P，移除非当前来源项不写云端。见 `ListenerCatalog`、`Wire/…/ListenerGateway`|协议样本验证真实序列化字段、空 anchor、不透明游标及排序；匿名真实 Listener/Playlist 返回 2/-101|
|本机待播与切换账号|“加入待播”去重；可切来源/本机、拖排序、删除、仅保留当前、确认清空；本机删当前则停止。以主账号 uid/游客隔离队列和冷启动位置；切换账号清理旧播放器/加载/锁屏。未授移动权时仍能播服务允许的单条，来源目录会说明需授权|已核 UI 至存储、取消回调、旧条目读取；拖动与账号切换待真机|
|手动/自动切歌、重复播放|播放/暂停、拖动、上一首/下一首；播完暂停/顺序/单曲循环/列表循环；顺序先下一 P、再下一条，跨页后再决定是否到尾。原生额外保留本地随机。四种原版值按原索引导入/导出，随机不污染原字段|既有 `Checks/PortBehaviorCheck.swift` 覆盖分 P 与队列、首尾、循环；`Acceptance/evidence/audio-queue-order.md` 有原设置往返记录|
|音质、线路、倍速、音量、响度|按 Wi-Fi/蜂窝取音质，优先兼容编解码、DASH 与 DURL 的备线；主账号移动 Listener、视频取流角色公开 UGC、AU 公共音频服务、OGV/PUGV 专用授权分开。完整移动服务拒绝不会改用其他身份。倍速 0.5–2×、播放器音量、系统选输出、播放信息。索引 DASH 可走 `DashBridge.startAudio` 的纯音频 HLS/ALAC，应用滤镜/服务响度测量；普通单文件可用系统音频增益，不宣称无索引音频支持离线分片归一化|SDK，已有 `hls-audio-processing.md` 的独立运算样本；本轮公开 UGC API 返回 DASH 音视频，通用网络检查三条视频 CDN 均 403、在读音频前停止；没有以获得地址当成实际出声|
|越权切换、缓存与回环|主账号 Listener/AU 使用 main，视频/课程使用 video，匿名明确绑定空 uid；`Playback/MediaLoader` 按请求及每轮范围缓存读前/交付前检查，`DashBridge` 收到本机请求以及远程范围收发时再查 role/owner，取流期间切号不继续用旧身份|SDK 和调用链核对；登录态受限音轨跨账号、系统缓存交付待真机|
|封面、作者、编号、歌词、MV|点封面开原生画廊；点作者暂停并开空间；编号复制、简介、收听/时间和服务统计；有 AU 歌词时解析 LRC/纯文本、多时间戳、毫秒偏移，当前歌曲点歌词进度定位，不对别首生效；有相关 MV 以 AV/CID 定位。歌词请求不带账号，流式限 1 MiB|真实 Swift 歌词样本：汉字、重复时间、偏移、非法时间和纯文本通过。音频标注/歌词回包及系统相册待验|
|赞/取消、投币、三连、收藏|主账号 Listener ThumbUp/CoinAdd/TripleLike，与本人操作绑定且不重试，三连按 thumbOk/coinOk/favOk 分别回写；按版权限定选币、支持同时赞。收藏资源 UGC=2/AU=12，快捷/选夹、移出全部有确认。见 `Audio/ListenMetadata`|离线真实 protobuf 三项写请求、取消赞、一币并赞以及部分三连回执通过；未做真实账号写入|
|评论、分享、举报|评论稿件 1、AU 14；复制、其它应用、系统分享，动态转发资源 8/256，稿件才可作为视频卡发私信。举报进入原站表单。见 `ListenMetadata` 与现有评论/IM/动态编辑器|SDK 与参数/入口核对；未发送、未举报|
|空降、多分 P、进度条|UGC 按 BV+CID 获取片段；进度条着色、定位、自动/手动跳过、列表、同意/反对和类别建议、可选观看统计；按类别与最小长度过滤。换曲/换 CID 清空任务和上一条提示|SDK，沿用实际 SponsorRules/SponsorVisits、SponsorMarkers；社区票数/计数未写入|
|继续收听、本机与云进度|本机保存当前账号、所在队列、稿件/分 P 与秒数；AU 使用单独命名空间，试听不覆盖正片位置。视频型使用 heartbeat 身份，验证历史 shadow/本机同步开关；UGC type=3、OGV=4、PUGV=10。冷启动“继续收听”回原队列。独立 AU 不冒充稿件上报|真实数据路径至 `Playback/CloudHistory`；未写线上历史|
|锁屏、耳机、电话、Siri/控制中心|系统音频会话、Info.plist audio 后台能力、Now Playing 封面/标题/艺人/进度/速度，播放/暂停/上一条/下一条/定位；耳机断开暂停。中断开始保存先前播放意图，只有系统应恢复且用户没有再次暂停/更换项目才恢复。前景、后台使用同一播放器|离线实测重复 begin、ended 仅恢复一次、应恢复 false、手动取消后不恢复；iOS 系统媒体、扬声器实际出声、路由/蓝牙和应用切后台需真机|
|定时停止|到点立即停止、等本集结束、可返回首页。换曲网络尚在加载时也由当前播放器持有定时器，迟到的旧 item/中断/线路不会让已睡眠的队列自启。见 `Playback/SleepTimer` 与 `Audio/ListenQueue.bindSleep`|本地到点时无 item/正在播放/等播完后仅触发一次通过；锁屏挂起与恢复需真机|

复验（WSL，目录 `Native`）：

- `PILI_LISTENER_PUBLIC=1 swift test --package-path Wire --filter ListenerGatewayTests`：4 项通过；两项匿名请求分别为 gRPC 2 / -101（需登录）。无写请求离开本机
- `bash Checks/listen_interruption.sh`：编译实际 Swift 策略和歌词实现，全部断言通过
- `python3 Checks/listen_public.py [--song 编号 | --space 用户编号]`：只读验证目录、AU 详情、服务返回音轨和最多 512 字节 Range，依次打印，站点拒绝时返回失败。当前环境的目录样本返回 412，未更换身份规避
- `python3 Checks/generate_wire.py <protoc-gen-swift> --check`：根据固定上游描述符重新生成并逐个比对；与并行 IM 变更合并后的 639 个类型，21 个生成文件一致
- 当前工具链 `arm64-apple-ios17.0` + Apple iPhoneOS 27.1 SDK 的模块类型检查包含全部 Audio Swift、DashBridge/MediaLoader/SleepTimer 及库、空间、视频、剧集的入口；安装与设备系统行为由整包验收

可独立更新 `preference:SettingBoxKey/audioPlayMode`：默认与原四种模式、持久化、导入导出已有独立行为检查。建议继续保留 `page:audio`、`page:member_audio`、`route:/audio`、`upstream:feat/播放音频`、`subsystem:services/audio_handler.dart`、`subsystem:services/audio_session.dart` 的实机/认证验收项；本记录不覆盖独立 BGM 详情 `page:music` 或全播放器的实机验证
