固定来源 d9e9626f：lib/pages/{home,hot,rank,rank/zone,rcmd,pgc,live} 的页面状态、lib/pages/webview、lib/pages/login/view.dart、lib/pages/member_video_web/season_series 及搜索服务

- 原版首页六个频道保持各自状态；发现页按用户保存的排序摆放，没有配置时使用直播、推荐、热门、分区、番剧、影视，首选推荐。支持点频道和横向翻页。首次访问才创建该频道，重访保留分页和滚动；21 个排行榜分区同样在自己的位置恢复。双击或再次选择顶栏不会把已离屏的列表滚回顶部；切账号清除相应内容。主账号头像可进「我的」，未登录时也可从这里登录，有观看无痕标志
- 搜索的 7 类内容及独立直播间/主播搜索沿用 discovery-search-audit.md 的参数和解析。收到站点的验证指示或搜索服务的 -352 时，提供固定 search.bilibili.com 的原关键词页面，原生列表也可重试。不复用网页登录验证凭据。实时联想、直播搜索、默认词以及跳转后的站内搜索页面按推荐身份；设置游客推荐时不会带主账号 Cookie。切换身份会取消/忽略过期结果
- WKWebView 原生操作：当前标题、进度、前进/后退/退出、刷新、复制/分享、浏览器打开、清除缓存及历史、官方域同步所选账号。换主账号会创建独立网页实例和非持久数据存储，不能返回原账号的历史。对用户亲自点击的外部应用链接显示地址并先询问；网页关闭窗口正常返回。手机赛事、两种找回密码页面按 WebKit 的相应内容模式打开，笔记入口使用原生编辑器或同一稿件的官方编辑器
- /ssWeb 是空间合集和系列的两个稿件列表，并非嵌入网页。CreatorArchiveCatalog 按真实 mid 及 season_id/series_id、正反顺序和页码读取，调用者带来源、起播条目和计数。/dlna 进入 CastView 和实际发现/transport 链，见 dlna-cast.md
- Checks/discovery_readback.py 已运行生产模型：时区日期、综合/单类、7 种结果/分区、混合资源跳转、屏蔽、匿名和丢失回执。网页/搜索/频道控件与 iOS 17 部署目标完成 iPhoneOS 27.1 SDK 类型检查；未用真人账号进行验证、改密码或提交反馈

登录设备页保留设备名称、时间、来源与当前设备标志，还可手动打开[官方登录设备管理](https://www.bilibili.com/h5/validate/device)。其规范地址 https://account.bilibili.com/h5/account-h5/device 匿名 GET 返回页面 200，官方页面本身区分 App 内访问与普通网页。转交只包含固定网址，不把当前账号的 Cookie、移动令牌、设备号放入链接
