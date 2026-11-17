# 专栏、图文、文集和视频笔记：页面与回包二次核查

固定 PiliPlus 基线 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。原生实现分别从阅读页、视频普通与全屏工具栏、资料库和创作者空间进入；本次没有写入真实账号

| 上游入口 / 原生记录 | 已对照的操作和实现 |
| --- | --- |
| lib/pages/article/controller.dart、view.dart、widgets/，page:article、route:/articlePage | CV 匿名 HEAD 只读取官网跳转，识别实际 OPUS；图文服务给 fallback CV 时只回落一次，避免循环。按服务提供的数据读 OPUS 段落、旧 CV HTML 或 type=3 的 Quill ops，不把 JSON 作为正文。旧格式按原顺序还原文字、图像卡（文章、直播、商品、视频、商城、投票）；视频/专栏/投票跳到实际资源。角色、访客、服务失败、正文为空均有独立状态，不用未授权来源替换付费正文 |
| lib/pages/article/widgets/opus_content.dart、html_render.dart、article_ops.dart | 图文段落、标题、引用、代码、列表、分隔图和图库；链接、@、投票、抽奖、表情使用服务给的目标。数学式使用原项目同一 /x/web-frontend/mathjax/tex 返回的 SVG，独立不执行脚本的 iOS 图片视图，失败显示原公式。支持文字样式/颜色/字号和黑暗背景。支持链接卡 UGC、失效、活动、直播、图文、投票、音乐、逐项商品，以及 EVA3 视频/图文/用户/玩具/投票/评论；EVA3 用户、投票和评论按各自 ID、resource_url 路由。受限模块只留服务器给的标题、提示和官方权限入口；不展示受限段落 |
| 阅读操作 | 顶部相册可横滑、全屏、批量保存，实况图片保留配对。正文图片加入同篇图库，旧 HTML 图片只在可识别的 B 站 CDN 缩略后缀上取原图。保留作者/发布时间、话题圈、文集跳转、转发、收藏/取消、评论、点赞、分享与分享图。旧专栏收藏走 /x/article/favorites/{add,del}；OPUS 收藏走 simple_action。点赞先按明确发起操作的主账号读回目标状态；只对用户要求的状态发一次。普通阅读按已配置的观看历史身份和服务器暂停开关报告 type=5，公开笔记也走同一阅读页 |
| lib/pages/article_list 与 page:article_list、route:/articleList | 原版请求 /x/article/list/web/articles 返回整个文集，没有服务端页游标；原生列表使用真实返回顺序、封面/作者、刷新、总文数、字数、阅读量、更新时间、各文章阅读/点赞/回复与摘要。优先进入原项目给的 dyn_id_str，缺失时才按 CV。保留官方文集网页入口 /read/mobile-readlist/rl{id} |
| lib/pages/member_{article,opus}，page:member_article、page:member_opus | 空间的专栏/图文入口延用已有 CreatorOpus/gRPC 的分页与文集，此次核实其目标与共用原生阅读器/文集接通；并未把整个空间归入本轮核销 |
| lib/pages/fav/article、fav/note，以及 lib/http/fav.dart | 图文收藏显示封面、作者、点赞及时间，可取消；未发布笔记与已发布笔记分别按 note_id、cvid 翻页、显示公开正文、确认批量删除。两种删除字段分别是 note_ids、cvids，主账号和 CSRF 绑定。原版未发布笔记原样打开服务给的 web_url。iOS 保留这个入口，也在能从受信站内地址或返回 arc 确认视频时提供原生编辑；仍须通过该账号该视频的 /x/note/list/archive 校验身份 |
| lib/pages/video/note/controller.dart、view.dart 与 lib/pages/webview/view.dart | AV 的公开笔记列表每页 10 条，以服务器 page.total 停止，展示作者头像/等级、摘要、发布时间，点击打开公开笔记或作者。固定 Flutter 版本的“开始记笔记”不是本地 Quill 编辑器：实际打开 www.bilibili.com/h5/note-app，桥接完成按钮、资料栏返回视频和 AJAX 默认标题；因此仅搜索 Api.addNote 字符串会误判。原生版有正式业务服务的 Swift 编辑器，也保留原版官网编辑器作为备用 |
| 笔记公开阅读 | /x/note/publish/info 按实际 cvid、pub_status=2 读取。富文本原顺序、文字格式、截图和时间标记都能阅读；时间戳用笔记自己的 oid、对应 CID 和秒数打开分集，末尾可回源视频。HTTP 错误、审核中、未知或私有状态不会被改成可公开阅读 |
| 笔记原生编辑 | 当前主账号 /x/note/list/archive 列出的 noteIds → /x/note/info 的正文、状态、版本。按原编辑器锁定审核中状态 1/5、锁定状态 4、明确不可编辑标志，未知状态不允许写。当服务明确返回空名单才可为该视频新建；失去服务时仍能先写本机草稿。原生支持正文、粗、斜、删除线、下划线、调整段落顺序、相册和帧截图、标签与对应分集。保留不认识的 Quill 操作和自定义属性，局部编辑不会删掉其它字段 |
| 记时间/截图和上传 | 播放器入口传入真实播放器、CID 和视频标题。取主播放器当前实际视频/分集，按该分集的 page、总分 P、当前进度与 cid 建 tag，再由此生成完整的 tags 表单；插图先在本机预览。FrameCapture 仅截取当前受支持、非试看且系统允许截帧的画面；普通相册图片绝不伪作“视频截图”。用户明确保存后才向笔记专用 /x/note/image/upload 发送 multipart 的 file 与 CSRF，只有有效业务回执 data.location 才进入 imageUpload。私人图片只向指定官方笔记路径带当前身份；服务若跳到白名单媒体 CDN，新请求不带 Cookie |
| 草稿、保存及公开 | Application Support/PiliNotebook 下主账号/视频/笔记分区，图片单独写入、元数据原子替换，排除系统备份，设置备份不含内容或授权。资料库“未发布笔记 → 本机草稿”可恢复、删除。多窗口存档比对上次读到的草稿，服务正文和审核/版本在上传前和最终提交前再核对。离线新草稿遇已有云端笔记可以经明确确认追加到本机副本，仍需再点保存才写云端。草稿使用 /x/note/add；公开是独立确认，提供上传协议/规范/原创声明，原创和同时发视频评论分别选择；旧已发笔记不重复发评论。服务明确拒绝保留本机内容；结果不确定时先对照云端，不自动重发。提交公开时据实显示已提交审核 |
| 官方深链 | 固定 lib/utils/app_scheme.dart:627 的正式 note/note-app 入口携唯一有效 cvid 时路由至专栏；不接受外站及歧义 ID。移动文集 rl 路径原先已由 read/token 识别，已加入回归验证，没有另造一条路由 |

