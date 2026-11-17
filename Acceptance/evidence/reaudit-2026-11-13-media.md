# 2026-11-13 媒体功能独立复查

固定上游：`d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`，PiliPlus 2.2.0.2

本轮开始的原生 HEAD：`daa2ea629cc15584ebcad032c7275424dbc4700f`

从 Dart 的取流、操作入口和错误分支重新对照 Swift，没有用旧 `passed` 状态代替检查

## 发现与修复

| 编号 | 严重度 | 原先的实际差异 | 本轮结果 |
| --- | --- | --- | --- |
| MEDIA-01 | P1 | `video/controller.dart:905–935` 明确处理非 DASH 的单段 FLV/MP4 和多段 `durl`，原生普通视频只接受一个 `durl`、PGC/课堂只接受 DASH，合法旧片会失败 | 新增共享有序媒体计划、Range MP4 索引、原生 FLV 无损转封装和带初始化切换的连续 VOD；普通视频、番剧影视、课堂接入同一条链 |
| MEDIA-02 | P1 | 下载和缓存选项只接 DASH，旧 MP4 单文件分支也不能容纳多段 FLV | 允许合法 `durl` 进入现有授权下载计划，每段用 `part-0000` 等组件续传、校验和存储；保存前打开真实 sample table，FLV 本机转 MP4；离线用同一分段时间线播放 |
| MEDIA-03 | P1 | `/x/tv/playurl` 在 Keychain 没有所谓 operator 身份时发送未签名参数；固定上游 `video.dart:1086–1108` 直接使用公开的 `AppSign` | 删除这个额外门槛，`CastProjectionSigning` 复用 `MobileClientSigning.signed`，保留视频角色移动凭据和请求前后身份核对 |
| MEDIA-04 | P2 | 听视频的普通视频后备和听剧集只接 DASH，旧式合法片源不能进入音频播放 | `ListenSource` 接普通、PGC/课堂的合法 `durl`，`ListenQueue` 使用只输出音轨的分段播放桥，保留待播队列、记忆、交接位置和后台播放 |
| MEDIA-05 | P2 | 下载末段落盘后、字幕弹幕任务启动前退出进程，恢复时仅将媒体标成已保存，没有重启附件获取 | `reconcile` 恢复没有 `attachmentStamp` 的已存任务，按原 `includeExtras` 选项继续附件处理 |
| MEDIA-06 | P2 | 补入旧式媒体后，播放地址编辑和解码回退若继续仅读 DASH，会成为无效入口 | 地址授权包含全部合法片段及其备选 CDN，切换某段保留其他片段和进度；音效重载、画质/语言、线路重载、解码回退、seek 与关闭均接入旧式桥 |
| MEDIA-07 | P2 | 首版旧式 FLV 适配需要先下载完整 FLV，长片和多段视频首次播放准备过长 | 增加 FLV 原生 keyframe 索引、按 GOP Range 和小段转封装；清单先发完整时间线，首播与远处 seek 只读请求的窗口，后续片段不预下载整段 |
| MEDIA-08 | P1 | 固定上游 `video.dart:274–314` 在 playview 无 video_info 且 arc.is_drm 为真时使用正常公开 web 回退；原生把这个路由标记当成实际流保护，直接拒绝 | 在同一视频账号下请求 PGC/课堂的对应 web API，接受服务实际发布的清晰媒体；拒绝业务拒绝、具体流保护、pssh/license，并跨回退保留试看标记 |
| MEDIA-09 | P2 | 上游首取 qn=129，并对 support_formats 中低于当前最高档但 DASH 遗漏的最高一档补一次请求；原生首取127且不补请求 | UGC 和 PGC/课堂对齐首取档位及补请求策略，按画质/编码去重合并；账号、语言、试看和实际媒体授权保持一致才合并 |
| MEDIA-10 | P2 | 分片池的第二等待者直接返回共享任务结果，在 stop/seek 与延迟完成交错时可能拿到创建者已经关闭的旧资源 | 已缓存资源带任务 UUID，所有等待者恢复后检查取消、池状态及 pending/ready UUID 归属；仅创建者发布或关闭结果，单个客户端取消不关闭仍被其他客户端使用的媒体 |

