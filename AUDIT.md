# 原生移植核查

本分支固定对照 PiliPlus 2.2.0.2（d9e9626f1a3f89cd9ca85e18f61aaba02634e12a）。[14 域核查索引](Acceptance/evidence/cross-domain-review.md) 按用户操作链接具体实现与证据；[逐项对照](parity.json)、[最终复核结果](Acceptance/final.json)和[真机验收清单](Acceptance/device-checklist.md)分别记录源码对齐、固定版本验收和设备操作

## 开发过程记录

以下是较早的排查快照，其中的“继续核对”不用于判断当前版本是否签收

当时的专项核查：[HTTP 调用交叉核对](Acceptance/evidence/http-surface-audit.md)、[登录](Acceptance/evidence/login-website.md)、[创作者空间](Acceptance/evidence/creator-sections.md)、[动态流](Acceptance/evidence/dynamic-feed-layout.md)、[文章与互动](Acceptance/evidence/reading-layout.md)、[导航与我的](Acceptance/evidence/navigation-shell.md)、[点播线路](Acceptance/evidence/vod-lines.md)、[字节缓冲](Acceptance/evidence/media-byte-buffer.md)、[播放控件](Acceptance/evidence/player-gestures-layout.md)、[锁屏与横屏](Acceptance/evidence/player-layout-and-system-controls.md)、[会话设置](Acceptance/evidence/player-session-preferences.md)、[接口代理](Acceptance/evidence/api-proxy.md)

开发中新增核对（不是最终验收）：

- [首页推荐与移动端反馈](Acceptance/evidence/mobile-feed.md)、[搜索与热门入口](Acceptance/evidence/discovery-entries.md)、[横竖屏卡片宽度](Acceptance/evidence/catalog-layout.md)：公开移动推荐在两次请求中解出 16 条不同的可播放内容
- [收藏与稍后再看队列](Acceptance/evidence/cloud-playlist.md)、[多 P 与分享定位](Acceptance/evidence/archive-resume.md)、[播放顺序](Acceptance/evidence/play-order.md)、[起播和混合内容](Acceptance/evidence/video-transport.md)：分开检查服务端页码、内容 ID、播放进度、顺序和账号
- [直播线路与 FLV 转封装](Acceptance/evidence/live-native-remux.md)：验证 H.264、HEVC、AV1 及纯音频样本、滚动播放列表与取消行为
- [评论装扮和表情](Acceptance/evidence/comment-artwork.md)、[动态与图文正文节点](Acceptance/evidence/rich-text-nodes.md)：检查同名链接各自的目的地、真实附件和纯文本回退
- [番剧影视首页与空间入口](Acceptance/evidence/pgc-home.md)：区分推荐和索引，按天合并两个真实排期源，独立核对关注列表和订阅权限
- [图片缓存与清理](Acceptance/evidence/artwork-cache.md)、[网络重试](Acceptance/evidence/connection-retry.md)：核查公开封面 HTTP 头、缓存范围与故障重试时的账号和写入边界
- [默认字幕与游客目录](Acceptance/evidence/subtitle-catalog.md)、[外接键盘](Acceptance/evidence/player-keyboard.md)：验证字幕协议、静音分支及播放顺序；设备焦点、实际字幕画面留待最终验收
- [帧率和简介](Acceptance/evidence/archive-display.md)、[视频与合集封面](Acceptance/evidence/archive-covers.md)：匿名服务样本验证分轨元数据；相册授权、真实 60 fps/高刷设备仍需最终测试
- [动态分类和目录](Acceptance/evidence/dynamic-feed.md)、[未读角标](Acceptance/evidence/unread-indicators.md)、[站内私信分享](Acceptance/evidence/im-share.md)、[公开可见性](Acceptance/evidence/public-visibility.md)：消息序列化和账号归属已进入主机检查。游客评论接口返回 -352 的用例保留为未确认，未发送测试私信或发表测试评论