## 官方编辑服务的依据

本轮在 2026-11-12 匿名读取[官方笔记编辑页](https://www.bilibili.com/h5/note-app?oid=1&pagefrom=ugcvideo&is_stein_gate=0)。实际编辑组件在 [235.0e7bc934.js](https://s1.hdslb.com/bfs/static/2233-monorepo/note-app-h5/static/js/235.0e7bc934.js)，本轮下载字节 SHA-256 为 62a645ffcd36adf482c2c164597e864e531a690cb308859e9a82ec55f5f0602b。公开确认组件的来源是 [823.aca603ce.js](https://s1.hdslb.com/bfs/static/2233-monorepo/note-app-h5/static/js/async/823.aca603ce.js)。这些网页资产仅供查看接口、字段和编辑权限，没有复制到产品，也没有采用网页调试样例的硬编码表单

保存携 oid/oid_type（当前仅视频 0）、服务确认的 note_id、标题、富文本 content、summary、cont_len、tags、cls、hash、platform 与登录 CSRF。新建与更新都以服务真实 note_id 判断回执；发布另携 publish、original、auto_comment、pub_from 和 comment_format。非零业务码不会被当作已发出、已公开或已过审，账号切换不会换另一个身份提交

原项目没有编辑长专栏正文、文集出版管理或解除付费内容授权的原生写入流程。动态附带“稿件说明”编辑与真正编辑长专栏是两件事；后者仍应由官方发布工具处理

## 验证

- 在 Native 目录执行 bash Checks/notebook_domain.sh：账号分区、并发保存、过期写入拒绝、服务返回状态、草稿与公开参数、真实图片路径、第三方私图域拒绝、已有 Delta 未知字段、分集跳转、旧式图文和 EVA3 卡、公式与样式，本地 Swift 样本全部通过
- 重跑已有 ArticleBodyCheck、ContentContractCheck 通过，包括域名、CV、移动文集、重复 ID、HTML 原图和文档顺序
- python3 Checks/note_public_readback.py 为可选匿名只读联查。这次 AV170001 有 2 篇公开笔记，CV43796340 的官网 HEAD 指向 opus/1137166765727416322；实际 note/publish/info 有 38 个富文本操作，工程内的 Swift 解析器生成 19 个阅读块。公式端点返回 HTTP 200 的 SVG
- iPhoneOS 27.1 SDK / arm64 iOS 17 对 14 个阅读、笔记、深链和资料库主文件独立类型检查通过。未执行真实账号的云笔记保存、截图上传、发评论、收藏或审核；iPhone 中文输入、系统相册、真机截图、关闭编辑页后的账号实际同步、审核后公众可见性仍需最终设备验证
