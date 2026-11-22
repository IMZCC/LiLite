import Foundation

struct SettingSearchRow: Identifiable {
  let screen: String, anchor: String, title: String, section: String, extra: String
  var cellular: Bool? = nil
  var id: String { cellular.map { anchor + ($0 ? ":cell" : ":wifi") } ?? anchor }
  func location(_ d: UserDefaults = .standard) -> (anchor: String, hint: String?) {
    func flag(_ key:String, _ fallback:Bool) -> Bool { d.object(forKey:key) as? Bool ?? fallback }
    func json(_ k:String) -> [String:Any] { d.data(forKey:k).flatMap { (try? JSONSerialization.jsonObject(with:$0)) as? [String:Any] } ?? [:] }
    switch anchor {
    case "SettingsView/图片叠加色" where (d.object(forKey:"images.nightTint") as? NSNumber)?.uint32Value ?? UInt32.max == UInt32.max:
      return ("SettingsView/深色模式调暗网络图片","需先开启图片调暗")
    case "ThemePicker/自定义颜色","ThemePicker/预设颜色":
      if flag("appearance.systemTint",false) { return ("ThemePicker/跟随系统强调色","需先关闭系统强调色") }
    case "MediaProfilePanel/添加编码":
      let m=json("play.networkMedia"), selected=cellular == true ? m["cellCodecs"] as? [String] : m["wifiCodecs"] as? [String]
      if cellular == true, selected == nil {return ("MediaProfilePanel/与 Wi-Fi 相同","需先使用独立编码顺序")}
      if Set(selected ?? ["AVC","AV1"]).isSuperset(of:["AVC","AV1","HEVC"]) {return ("MediaProfilePanel/视频编码优先顺序","已添加所有编码")}
    case "VODLineSettings/选择最快":
      return ("VODLineSettings/进入时测速","测速成功后可选最快线路")

    case "PlayerPreferencePanel/快速收藏夹" where !flag("detail.quickFav", false):
      return ("PlayerPreferencePanel/快速收藏", "需先开启快速收藏")
    case "RecommendationSettings/标出上次刷新的位置" where !flag("feed.keepPrevious", true):
      return ("RecommendationSettings/保留上次推荐", "需先开启保留上次推荐")
    case "PlayerPreferencePanel/横屏时展开简介" where flag("detail.expandIntro", false):
      return ("PlayerPreferencePanel/默认展开视频简介", "当前已默认展开简介")
    default: break
    }
    return (anchor,nil)
  }
  static let sections = [
    "SettingsView": "设置",
    "PlaybackOptionsView": "画面与音轨",
    "HighQualityPlaybackSettings": "高画质解析",
    "DecoderSettings": "视频解码",
    "GallerySettings": "图片与实况照片",
    "SuperChatSettings": "直播醒目留言",
    "SponsorSettings": "空降助手",
    "ViewportSettings": "播放控件与画面缩放",
    "APIProxyPanel": "接口代理",
    "ArtworkCacheSettings": "图片缓存",
    "AudioLevelSettings": "播放器音量与均衡",
    "ConnectionSettings": "网络连接",
    "DanmakuStylePanel": "弹幕样式与过滤",
    "DeviceIdentityPanel": "客户端设备标识",
    "InteractionScaleOptions": "界面与手势",
    "LiveCDNSettings": "直播 CDN",
    "MediaBufferSettings": "缓冲容量",
    "MediaProfilePanel": "网络画质和音轨",
    "MotionSettings": "页面切换",
    "NavigationLayoutPanel": "导航布局",
    "PlayerPreferencePanel": "详情与播放控制",
    "CaptionStylePanel": "字幕样式",
    "RecommendationSettings": "推荐过滤",
    "VersionPanel": "版本与更新",
    "ReplyFilterPanel": "评论设置",
    "SpeedSettings": "播放倍速",
    "ThemePicker": "主题颜色",
    "TypographyPanel": "字体与字号",
    "DisplayPanel": "刷新率",
    "VODLineSettings": "视频线路",
    "CommunityFilterPanel": "动态筛选",
    "BadgePreferences": "未读提醒",
  ]
  // Native names differ from the upstream settings. Keep the original terms searchable.
  static let aliases: [String:String] = [
    "音画同步":"音视频同步模式 视频同步 video-sync mpv display-resample display-tempo display-vdrop display-adrop display-desync desync",
    "音频时钟平滑":"音频同步 autosync 自动同步 音视频时钟抖动",
    "播放器增益":"音量放大 响度 播放声音增益",
    "均衡模式":"音频标准化 音量均衡 loudnorm dynaudnorm replaygain",
    "允许拖动字幕":"拖动字幕 手动移动字幕位置",
    "番剧与国创超分辨率":"Anime4K 超分辨率 补偿 着色器",
    "视频编码优先顺序":"H.264 AVC H.265 HEVC AV1 编码优先级",
    "提前载入播放器":"预初始化播放器 preInitializePlayer",
    "屏蔽滚动弹幕":"普通弹幕 滚动弹幕过滤",
    "播放控件与画面缩放":"填充 裁剪 拉伸 视频长宽比 画面比例",
    "番剧片头片尾":"跳过片头片尾 OP ED 跳过一次",
    "API 代理":"HTTP 代理 网络连接",
    "视频线路":"CDN 播放线路 分流测速",
    "账号屏蔽规则":"同步账号关键词弹幕屏蔽 正则 发送者",
    "空降助手":"SponsorBlock sponsor 广告跳过 空降片段",
    "保留上次推荐":"刷新推荐 不刷新旧内容",
    "本机屏蔽的 UP 主":"本地黑名单 屏蔽作者 UID",
    "直播醒目留言":"超级留言 SC Super Chat",
    "提醒原版更新":"检查更新 Release", "网络连接":"HTTP2 重试 代理",
    "深色模式使用纯黑背景":"OLED 黑色主题 夜间模式",
    "弹幕不透明度":"弹幕透明度 alpha",
    "举报":"反馈", "播放倍速":"视频速度 倍率",
    "允许密集弹幕重叠":"海量弹幕 massive",
    "界面缩放":"屏幕缩放 界面大小 textScale"
  ]
  static let all: [Self] = SettingSearchData.anchors.split(separator:"\n").flatMap { raw -> [Self] in
    let anchor = String(raw), parts = raw.split(separator:"/", maxSplits:1)
    guard parts.count == 2, let name = sections[String(parts[0])] else { return [] }
    let screen = String(parts[0]), title = String(parts[1])
    let extra = (aliases[title] ?? "") + " " + (SettingSearchTerms.byAnchor[anchor]?.keywords ?? "")
    if screen == "MediaProfilePanel" {
      return [false,true].filter { $0 || title != "与 Wi-Fi 相同" }.map { cellular in
        .init(screen:screen, anchor:anchor, title:title, section:cellular ? "蜂窝网络" : "Wi-Fi 与有线网络", extra:extra, cellular:cellular)
      }
    }
    return [.init(screen:screen,anchor:anchor,title:title,section:name,extra:extra)]
  }
  static func normalized(_ s: String) -> String {
    s.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive], locale: Locale(identifier:"zh_CN"))
      .lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
  }
  private struct IndexedRow {
    let row: SettingSearchRow
    let title: String
    let section: String
    let text: String
  }
  private static let index: [IndexedRow] = all.map { row in
    let title = normalized(row.title)
    let section = normalized(row.section)
    return IndexedRow(row: row, title: title, section: section,
      text: title + " " + section + " " + normalized(row.extra))
  }
  static func matches(_ query: String, defaults: UserDefaults = .standard) -> [Self] {
    let q = normalized(query), words = q.split(whereSeparator:\.isWhitespace).map(String.init)
    guard !words.isEmpty else { return [] }
    return index.compactMap { entry -> (Int, Self)? in
      let row = entry.row
      let t = entry.title
      let section = entry.section
      if !words.allSatisfy(entry.text.contains) {
        let value = SettingSearchTerms.value(for: row.anchor, defaults: defaults)
        guard !value.isEmpty else { return nil }
        let state = normalized(value)
        guard words.allSatisfy({ entry.text.contains($0) || state.contains($0) }) else { return nil }
      }
      let score = t == q ? 0 : t.hasPrefix(q) ? 1 : t.contains(q) ? 2 : section == q ? 3 : 4
      return (score,row)
    }.sorted { l,r in
      if l.0 != r.0 { return l.0 < r.0 }
      return l.1.id < r.1.id
    }.map(\.1)
  }
}
