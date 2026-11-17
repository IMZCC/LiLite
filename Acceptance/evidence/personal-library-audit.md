# 个人主页、订阅、收藏、稍后再看与历史

基线：PiliPlus 2.2.0.2，提交 d9e9626f；逐条依据 lib/pages/mine、subscription、subscription_detail、fav*、later*、history* 和这些页面调用的 lib/http/{user,fav,video}.dart。所有表中路径均相对于 Native/Sources/PiliNative。这里记录可达入口、服务动作和运行过的检查；没有用私人账号写入，也未安装真机

| 原版操作 | 原生路径与核对结果 |
|---|---|
| 查看个人资料、进入自己的空间、切换或添加账号 | Account/ProfileOverview.swift 显示当前账号的头像、等级、年度会员、硬核会员、硬币和经验；点头像进 CreatorSpace，长按可登录其他账号。“我的选项”和账号区均可切换；注销和移除仍由 AccountContext 处理 |
| 查看动态数、关注数及粉丝数，点数字看对应列表 | 明确用主账号请求 /x/web-interface/nav 与 /x/web-interface/nav/stat，分别链接 CreatorDynamics 和实际关注/粉丝列表。切换账户或下拉刷新后重取 |
| 评论历史、消息、搜索、外观和设置 | ProfileView、ProfileQuickActions 接入 MyReplies、Inbox 和原生设置，保留未读计数；没有首页标签时提供搜索，外观和全局 appearance 使用同一设置 |
| 临时无痕、设为永久、退出 | Account/Accounts.swift 与 AccountRole.swift。临时设置仅在当前进程、当前主账号上为 heartbeat 创建游客角色副本，不写钥匙串或导出备份。永久设置保存角色映射，退出恢复跟随主账号；查看历史依原版从游客 heartbeat 回落主账号，取流及推荐角色保持原分配 |
| 自定义展示四种资料架、横向翻页、进入完整列表 | Account/ProfileShelf.swift：历史按历史账号，其余按主账号。由 NavigationLayout.mineTabs 决定显示和顺序；行指向原资源、收藏夹或合集 |
| 创建的收藏夹分页、排序、编辑、删除 | Account/ProfileView.swift 的 FolderList 请求 created/list 的真实页码，保留 cover、媒体数量和公开性；Library/CloudOrder.swift 用完整列表排序并锁定第一项；只有非默认夹提供删除，保存、排序、删除绑定打开动作时的 UID |
| 收藏夹名称、简介、可见性、封面 | Library/FolderEditor.swift、FolderCover.swift：名称 20 字、简介 200 字；相册选择、原比例/16:9/方形裁剪、缩放、水平垂直调整、取消/移除。正式保存时以 multipart file、bucket=medialist、dir=cover 上传，再保存返回地址。默认夹锁住名称且隐藏简介/换封面，可改可见性 |
| 收藏资源时查询原勾选、取消、同时移到多个夹、建夹、容量 | Library/PickFolder.swift：按资源 ID 和类型查询 fav_state，差集提交 add_media_ids、del_media_ids。默认夹 50000、其他夹 1000 上限只限制新加入；可撤销原有勾选。新建后重取真实勾选并保留还未提交的选择 |
| 跨文件夹搜索、筛选顺序、分页 | Library/FavoriteSearchAll.swift：以默认夹作为搜索上下文、按 type=1 搜索全部收藏夹；夹内搜传 type=0。均使用 mtime、view、pubtime；按 has_more 翻页 |
| 跨夹对搜索结果逐条或批量整理 | 全局搜索先据每条的实际 id:type 读取真实所属夹；可检查/勾选单项的所属夹。批量复制只增加目标关联；移动或移除先选实际来源并显示将处理的数量，不假设结果都在默认夹 |
| 收藏夹头部、创建者、封面和公开分享 | Library/FavoriteFolderScreen.swift 基于 folder/info 检查 mid/upper、attr、fav_state。可跳创建者、查看封面、阅读简介和统计。只有公开夹提供系统分享及原版 dyn_type=4300、rid=夹 ID 的资源转发，不把文件夹当成一条动态 ID |
| 收藏/取消收藏别人的夹，清理失效项，删除整个夹 | 同上：别人夹的 fav/unfav 根据账号真实状态；拥有者才可 clean、编辑及手动排序，非默认夹才可删除。列表与播放队列均不对公开访客开放原夹的移除动作 |
| 夹内排序、正倒序、管理、播放 | Library/CloudLibrary.swift、LibraryPlaylist.swift、FavoriteOrder.swift：服务排序与手动拖动分开；页码倒序从真实末页起并倒转每页，点选时保留原服务页码。播放全部、从条目起播、恢复队列、前后切换，参考 cloud-playlist.md |
| 夹内与稍后再看多选、全选、批量移动/复制/移除 | 原生保存加载顺序。对收藏的复制和移动像原版一样按显示顺序倒转资源，编码 id:type；稍后再看传 aid。源夹、目标夹、mid 和 CSRF 随用途和类型构造，服务确认后刷新 |
| 打开普通投稿、音频、番剧、失效收藏 | Library/FavoriteMedia.swift：投稿从首分 P 开始，音频和番剧分别进入原生音频/单集页；失效收藏有作者 ID 时可去作者空间，不作为可播放项。公开封面可经原生图库保存 |
| 追番、追剧、想看/在看/看过及批量改状态 | Discover/SeasonLibrary.swift：服务端分页，初始“在看”。可点作品进入详情，单项切状态/取消追番，选择已加载作品或全选后一次提交完整 season_id 列表和目标 status |
| 收藏课程 | Discover/Courses.swift：按服务 page.next 翻页，打开课程或课时，直接在收藏列表对单项确认取消收藏，绑定当前主账号 |
| 图文、话题、笔记 | Library/SavedReadings.swift：图文打开原生阅读器、话题打开原生话题页；两者分别使用自己的取消收藏接口。公开与未发布笔记分页、单删、全选已加载笔记和批量删除，分别传 cvids/note_ids；按资源提供阅读和原笔记官方链接 |
| 订阅列表、失效订阅、取消订阅 | Library/Subscriptions.swift：读取 collected/list，第 11 类是收藏夹，第 21 类是合集；失效项目显示状态但仍能取消订阅。取消夹与取消合集调用不同端点与参数；请求一律绑定主账号 |
| 订阅详情、查看创建者/封面、正倒序 | 第 11 类复用全功能收藏夹页；合集使用 /x/space/fav/season/list，带数量的列表入口按原版先倒序，直接打开无数量时先正序取得信息。详情合并服务元数据，展示名称、创建者和播放数、可播放视频 |
| 分享链接和空间入口 | Discover/SharedLink.swift、LinkDestination.swift、Social/CreatorFavorites.swift：medialist/detail/ml…、bilibili://medialist、个人空间合集链接进入上述完整详情页；URL 参数与域名分开解析 |
| 稍后再看：分类、关键字、排序与清理 | Library/CloudLibrary.swift 和 Network/CollectionsAPI.swift：只有原版实际启用的“全部”“未看完”（viewed=0/2），远程搜索、最近/最早加入、队列，分别确认 clean_type=1、2 或全部清空；不把注释中的“未看”和“看完”算作独立标签 |
| 完整历史分类、混合搜索和翻页 | Library/HistoryLibrary.swift：初始读 type=all 并采用服务返回的 tab；列表用最大 oid + view_at，搜索按 pn 传 business=all，不只保留有 BV 号的投稿 |
| 历史按资源类型打开、观看时刻 | Account/ProfileShelfModels.swift、Library/HistoryCourseLink.swift：投稿、分 P、PGC、课程、直播、专栏及文集条目分别处理。未开播直播保持不可播放。课程按历史 aid 匹配原课时；明确的 0 或 -1 从头开始，正秒数传播放器，没有进度才可由播放器使用已有断点 |
| 查看作者、加入稍后再看、逐项/批量删除和清理已看完 | HistoryLibrary：按原版条件显示作者入口与稍后再看。稍后再看用主账号，删除用历史角色，且只接受有效 business_kid；全选和清理已看完均只处理已加载的记录。不会把页面显示用的备用 oid 变成删除目标 |
| 暂停、恢复与清空观看历史 | HistoryLibrary 的显式确认与 HistorySettings 使用同一套 shadow、shadow/set、clear。用户设备上的进度同步开关保持独立 |

**核验**：2026-11-12 在无 Cookie 条件下使用固定上游 api.dart 注释附带的公开 UID 17340771。created/list 返回 4 个夹；folder/info 返回真实夹 76614671、所有者 17340771、attr=0、media_count=84、fav_state=0；resource/list 第一页实际返回 19 项，第 5 页 4 项。因此不能因为中间页少于 20 条就提前结束。公开数据会变化。Checks/NavigationShellCheck.swift 覆盖混合类型、相同 kid 的不同业务、分 P 及 null/-1/0/正秒数；Checks/PortBehaviorCheck.swift 核对账号用途、临时游客副本和队列。UI、请求和实体经过 arm64 iOS SDK 类型检查。真实主账号的私有列表和数据写入不在这次只读核验内