| 核查范围 | 发现或已复核的行为 | 继续核对 |
|---|---|---|
| 推荐、热门、搜索 | 推荐、排行、相关视频分别走原版适用的过滤条件；已关注例外、过滤后为空仍有下一页、热搜不可用时能打开 BV 链接 | 不同推荐账号的真实反馈与撤销、综合结果中的直播活动与赛事、分区与时间筛选 |
| 普通视频、影视、课堂 | 直链备用地址失败可回退到 DASH，错误范围或短响应不应成为正常片段；有音轨但无法选择时显示错误；接入剧集字幕和片头片尾区间 | 不同编码、付费权限、切源和远端 CDN 失败恢复；IPv6 与网络切换 |
| 音频、弹幕 | 弹幕提供权重/模式/关键词/正则/发送者筛选、合并、密度、描边和滚动速度，列表可按时间定位；独立听视频、锁屏队列和定时停止有真实入口；定时器覆盖直播和等当前集播完；分段弹幕解析、特殊弹幕时间轴已有可执行校验 | 独立音乐详情、完整弹幕类型、全屏与画中画、音频路由中断 |
| 收藏、历史及稍后再看 | 补齐图文与话题收藏、公开和未发布笔记列表、按资源分别取消收藏或删除笔记；修正收藏选择器：按资源 ID 查询原有勾选，保存时计算新增和移除集合，切账号不会把原操作写到另一人名下 | 带账号的分页、笔记批量操作与删除后刷新、云端排序 |
| 账号、空间与创作者 | 扫码、钥匙串、多账号、空间隐私与创作者导航可以从客户端继续到服务调用 | 账号资料编辑、登录设备、特殊投稿类型和空间关系；漫画、空间搜索、大航海与充电排行已有原生入口 |
| 社区、私信 | 动态详情、发布、投票、带图回复和消息列表有原生代码；“我的评论”根据服务端回复保存到对应账号的本地记录，支持文件与剪贴板导入导出、打开楼层和移除本地记录 | 使用移动端授权的账号实测折叠会话与消息设置、不同类型的长图文卡片、评论和富文本链接 |
| 图文阅读 | 文集链接与收藏图文进入原生阅读页；同一套 HTML 与 Opus 解析检查验证图片、正文、引文、代码和链接的顺序 | 更多复杂卡片与账号阅读状态 |
| 视频详情工具 | 新增按当前 BV 与分 P 读取原站视频总结、按章节时间跳转；无可用总结不会编造内容 | 权限状态、空章节、笔记、互动分支、专栏 |
| 直播、投屏 | 公共接口实读分区树；已有直播流、弹幕和投屏入口 | 贡献榜权限及各分页、复杂直播间交互、局域网真设备、签名描述文件多播授权 |
| 缓存与离线 | 修正冷启动恢复队列误伤新任务和重复索引导致崩溃；新增离线搜索、分集弹幕分段存储、字幕语言、无网络读本地回放和手动更新 | 有权账号的影视/课堂缓存、后台被系统终止后的恢复、真机长视频 |
| 设置、备份、平台 | 每项设置单独对照，不能用“有设置页”覆盖其余行为；滤镜、片头片尾模式纳入设置备份 | 原生首页支持调整频道、启动栏目、底部导航顺序；继续核对全部设置的实际消费者、旧版备份兼容性、外设与系统行为 |
| 工程与打包 | WSL 的 xtool 交叉编译 Swift；校验包内为 iOS 17 设备用 arm64 主程序并排除 Flutter | 所有行为核对完成后，在同一份源码上做整体验收和最终签名 |

### 核查办法

- `python3 Checks/parity.py --summary` 从固定提交重建索引，分别统计 114 个一级页面目录、56 个嵌套页面、70 个路由、249 个偏好、147 个 README 记录、15 个底层模块、4 个 iOS 集成入口。索引互相重叠；这些数字不是功能完成比例，也不是对原版所有隐含行为的穷举
- `bash Checks/run.sh` 运行索引解析、弹幕、链接、过滤规则、时间边界和字节范围检查；`bash Checks/public_services.sh` 用应用内模型只读请求真实公共数据，不加载 Cookie。一次取样读到 20 个热门视频、所选视频 4 个分 P、100 个排行视频（后续抽样出现服务错误 -352）、20 个影视条目、所选番剧 200 个剧集编号以及 12 个直播大区和 456 个子区。扩展抽样用应用端相同的参数签名得到 10 个联想词，直播短号解析出正式房间和主播编号；从同一公开视频实取音频、视频 CDN 字节区间，两份媒体索引均按播放器实际代码解析成功
- `bash build.sh --release` 已完成优化构建和设备目标检查。`bash build.sh` 只生成开发包；`python3 Checks/inspect_ipa.py dist/PiliNative.ipa` 检查压缩包、主程序、目标平台、最低系统版本、包标识和后台音频声明
- `python3 Checks/parity.py --complete` 拒绝待移植和部分实现的记录；全部结清后仍需验收与源码指纹一致，14 个领域均有证据。签名入口也执行此检查。验收需要测试的实际行为写入独立记录，不能用勾选或文件存在代替实测

