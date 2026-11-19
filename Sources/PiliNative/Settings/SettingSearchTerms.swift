// Upstream titles, subtitles and non-sensitive scalar settings, matched to their native controls.
import Foundation

enum SettingSearchTerms {
  struct Terms { let keywords: String, storage: String, fallback: String }
  private static let rows = """
APIProxyPanel/使用 HTTP 代理	enableSystemProxy 设置代理 设置代理 host:port
AudioLevelSettings/音量	playerVolume 当前:「 % 播放器音量	audio.gainPercent	100.0
BadgePreferences/定时检查更新	checkDynamic 检查未读动态 点击设置检查周期(min	badge.periodic	true
CaptionStylePanel/允许拖动字幕	enableDragSubtitle 启用拖拽字幕调整底部边距	caption.drag	false
CaptionStylePanel/字重	subtitleFontWeight	caption.weight	6.0
CaptionStylePanel/底部边距	subtitlePaddingB	caption.bottom	24.0
CaptionStylePanel/描边	subtitleStrokeWidth	caption.stroke	2.0
CaptionStylePanel/水平边距	subtitlePaddingH	caption.horizontal	24.0
CaptionStylePanel/背景不透明度	subtitleBgOpaticy	caption.opacity	0.67
CommunityFilterPanel/UP 主面板	upPanelPosition 动态页UP主显示位置
CommunityFilterPanel/公开动态和转发	enableCreateDynAntifraud 发布/转发动态反诈 发布/转发动态后检查动态是否可见	social.verifyPost	false
CommunityFilterPanel/展开正在直播的 UP 主	expandDynLivePanel 动态页展开正在直播UP列表	social.expandLive	false
CommunityFilterPanel/显示争议信息	showDynDispute 显示动态警告/争议信息	social.dispute	false
CommunityFilterPanel/显示互动摘要	showDynInteraction 开启后则在动态卡片底部显示互动内容（如关注的人点赞、热评等 显示动态互动内容	social.interaction	true
CommunityFilterPanel/显示关注的全部 UP 主	dynamicsShowAllFollowedUp 动态页显示所有已关注UP主	social.allFollowed	false
CommunityFilterPanel/显示动态详情操作栏	showDynActionBar 动态/专栏详情页展示底部操作栏	social.actionBar	true
CommunityFilterPanel/评论	enableCommAntifraud 发评反诈 发送评论后检查评论是否可见	social.verifyReply	false
CommunityFilterPanel/隐藏带货动态		social.hideGoods	false
CommunityFilterPanel/默认分类	defaultDynamicType 动态展示	social.defaultFeed	0
ConnectionSettings/HTTP 协议	enableHttp2 启用HTTP/2	network.negotiateHTTP2	false
ConnectionSettings/允许无效证书	badCertificateCallback 禁用 SSL 证书验证 谨慎开启，禁用容易受到中间人攻击	network.allowInvalidCertificates	false
ConnectionSettings/网页链接默认用浏览器打开	openInBrowser 使用外部浏览器打开链接	web.external	false
ConnectionSettings/重试间隔	retryDelay	network.retryDelay	500
DecoderSettings/使用硬件解码	enableHA 以较低功耗播放视频，若异常卡死请关闭 开启硬解	decoder.hardware	true
DisplayPanel/强制 120Hz	高刷 高刷新率 ProMotion 120 帧率 fps 流畅	display.force120	false
GallerySettings/保存时隐藏进度提示	silentDownImg 不显示下载 Loading 弹窗 静默下载图片	images.silentSave	false
GallerySettings/大图质量	previewQuality	images.previewQuality	100
GallerySettings/横屏时在面板中查看	horizontalPreview 横屏在侧栏打开图片预览	images.sidePreview	false
GallerySettings/缩略图质量	defaultPicQa	images.quality	10
GallerySettings/长按缩略图显示菜单	enableImgMenu 长按/右键显示图片菜单	images.longMenu	false
GallerySettings/预览实况照片	enableLivePhoto 开启则以视频形式预览 Live Photo，否则预览静态图片 预览 Live Photo	images.live	true
InteractionScaleOptions/指示器高度	refreshDisplacement 刷新指示器高度 当前指示器高度:  , 刷新滑动距离	list.refreshDisplacement	20.0
InteractionScaleOptions/起始距离	touchSlopH 当前:「 」，系统默认值 横向滑动阈值	gesture.horizontalThreshold	24.0
MediaProfilePanel/直播	liveQualityCellular 当前画质 蜂窝网络直播默认画质 liveQuality 直播默认画质
MediaProfilePanel/音质	defaultAudioQaCellular 当前音质 蜂窝网络音质 defaultAudioQa 默认音质
MotionSettings/过渡效果	pageTransition 页面过渡动画
NavigationLayoutPanel/底部导航栏	hideTabBar
NavigationLayoutPanel/首页搜索栏	hideSearchBar
NavigationLayoutPanel/默认栏目	defaultHomePage 默认启动页
NavigationLayoutPanel/改用侧边栏	useSideBar 侧边栏 iPad 平板 横屏
PlaybackOptionsView/播放器内核	mpv AVPlayer libmpv 播放器内核 画中画 隔空播放
PlaybackOptionsView/游客播放优先使用可用的 1080P	p1080 免登录1080P 免登录查看1080P视频	play.guestPublicHD	true
PlayerPreferencePanel/上下滑动切换全屏	enableSlideFS 中间滑动进入/退出全屏	theater.swipe	true
PlayerPreferencePanel/上下滑动调节亮度和音量	enableSlideVolumeBrightness 左右侧滑动调节亮度/音量	player.slideLevels	true
PlayerPreferencePanel/使用横屏布局	horizontalScreen 启用横屏布局与逻辑，平板、折叠屏等可开启；建议全屏方向设为【不改变当前方向】 横屏适配
PlayerPreferencePanel/全屏方向	fullScreenMode 当前全屏方向 默认全屏方向
PlayerPreferencePanel/全屏显示截图按钮	showFsScreenshotBtn 全屏显示截图按钮	theater.captureButton	true
PlayerPreferencePanel/全屏显示点赞、投币和收藏	showFSActionItem 全屏展示点赞/投币/收藏等操作按钮	theater.actionBar	true
PlayerPreferencePanel/全屏显示电量	showBatteryLevel 全屏显示电池电量	theater.battery	true
PlayerPreferencePanel/全屏显示锁定按钮	showFsLockBtn 全屏显示锁定按钮	theater.lockButton	true
PlayerPreferencePanel/分 P 或合集倒序后从首集播放	reverseFromFirst 分P/合集：倒序播放从首集开始播放 开启则自动切换为倒序首集，否则保持当前集	play.reverseFirst	true
PlayerPreferencePanel/切到后台时暂停视频	pauseOnMinimize 最小化时暂停/还原时播放	play.pauseWhenBackground	false
PlayerPreferencePanel/双击左右两侧快退或快进	enableQuickDouble 双击快退/快进 左侧双击快退/右侧双击快进，关闭则双击均为暂停/播放	player.quickDouble	true
PlayerPreferencePanel/反转全屏手势方向	fullScreenGestureReverse 全屏手势反向 默认播放器中部向上滑动进入全屏，向下退出 n开启后向下全屏，向上退出	theater.reverseSwipe	false
PlayerPreferencePanel/启用播放快捷键	keyboardControl 启用键盘控制	player.keyboard	true
PlayerPreferencePanel/开始播放时进入全屏	enableAutoEnter 自动全屏 视频开始播放时进入全屏	theater.autoEnter	false
PlayerPreferencePanel/快进快退	fastForBackwardDuration 双击快进/快退时长	player.seekStep	10.0
PlayerPreferencePanel/快速收藏	enableQuickFav 快速收藏 点击设置默认收藏夹 n点按收藏至默认，长按选择文件夹	detail.quickFav	false
PlayerPreferencePanel/扩大竖屏视频画面	enableVerticalExpand 小屏竖屏视频宽高比由16:9扩大至1:1（不支持收起）；横屏适配时，扩大至9:16 竖屏扩大展示	layout.verticalMedia	false
PlayerPreferencePanel/投币时同时点赞	coinWithLike	detail.coinLike	false
PlayerPreferencePanel/拖动时预览画面	showSeekPreview 滑动跳转预览视频缩略图	player.seekPreview	true
PlayerPreferencePanel/按视频时长比例滑动	useRelativeSlide 滑动快进/快退使用相对时长	player.relativeSeek	false
PlayerPreferencePanel/提前载入播放器	preInitPlayer 提前初始化播放器 相对减少手动播放加载时间	play.preinitialize	false
PlayerPreferencePanel/播完退出全屏	enableAutoExit 自动退出全屏 视频结束播放时退出全屏	theater.autoExit	true
PlayerPreferencePanel/播放器调整仅用于本次播放	tempPlayerConf 弹幕、字幕及部分设置中没有的设置除外 播放器设置仅对当前生效	play.temporaryPreferences	false
PlayerPreferencePanel/显示正在观看人数	enableOnlineTotal 展示同时在看人数 观看人数	detail.online	false
PlayerPreferencePanel/显示相关推荐	showRelatedVideo 视频页显示相关视频	detail.related	true
PlayerPreferencePanel/显示视频争议提示	showArgueMsg 显示视频警告/争议信息	detail.argue	true
PlayerPreferencePanel/显示视频总结	enableAi 启用AI总结 视频详情页开启AI总结	detail.summary	false
PlayerPreferencePanel/显示视频章节	showViewPoints 显示视频分段信息	detail.chapters	true
PlayerPreferencePanel/显示评论入口	showVideoReply 显示视频评论	detail.replies	true
PlayerPreferencePanel/显示高能进度条	showDmChart 显示高能进度条 高能进度条反应了在时域上，单位时间内弹幕发送量的变化趋势	player.trend	false
PlayerPreferencePanel/横屏时展开简介	exapndIntroPanelH	detail.expandWide	false
PlayerPreferencePanel/滚轮调节音量	enableScrollVolume 滚轮调节音量	player.scrollVolume	true
PlayerPreferencePanel/画中画时暂停加载视频弹幕	pipNoDanmaku 当弹幕开关开启时，小窗屏蔽弹幕以获得较好的体验 画中画不加载弹幕	dm.quietPiP	false
PlayerPreferencePanel/续播上次观看的分 P	continuePlayingPart 显示继续播放分P提示	play.continuePart	true
PlayerPreferencePanel/自动进入画中画	autoPiP 后台画中画 进入后台时以小窗形式（PiP）播放	play.autoPiP	false
PlayerPreferencePanel/视频详情使用深色外观	darkVideoPage 视频播放页使用深色主题	detail.dark	false
PlayerPreferencePanel/触感反馈	feedBackEnable 请确定手机设置中已开启震动反馈 震动反馈	ui.haptics	false
PlayerPreferencePanel/进入后台时继续播放	continuePlayInBackground 后台播放 进入后台时继续播放	play.background	false
PlayerPreferencePanel/进入详情页自动播放	autoPlayEnable 自动播放 进入详情页自动播放	play.onEntry	false
PlayerPreferencePanel/锁屏与控制中心播放控件	enableBackgroundPlay 后台音频服务 避免画中画没有播放暂停功能	play.systemMedia	true
PlayerPreferencePanel/长按时使用当前倍速的两倍	enableAutoLongPressSpeed	player.doubleSpeed	false
PlayerPreferencePanel/音画同步	videoSync 当前： （此项即mpv的--video-sync 视频同步	play.videoSync	system
PlayerPreferencePanel/音频时钟平滑	autosync 当前： （此项即mpv的--autosync 自动同步	play.autosync	0
PlayerPreferencePanel/默认字幕	subtitlePreferenceV2 当前选择偏好 自动启用字幕	caption.preference	0
PlayerPreferencePanel/默认展开视频简介	alwaysExapndIntroPanel	detail.expandIntro	false
RecommendationSettings/使用移动端推荐	appRcmd 若web端推荐不太符合预期，可尝试切换至app端推荐 首页使用app端推荐	feed.mobile	true
RecommendationSettings/保留上次推荐	enableSaveLastData 下拉刷新时保留上次内容 保留首页推荐刷新	feed.keepPrevious	true
RecommendationSettings/同时筛选相关视频	applyFilterToRelatedVideos 其它（如热门视频、搜索等）均不受过滤器影响，无法豁免相关视频中的已关注UP 过滤器也应用于详情页相关视频
RecommendationSettings/屏蔽分区关键词或正则表达式	banWordForZone 分区关键词过滤
RecommendationSettings/屏蔽标题关键词或正则表达式	banWordForRecommend 标题关键词过滤
RecommendationSettings/推荐中豁免已关注的 UP 主	exemptFilterForFollowed 已关注UP豁免推荐过滤 推荐中已关注用户发布的内容不会被过滤
RecommendationSettings/显示榜单快捷入口	showHotRcmd 显示热门推荐 热门页面显示每周必看等推荐内容入口	feed.hotEntrances	false
RecommendationSettings/最低播放量	minPlayForRcmd 推荐、热门、分区、相关视频 播放量
RecommendationSettings/最低点赞率	minLikeRatioForRecommend Web推荐、热门、分区 点赞率
RecommendationSettings/最短时长（秒）	minDurationForRcmd 推荐、相关视频 视频时长
RecommendationSettings/标出上次刷新的位置	savedRcmdTip 保留上次推荐时，在上次刷新位置显示提示 显示上次看到位置提示	feed.retainedTip	true
RecommendationSettings/首个推荐使用大卡片	大卡片 首卡 推荐卡片 双列 卡片样式	feed.featuredFirst	false
ReplyFilterPanel/主评论	replySortType 评论展示	reply.mainSort	1
ReplyFilterPanel/从屏幕边缘滑动返回	slideDismissReplyPage 侧滑关闭二级页面	reply.edgeDismiss	true
ReplyFilterPanel/屏蔽关键词或正则表达式	banWordForReply 评论关键词过滤
ReplyFilterPanel/屏蔽只包含 @ 的评论	blockAtOnlyReply 屏蔽只包含@的评论
ReplyFilterPanel/屏蔽复制视频简介的评论	filterIntro 屏蔽复制简介评论
ReplyFilterPanel/屏蔽带货评论	antiGoodsReply 屏蔽带货评论
ReplyFilterPanel/折叠行数	replyLengthLimit
ReplyFilterPanel/显示头像挂件和装扮卡	showDynDecorate	appearance.decorate	true
ReplyFilterPanel/显示番剧评论	showBangumiReply 显示番剧评论	detail.episodeReplies	true
ReplyFilterPanel/楼中楼	reply2SortType 楼中楼评论展示	reply.detailSort	0
ReplyFilterPanel/点按预览正文表情	enableEmoteTooltip 点击表情显示 Tooltip	emote.preview	false
ReplyFilterPanel/视频详情默认显示评论	defaultShowComment 在视频详情页默认切换至评论区页（仅Tab型布局 默认展示评论区	reply.openFirst	false
ReplyFilterPanel/评论关键词搜索	enableWordRe 展示评论区搜索关键词 评论区搜索关键词	reply.wordSearch	false
SettingsView/保存搜索记录		search.save	true
SettingsView/外观模式	themeMode
SettingsView/弹幕不透明度		dm.opacity	1.0
SettingsView/提示不透明度	defaultToastOp	ui.toastOpacity	1.0
SettingsView/播放器内核	mpv AVPlayer libmpv 播放器内核 画中画 隔空播放
SettingsView/显示弹幕		video.danmaku.enabled	true
SettingsView/显示搜索默认词	enableSearchWord 搜索默认词 是否展示搜索框默认词	search.defaultWord	false
SettingsView/显示热搜	enableHotKey 大家都在搜 是否展示「大家都在搜	search.hot	true
SettingsView/显示猜你想搜	enableSearchRcmd 搜索发现 是否展示「搜索发现	search.picks	true
SettingsView/深色模式使用纯黑背景	isPureBlackTheme 纯黑主题	appearance.pureBlack	false
SettingsView/滚动弹幕区域		dm.area	0.5
SettingsView/点按弹幕时悬停	enableTapDm 启用点击弹幕 点击弹幕悬停，支持点赞、复制、举报操作	dm.tap	true
SettingsView/番剧首页显示更新日历	showPgcTimeline 展示追番时间表	discovery.pgcTimeline	true
SettingsView/空间显示 UP 主的小店	showMemberShop 显示UP主页小店TAB	creator.shop	false
SettingsView/自动领取大会员经验	大会员 经验 领取 每日 签到	vip.autoExperience	true
SettingsView/记住播放进度		play.remember	true
SettingsView/输入时显示搜索建议	searchSuggestion 搜索建议	search.suggest	true
SettingsView/隐藏收到的赞		inbox.hideLikes	false
SettingsView/默认倍速		play.rate	1.0
SpeedSettings/长按时使用当前倍速的两倍	enableAutoLongPressSpeed	player.doubleSpeed	false
SponsorSettings/使用空降助手		sponsor.enabled	false
SponsorSettings/向服务器统计跳过次数	blockTrack
SponsorSettings/显示跳过提示	blockToast
SponsorSettings/最短自动跳过时长（秒）	blockLimit
SuperChatSettings/不透明度	fullScreenSCOpacity	live.paidOpacity	1.0
SuperChatSettings/宽度	fullScreenSCWidth	live.paidWidth	255.0
SuperChatSettings/显示新收到的留言	enableFullScreenSC	live.paidFullscreen	true
SuperChatSettings/显示粉丝勋章	showMedal 显示粉丝勋章	live.medal	true
SuperChatSettings/缩放	fullScreenSCScale	live.paidScale	1.0
SuperChatSettings/醒目留言	superChatType SuperChat (醒目留言) 显示类型	live.paidMode	0
ThemePicker/跟随系统强调色		appearance.systemTint	false
TypographyPanel/字号	textScale
TypographyPanel/字重	appFontWeightV2
VODLineSettings/进入时测速	cdnSpeedTest CDN 测速 测速通过模拟加载视频实现，注意流量消耗，结果仅供参考	vod.speedTest	true
VODLineSettings/音频单独选线	disableAudioCDN 直接采用备用 URL，可解决部分视频无声 音频不跟随 CDN 设置	vod.independentAudio	false
VersionPanel/提醒新版本	autoUpdate 检查更新 每次启动时检查是否需要更新	updates.automatic	true
ViewportSettings/双指允许缩小画面	enableShrinkVideoSize 启用双指缩小视频	player.shrink	true
ViewportSettings/底部进度条	btmProgressBehavior 底部进度条展示	player.bottomProgress	0
ViewportSettings/延长播放控件显示时间	enableLongShowControl 延长播放控件显示时间 开启后延长至30秒，便于屏幕阅读器滑动切换控件焦点	player.longControls	false
ViewportSettings/播放画面延伸到屏幕边缘	removeSafeArea 播放页移除安全边距	player.edgeToEdge	false
ViewportSettings/番剧与国创超分辨率	superResolutionType 当前:「 」 n默认设置对番剧生效, 其他视频默认关闭 n超分辨率需要启用硬件解码, 若启用硬件解码后仍然不生效, 尝试切换硬件解码器为 auto-copy 超分辨率	player.upscale	0
"""
  static let byAnchor: [String:Terms] = {
    var result: [String:Terms] = [:]
    for line in rows.split(separator:"\n") {
      let fields = line.split(separator:"\t", omittingEmptySubsequences:false).map(String.init)
      guard fields.count >= 2 else { continue }
      result[fields[0]] = .init(keywords:fields[1], storage:fields.count > 2 ? fields[2] : "", fallback:fields.count > 3 ? fields[3] : "")
    }
    return result
  }()
  static func value(for anchor: String, defaults: UserDefaults) -> String {
    guard let v = byAnchor[anchor], !v.storage.isEmpty else { return "" }
    let saved = defaults.object(forKey: v.storage)
    if v.fallback == "true" || v.fallback == "false" {
      return (saved as? Bool ?? (v.fallback == "true")) ? "已开启 已启用 打开" : "已关闭 已停用"
    }
    if v.storage == "play.autosync" || v.storage == "play.videoSync" { return (saved as? String) ?? v.fallback }
    return (saved as? NSNumber)?.stringValue ?? v.fallback
  }
}