## 关键实现与操作链

### 普通视频与特殊片源

- `Playback/LegacyDURLTypes.swift` 解码 `durl/order/length/quality/accept_quality/language/volume`，检查地址、数量、顺序和长度
- `Playback/LegacyDURL.swift` 在同一视频账号下取流，继续检查原稿件权限、试看、DRM 和缓存许可
- `Playback/LegacyDURLPlayback.swift` 对每个原始片段独立索引，MP4 继续使用有界 HTTP Range，不把整部 MP4 装入内存
- `Decoder/LegacyMovieRemux.swift` → `MediaKit/Sources/CLiveRemux/LegacyVOD.c` 在设备内用 FFmpeg 直接复制 FLV 音视频包到可 seek 的 MP4，不启动外部程序，不重新编码
- `LegacyFLVIndex/LegacyFLVBridge` → `LegacyFLVIndex.c` 从 64 KiB 起的有界前缀读取原生 FLV 关键帧表，实际请求哪个 GOP 才 Range 读取并准备哪个 GOP
- `LegacyFragmentTime` 给小窗口的 fMP4 恢复全局 tfdt，GOP 内不重置总时间轴；`LegacySlicePool/LegacyMediaHTTP` 合并并发请求、保留在用 GOP、限制闲置缓存，并在 seek/关闭时取消旧窗口
- `Playback/LegacyDURLPlaylist.swift` 为各片段发出独立初始化和 `EXT-X-DISCONTINUITY`，视频/音频在相同片段边界结束，缺少音轨的片段用 HLS GAP 保持时间线
- 总时间线保留与真实 sample duration 相符的服务端片段长度，排除错误的远超实际长度提示；离线将这些长度存在 `OfflineVideo.legacyDurations`
- `PlayerModel.load/loadEpisode` 和 `EpisodePlayPayload/Service` 共同处理 UGC、PGC、课堂的 DASH 与旧式媒体，拒绝服务错误和受保护内容的分支仍然保留
- `episodePlayBody` 识别原版 playview 的 web 路由标记，使用同一视频角色、EP/CID、语言和画质回退；实际流的保护信息继续检查，试看状态带入播放和缓存许可
- 切画质、语言、音效、线路或解码方式时先建立新源，经过 generation、CID、账号和请求戳核对后才替换播放器，保留当前进度和暂停状态
- DASH 依原版先请求 qn=129，并补一次被 support_formats 广告但返回列表缺少的中间档位；额外请求失败不丢弃已可用的主响应
- `seek/seekThenPlay` 将全局秒数映射到所属片段，只保留目标片段附近的传输和解码需求；关闭、换集或取消会停止桥、传输、连接及原生转封装

### 离线、续传与目录包

- `Downloads.resolve` 先取得普通稿件或 PGC/课堂的离线许可，再解析被授予的旧式媒体计划
- PGC/课堂继续经过 `EpisodeCachePolicy.allow`、`clearPayload`，试看、地区不可用、服务拒绝、DRM 与媒体子项的保护信息均拒绝离线
- 每个 `part-0000…` 组件各自使用原有 `OfflinePieces` 表示指纹、强 ETag、Content-Range、原子 receipt 和 committed 长度恢复
- 弱验证器不拼接为续传成品，文件变更不会复用旧字节，崩溃后未提交的尾部会截掉
- 完整源先经 `LegacyOfflineMedia.prepare` 检查，FLV 转封装完成并验证索引后原子替换；取消或失败保留下载好的原始片段以便恢复
- 所有片段均完成后才进入 saved；恢复进程、睡眠退出、暂停/恢复、删除以及 finalizing 的关系也已接入
- `OfflinePackage/OfflineMediaStore` 保留分段组件白名单、哈希、原子目录发布和账号封存；组件范围严格限定为连续的 0…255，路径和越界组件会拒绝
- `OfflineDecoderItem` 的统一 Source/Bridge 继续提供进度跳转、失败后的剩余解码路径、音效变化重建和关闭，旧式缓存没有额外网络读取
- 纯本地缓存用 `localOwner(.video)` 核对所属账号，在线新取流继续核对当前视频身份
- 字幕、弹幕、片头片尾和封面继续使用原有 `extraDirectory`、附件开关、权限和目录快照，没有另造不相容的附件格式