原版文件和对应 Swift 实现路径见 [parity.json](parity.json)。后续发现清单外的行为仍需补入；不因上游没有单独的路由就跳过

### 私信协议核查

从固定上游的描述符生成 120 个 Swift 消息和枚举，重新生成并按内容比较已通过。原生会话首页及分类分别使用 SessionMain、SessionSecondary，分页保留服务端的完整 offset map。未关注、陌生人和折叠会话按服务端类型进入。私信侧的已读、清空、置顶和取消置顶使用各自的 RPC；设置与屏蔽词只在用户操作后提交

在 WSL 用独立二进制样本验证了分页与重复游标、分类请求、关键词增删、压缩帧、返回状态与截断响应。设备 Release 构建已成功；不携带账号的服务探测只确认了网关能返回 gRPC 错误。移动端授权绑定到当前 UID 的钥匙串记录，网页扫码账号仍可通过网页凭据使用私信。尚未核验移动端已授权账号的服务端结果

通知：拆开服务端最新点赞与累计点赞，补回多人点赞名单、通知级静音、删除和系统已读游标。多人详情按卡片号、页号及上一页最后一位用户请求；消息自带的视频、用户和评论楼层链接直达原生页面。已通过路由行为检查和 iOS 设备目标编译；真实账号收到通知后的服务结果待验

账号资料：网页账号中心加载的公开脚本确认账号基本资料、改名条件、四个表单字段和头像接口。昵称成本提示取自当前账号，提交前重新校验条件；每次只改所选字段，保存前从服务端刷新其余字段。相册支持预览、裁剪和保留 GIF。关注列表区分共同关注和我关注的人也关注 TA；分组以当前关系为初始值。收藏夹排序与资源排序分开，资源排序保留 ID 和类型，音频、番剧和失效资源不会因缺少 BV 号而丢失。上述涉及个人账户写入的流程尚未实测

显示与诊断：比对 Android 专用屏幕模式后，在 iOS 接入播放器弹幕动画刷新率；动画按实际媒体时间采样，在暂停及后台停帧。字体支持系统字体和 TTF/TTC/OTF 本地注册，字重与字号传入内容样式。倍速列表与长按、AVKit 菜单、备份贯通。日志记录选择性的错误类别、状态码和系统 MetricKit 诊断，不记录账号凭据或请求参数。普通网页现在使用每个视图独立的临时 WebKit 存储，支持前进、后退、复制、分享、刷新和账号同步。设备 Release 已编译；物理屏幕刷新率、系统诊断投递、真实字体和已登录网页尚待核验

动态与空间：对照发动态载荷补入标题、精选评论和直播预约，支持编辑预约并保留服务端返回的编号；筛选同时考虑转发原文、带货卡和临时隐藏的作者。增加图文投稿、商品、投稿分类和合集跳页。使用不带账号的公开小店目录请求获得 HTTP 200、业务码 0、空列表和重复的零游标，客户端会结束这一页；这次没有检验非空商品交易或真实预约

直播信息流：按原版选择协议 3；iOS 使用系统 Brotli 与 zlib，保留认证、人气和弹幕事件，认证成功后才启动心跳。分别对用 libbrotlienc 和 Python zlib 生成的完整帧执行了相同断言，并验证截断或无认证结果的帧会失败。登录设备是独立安全中心请求，实读游客请求返回 -101；登录设备列表未冒充为登录历史，也未动用用户凭据进行在线测试

动态协议：新增公开图文流、文集入口及动态点赞与转发名单，完整协议范围现由 397 个上游类型组成。公开图文接口的前两页已被 Swift 客户端实际解码；线上点赞名单被服务端限制，见[核查记录](Acceptance/evidence/dynamic-protocol.md)。平台豁免现在需要指向固定版本内能核实的行和具体功能；Windows/macOS 独有实现的豁免不代替对应的 iOS 功能审核

备份：设置 JSON 已支持旧原生格式、原版 setting/video 和带原生扩展的新格式。WebDAV 按平台定位文件、递归建目录、验证配置，密码留在本机钥匙串，覆盖前校验远端版本并保留不认识的原版字段。详见[数据迁移核查](Acceptance/evidence/settings-migration.md)

评论：原生顶层与楼中楼请求都应用作者黑名单、商品、提及人数、纯提及及关键词规则；顶层视频评论还支持过滤复制简介。保留服务器分页，置顶回复先合并去重再过滤；富文本按行折叠，展开后可继续点名片和链接。已检查纯提及、嵌套回复前缀、图片/表情豁免与商品过滤，并通过设备目标编译

流媒体：按当前网络分别读取视频、音频、直播默认清晰度和编码优先列表。兼容 DASH 的大小写字段及独立 Dolby/FLAC 音轨，跳过本设备无法解析的格式；质量降级按上游音质等级而非编号排序。播放、缓存和听视频共用选择器；检查了独立音轨、分段范围及合成输入的降级。已完成设备目标编译，实际蜂窝网络、会员音轨与杜比输出尚待真机验证

账号：HTTP 客户端根据固定版本 ApiType 的 61 个服务地址区分记录观看、推荐和取流账号，其余操作默认走主账号。设置支持跟随主账号、指定账号或游客，应用读取 ZIP 中的同一组角色。历史列表回退、写入目标和删除前的账号校验独立；本轮执行了合成多账号隔离检查，没有发送真实账号写请求。未逐个联网验收各接口

播放时间轴：公开样片的两张预览图和热度数据已读回核对，详见[进度预览核查](Acceptance/evidence/playback-timeline.md)

发现与详情：首页保留上次刷新的推荐，超过 200 项保留前 50 项，刷新边界单独显示；更换推荐账号时重置列表。默认搜索词能从首页带入搜索，视频和番剧按分 P 和账号读取同时观看人数。公开读取两个服务均为 HTTP 200、业务码 0，返回 name 和 total 字符串；未用真实账户进行写入

空降助手：逐类核对 12 类标记、5 种处理方式、颜色和时长。贡献 ID 按服务器存入钥匙串，提交与投票由用户发起；跳过统计可关闭。真实游客读取 uptime 返回数值，样片片段接口返回 HTTP 200 空列表；跳过一次、回拖、跨片段与点标记用合成片段检查。没有在真实服务提交片段、投票或计数

弹幕互动：共用当前媒体时间和排版结果确定点中的弹幕；普通滚动、逆向和固定字幕使用同一帧矩形，特殊弹幕反算旋转和缩放后的坐标。支持固定显示、跳转正文里的时间、复制、分账号点赞、按原因举报和屏蔽发送者，接入内联、全屏、番剧和离线播放。已运行位移、生命周期和时间链接边界检查；没有对真实弹幕投票或举报，手势冲突需在最终设备交互验收时检查

直播醒目留言：还原独立列表、到期和全屏展示，兼容历史返回 null 和实时删除先于历史列表到达的情况。见[直播醒目留言核查](Acceptance/evidence/live-superchat.md)

媒体图库：按原始 url/live_url 分开传递封面和动图；新增同组浏览、双击与长图缩放、原图保存/分享以及 iOS 原生 Live Photo 配对。已实读 CDN 质量变体，见[图片与实况核查](Acceptance/evidence/media-gallery.md)

补充实查：[原生解码](Acceptance/evidence/native-decode.md)、[原始超分着色器](Acceptance/evidence/native-upscale.md)、[外置与受限缓存](Acceptance/evidence/storage-locations.md)、[直播普通与醒目留言互动](Acceptance/evidence/live-interaction.md)、[话题](Acceptance/evidence/topic-timeline.md)、[图片投票](Acceptance/evidence/native-polls.md)、[评论中的交互文本](Acceptance/evidence/reply-text-links.md) 以及[账号弹幕规则](Acceptance/evidence/cloud-bullet-rules.md)。功能、SDK 编译、本地载荷验证、公开只读响应、需账号或设备的回归分别记录，完整签名前仍以全量清单为准