### 投屏

- 原版依据：`lib/http/video.dart` 的 `tvPlayUrl` → `lib/utils/app_sign.dart`，两者均取自固定上游
- 原生：`CastSubject.fields` → `CastProjectionSigning` → `MobileClientSigning.signed` → `/x/tv/playurl` → `CastGrantBody.routes` → `CastRelay/CastSession`
- 保留 `credentials: .mobile`，取流后重新核对角色账号与移动凭据，转发媒体继续使用有界 Range 和现有 LAN 控制会话
- 播放/暂停、位置、音量、seek、超时、取消、断开、过期授权的恢复由现有 `CastSession` 操作路径处理

## 其他媒体范围重新追踪

| 范围 | 固定上游入口 | 核对的原生文件和操作 |
| --- | --- | --- |
| UGC 详情、分 P、合集、互动视频 | `lib/pages/video/controller.dart`、`introduction/ugc`、`plugin/pl_player/controller.dart` | `DetailView` → `PlayerModel` → `DashBridge/LegacyDURLPlayback`，`ArchiveResume`、`InteractiveStory`、`TimelineAssets`、`VideoExtras`，换分 P、倒序、分支和结束回调 |
| PGC、影视、课堂 | `introduction/pgc/controller.dart`、`lib/http/pgc.dart`、`lib/http/video.dart`、`lib/http/search.dart#pugvInfo` | `Seasons`、`EpisodePlayPayload`、`EpisodePlayService`、`EpisodeCache`、`EpisodeClips`、`EpisodeClipPrompt`，分集身份、合法 web 路由回退、试看、片头片尾、字幕和播放结束 |
| AI/人工语言音轨 | `video/controller.dart#setLanguage` | `DashModels.SpokenCatalog` 排序、`SpokenTrackPicker` → `PlayerModel.changeLanguage`，重新取授予的当前语言、保持进度、无效语言恢复 |
| 视频摘要、标签、分段、缩略预览、高能条 | `video/introduction/ugc`、`video/controller.dart` | `VideoSummary`、`VideoExtras`、`TimelineData/Assets`、`ArchiveTrendStrip`、`ViewportTimeline`，设置条件、当前 CID、点击跳转和全屏绘制 |
| 弹幕 | `plugin/pl_player`、`lib/utils/danmaku_utils.dart` | `SegmentedComments/DMProto` → `PlayerModel.loadSegment` → `BulletOverlay`，滚动/顶部/底部、高级/字幕弹幕、合并、样式、屏蔽、暂停、点击、撤回和切号清理 |
| 字幕 | `lib/utils/subtitle_utils.dart`、`plugin/pl_player` | `Captions`、`SubtitleSession`、`SubtitleDocument`、`SubtitlePicker`、`StyledSubtitleLayer`，默认选择、双字幕、外部文件、偏移、字号、拖动、导出和账号切换取消 |
| 听视频与音乐 | `lib/pages/audio/controller.dart`、`lib/http/music.dart` | `ListenSource/Queue`、`ListenerCatalog`、`EpisodeListening`、`SongLyric/LyricLines`，来源队列、前后取页、分 P、循环、随机、歌词、系统中断、锁屏命令和视频位置交接 |
| 直播播放、流格式与恢复 | `lib/pages/live_room/controller.dart`、`lib/http/live.dart` | `LiveVariants/LiveCDNOrigin` → `NativeLivePlayback` → `LiveFLVBridge/LiveHLSFeed`，HLS/FLV、AVC/HEVC/AV1、独立音轨、CDN、解码路线、停播、授权拒绝、超时和有限重启 |
| 直播弹幕、付费消息与互动 | `live_room/widgets/chat_panel.dart`、`live_room/superchat`、`live_room/send_danmaku` | `LiveChat`、`LiveModels`、`LiveComposer`、`LiveChatActions`、`SuperChatData/Views`，消息去重、重连、当前房间/账号、表情、显示模式和交互入口 |
| 下载、缓存管理与本地播放 | `lib/http/download.dart`、`lib/pages/download` | `Downloads`、`OfflinePieces`、`OfflineMediaStore/Package`、`OfflineSidecars`、`DownloadViews`，前述新增分段链及原有单文件、分轨、列表、目录迁移和附件路径 |
| 相关播放设置的实际消费 | `lib/pages/setting/models/play_settings.dart`、`video_settings.dart` | `PlaybackPreferences`、`PlayerSessionPreferences`、`MediaProfilePanel`、`AudioLevelSettings` → `PlaybackOption/NetworkMediaRules`、`VideoTransport`、`PlayerViewport/Keyboard`、`Theater`、`DanmakuStyle`、`StyledSubtitleLayer`、`NativeLivePlayback`，追踪设置键到渲染、取流或系统播放行为 |

上述其余范围本次没有新增已确认的功能空壳或仅保存未消费的设置项

## 本轮执行结果

- arm64 / iPhoneOS 27.1 SDK 定点 typecheck：本轮全部媒体新增和修改文件通过，日志 `Native/dist/legacy-durl-sdk.log`
- `Checks/legacy_durl.py`：通过
  - 真实生成 4 段 MP4/FLV，含 AVC、HEVC 和 AV1，经过本轮生产 C 代码和 Swift 代码
  - 原始媒体分块写入 → 强 ETag receipt → 未提交尾部中断恢复 → 文件完成 → FLV 原生转封装 → 本地 sample table 和分片输出
  - 180 帧解码 YUV 与原始输入逐帧一致，753 个音频帧，16 秒连续 VOD
  - 正向/反向跨段定位、每次初始化切换、缺音频 GAP、服务时长校准、取消清理和坏容器拒绝
  - 带 keyframe 表的 AVC/HEVC/AV1 按 GOP 准备后，全局时间戳 HLS 的视频 YUV 和音频 PCM 帧与原始 FLV 逐帧一致
  - 90 秒、23,719,045 字节 FLV 的首播与末尾 seek 仅准备 2/90 个 GOP，实际读取 561,394 字节
  - 并发 init/media 请求合并、在用 GOP 禁止淘汰、闲置淘汰、seek 取消、旧任务延迟完成与新任务隔离通过生产 actor 回归
  - 两个真实等待者在 stop/seek 后面对忽略取消的延迟生产者均收到 CancellationError，资源只关闭一次；单个等待者取消时其他等待者仍成功使用共享结果
  - 并发 fixture 通过只读阶段计数等待第二个需求实际进入，再释放生产者回调；移除等待者复核的变异版本会触发该回归失败
  - Linux FFmpeg 的 HLS demuxer会忽略 discontinuity 后的新 moov，回归按播放清单的 discontinuity 重建独立解码上下文，再核对所有真实媒体和全局定位
- `Checks/offline_resume.py`：通过原有身份、授权、强验证器、长度、崩溃尾部和离线历史回归
- `Checks/season_detail.sh`：通过，新增普通/旧响应 envelope 的 PGC/课堂 `durl`、合法 web 路由、服务拒绝、试看继承、DRM 和子项保护回归
- `Checks/storage_locations.sh`：通过，新增分段组件封存、哈希、目录发布、错误组件上下文、越界和路径拒绝回归
- `git diff --check`：本轮改动没有空白错误

## 真机和接收设备验收项

本轮没有签名、安装或真实账号写入，剩余设备验收范围为：AVKit 的多配置 HLS 连播/跨段 seek、系统后台/画中画/锁屏、音画时钟与蓝牙路由、字幕弹幕叠加、断网后的授权离线播放、iOS 后台下载进程恢复、真实 DLNA 设备，以及直播服务发布的实际格式与账号可用音轨

带有效关键帧表的线上 FLV 与 MP4 均按需 Range 读取；没有有效关键帧表的 FLV 保留完整扫描/转封装后备，其首次准备时间会相应增加

源码与生产回归已覆盖本轮确认的缺失分支，正式整仓 host/media/unsigned 收据由总任务在统一提交后重新捕获
