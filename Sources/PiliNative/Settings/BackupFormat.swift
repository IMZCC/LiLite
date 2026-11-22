import CoreFoundation
import Foundation

/// Translates only fields with a known source representation. The native extension
/// stores settings with no upstream equivalent; it is ignored by Hive's importer.
enum BackupFormat {
  typealias Map = [String: Any]
  static let limit = 4 * 1024 * 1024
  enum Kind {
    case orderedNames([String]), fontName, pointScale(Double), indexedWeight, splitRatio, nullableText, liveFormat, audioMode, nightARGB, unreadKinds, flag, text,
      integer,
      optionalInteger,
      decimalID,
      orientation,
      number, speeds, spring,
      integerList,
      stringList,
      choice(
        [String])
    func convert(_ value: Any, importing: Bool) throws -> Any {
      let n = value as? NSNumber
      let bool = n.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
      switch self {
      case .orderedNames(let names):
        if importing {
          guard let raw = value as? [Any] else { break }
          let indexes = try raw.map { try Kind.integer.convert($0, importing: true) as! Int }
          guard Set(indexes).count == indexes.count, indexes.allSatisfy(names.indices.contains) else { break }
          return indexes.isEmpty ? names : indexes.map { names[$0] }
        }
        if let values = value as? [String] { return values.compactMap { names.firstIndex(of: $0) } }
      case .fontName:
        if importing && value is NSNull { return "" }
        if let v = value as? String, v.count <= 180, !v.contains("/"), !v.contains("\\"), !v.unicodeScalars.contains(where: { $0.value < 32 }) {
          if v.isEmpty && !importing { return NSNull() }
          return v
        }
      case .pointScale(let base):
        if !bool, let d = n?.doubleValue, d.isFinite {
          if importing && (0.5...2.5).contains(d) { return d * base }
          if !importing && (0.5...2.5).contains(d / base) { return d / base }
        }
      case .indexedWeight:
        if !bool, let d = n?.doubleValue, let i = Int(exactly: d) {
          if importing && (0...8).contains(i) { return i + 1 }
          if !importing && (1...9).contains(i) { return i - 1 }
        }
      case .splitRatio:
        if importing, let a = value as? [Any], a.count == 2,
          let left = try Kind.number.convert(a[0], importing: true) as? Double,
          let right = try Kind.number.convert(a[1], importing: true) as? Double,
          (10...90).contains(left), (10...90).contains(right), abs(left + right - 100) <= 0.011
        {
          return left
        }
        if !importing, !bool, let left = n?.doubleValue, left.isFinite, (10...90).contains(left) {
          return [left, 100 - left]
        }
      case .flag: if bool, let n { return n.boolValue }
      case .text: if let s = value as? String { return s }
      case .decimalID:
        if value is NSNull { return NSNull() }
        if importing, !bool, let n, let id = Int64(n.stringValue), id > 0 { return String(id) }
        if !importing, let s = value as? String, let id = Int64(s), id > 0, String(id) == s {
          return id
        }
      case .audioMode:
        if importing, !bool, n?.doubleValue == 4 { return "播完暂停" }
        return try Kind.choice(["播完暂停", "顺序播放", "单曲循环", "列表循环"]).convert(
          value, importing: importing)
      case .orientation:
        guard let i = try Kind.integer.convert(value, importing: importing) as? Int,
          (0...5).contains(i)
        else { throw ServiceError("全屏方向无效") }
        return i == 5 ? 1 : i
      case .nightARGB:
        if importing, value is NSNull { return Int(UInt32.max) }
        if !bool, let d = n?.doubleValue, let v = UInt32(exactly: d) {
          if !importing, v == UInt32.max { return NSNull() }
          return Int(v)
        }
      case .optionalInteger:
        if value is NSNull { return NSNull() }
        return try Kind.integer.convert(value, importing: importing)
      case .integer:
        if !bool, let d = n?.doubleValue, let i = Int(exactly: d) { return i }
      case .number: if !bool, let d = n?.doubleValue, d.isFinite { return d }
      case .unreadKinds:
        if importing, let a = value as? [Any] {
          var bits = 0
          for item in a {
            guard let n = try Kind.integer.convert(item, importing: true) as? Int,
              (0...4).contains(n)
            else { throw ServiceError("未读分类无效") }
            bits |= 1 << n
          }
          return bits
        }
        if !importing, !bool, let d = n?.doubleValue, let bits = Int(exactly: d),
          (0...31).contains(bits)
        {
          return (0...4).filter { bits & (1 << $0) != 0 }
        }
      case .integerList:
        if let a = value as? [Any] {
          return try a.map { try Kind.integer.convert($0, importing: importing) }
        }
      case .nullableText:
        if value is NSNull { return NSNull() }
        if let s = value as? String { return s }
      case .liveFormat:
        if value is NSNull { return NSNull() }
        if let a = value as? [String], a.count == 3,
          a.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 32 && $0.utf8.allSatisfy({ (33...126).contains($0) })
          })
        {
          return a
        }
      case .stringList: if let a = value as? [String] { return a }
      case .spring:
        if let a = value as? [Any], a.count == 3 {
          let numbers = try a.map { try Kind.number.convert($0, importing: importing) as! Double }
          if numbers.allSatisfy({ (0.000001...1_000_000).contains($0) }) { return numbers }
        }
      case .speeds:
        if let a = value as? [Any], !a.isEmpty {
          return try a.map { try Kind.number.convert($0, importing: importing) }
        }
      case .choice(let choices):
        if importing {
          if !bool, let d = n?.doubleValue, let i = Int(exactly: d), choices.indices.contains(i) {
            return choices[i]
          }
        } else if let s = value as? String, let i = choices.firstIndex(of: s) {
          return i
        }
      }
      throw ServiceError("备份中的设置值无效")
    }
  }
  struct Field {
    let box: String, key: String, path: [String], kind: Kind
    init(_ key: String, _ path: [String], _ kind: Kind, _ box: String = "setting") {
      self.box = box
      self.key = key
      self.path = path
      self.kind = kind
    }
  }
  static let fields: [Field] = {
    var f: [Field] = [
      .init("navBarSort", ["layout", "tabs"], .orderedNames(["home","dynamics","mine"])),
      .init("defaultHomePage", ["layout", "launch"], .choice(["home","dynamics","mine"])),
      .init("tabBarSort", ["layout", "channels"], .orderedNames(["直播","推荐","热门","分区","番剧","影视"])),
      .init("textScale", ["typeface","scale"], .number), .init("appFontWeightV2", ["typeface","weight"], .indexedWeight),
      .init("appFont", ["typeface","name"], .fontName),
      .init("buvid", ["guestDevice"], .text),
      .init("springDescription", ["scrollSpring"], .spring),
      .init("pageTransition", ["controls", "numbers", "layout.pageMotion"], .integer),
      .init("touchSlopH", ["controls", "numbers", "gesture.horizontalThreshold"], .number),
      .init("refreshDisplacement", ["controls", "numbers", "list.refreshDisplacement"], .number),
      .init("uiScale", ["controls", "numbers", "layout.interfaceScale"], .number),
      .init("playerVolume", ["controls", "numbers", "audio.gainPercent"], .number),
      .init("audioNormalization", ["normalizer"], .text), .init("fallbackNormalization", ["fallbackNormalizer"], .text),
      .init("customColor", ["themeSeed"], .integer), .init("schemeVariant", ["paletteStyle"], .integer),
      .init("themeMode", ["appearance"], .choice(["light", "dark", "system"])),
      .init("pgcSkipType", ["episodeSkip"], .choice(["always", "once", "manual", "show", "off"])),
      .init("enableShowDanmaku", ["bullets"], .flag),
      .init("subtitleFontScale", ["subtitleSize"], .pointScale(16)),
      .init("subtitleFontScaleFS", ["controls","numbers","caption.fullSize"], .pointScale(16)),
      .init("subtitleFontWeight", ["controls","numbers","caption.weight"], .indexedWeight),
      .init("danmakuFontScale", ["dmSize"], .pointScale(15)),
      .init("danmakuFontScaleFS", ["fullDmSize"], .pointScale(15)),
      .init("fontWeight", ["danmakuStyle","fontWeight"], .indexedWeight),
      .init("danmakuOpacity", ["opacity"], .number), .init("danmakuShowArea", ["area"], .number),
      .init("enableLog", ["diagnosticLog"], .flag), .init("banWordForDyn", ["dynamicRegex"], .text),
      .init("antiGoodsDyn", ["hideGoods"], .flag),
      .init("disableLikeMsg", ["hideLikeNotices"], .flag),
      .init("recordSearchHistory", ["searchHistory"], .flag),
      .init("enableSponsorBlock", ["sponsorEnabled"], .flag),
      .init("blockServer", ["sponsorServer"], .text),
      .init("cacheVideoFit", ["gravity"], .choice(["stretch","fit","fill","width","height","original","down","fourThree","sixteenNine"]), "video"),
      .init("playSpeedDefault", ["rate"], .number, "video"),
      .init("speedsList", ["speeds"], .speeds, "video"),
      .init("playRepeat", ["controls", "numbers", "play.repeat"], .integer, "video"),
      .init(
        "longPressSpeedDefault", ["controls", "numbers", "player.holdSpeed"], .number, "video"),
    ]
    for (up, key) in [
      ("showDynDecorate", "appearance.decorate"), ("enableEmoteTooltip", "emote.preview"),
      ("pipNoDanmaku", "dm.quietPiP"), ("preInitPlayer", "play.preinitialize"), ("pauseOnMinimize", "play.pauseWhenBackground"), ("autoUpdate", "updates.automatic"), ("enableScrollVolume", "player.scrollVolume"), ("enableWordRe", "reply.wordSearch"), ("openInBrowser", "web.external"),
      ("defaultShowComment", "reply.openFirst"), ("showPgcTimeline", "discovery.pgcTimeline"),
      ("showMemberShop", "creator.shop"),
      ("showArgueMsg", "detail.argue"), ("alwaysExapndIntroPanel", "detail.expandIntro"),
      ("exapndIntroPanelH", "detail.expandWide"),
    ] { f.append(.init(up, ["controls", "flags", key], .flag)) }
    f.append(.init("recommendCardWidth", ["controls", "numbers", "grid.recommendWidth"], .number))
    f.append(.init("smallCardWidth", ["controls", "numbers", "grid.cardWidth"], .number))
    f.append(.init("reverseFromFirst", ["controls", "flags", "play.reverseFirst"], .flag))
    for (up, key) in [
      ("darkVideoPage", "detail.dark"), ("showBatteryLevel", "theater.battery"),
      ("showFSActionItem", "theater.actionBar"),
    ] { f.append(.init(up, ["controls", "flags", key], .flag)) }
    f.append(.init("isPureBlackTheme", ["controls", "flags", "appearance.pureBlack"], .flag))
    f.append(.init("reduceLuxColor", ["controls", "numbers", "images.nightTint"], .nightARGB))
    f.append(.init("defaultToastOp", ["controls", "numbers", "ui.toastOpacity"], .number))
    f.append(
      .init("subtitlePreferenceV2", ["controls", "numbers", "caption.preference"], .integer))
    for (up, key) in [
      ("useSideBar", "sidebar"), ("hideSideBarLabel", "iconOnly"), ("optTabletNav", "tabletNav"),
      ("enableMYBar", "spaciousBar"), ("floatingNavBar", "floating"), ("hideSearchBar", "collapseTop"),
      ("hideTabBar", "collapseBottom"),
      ("mainTabBarView", "animateTabs"), ("directExitOnBack", "directBack"),
    ] {
      f.append(.init(up, ["layout", key], .flag))
    }
    f.append(.init("barHideType", ["layout", "hideMode"], .integer))
    f.append(.init("mineTabs", ["layout", "mineTabs"], .integerList))
    f.append(.init("enableHA", ["controls", "flags", "decoder.hardware"], .flag))
    f.append(.init("hardwareDecoding", ["decoderChoices"], .text))
    f.append(.init("superResolutionType", ["controls", "numbers", "player.upscale"], .integer))
    f.append(.init("tempPlayerConf", ["controls", "flags", "play.temporaryPreferences"], .flag))
    f.append(
      .init("btmProgressBehavior", ["controls", "numbers", "player.bottomProgress"], .integer))
    for (up, key) in [
      ("enableLongShowControl", "player.longControls"), ("enableShrinkVideoSize", "player.shrink"),
      ("removeSafeArea", "player.edgeToEdge"),
    ] {
      f.append(.init(up, ["controls", "flags", key], .flag))
    }
    f.append(.init("bufferSize", ["controls", "numbers", "play.bufferMB"], .number))
    f.append(.init("liveBufferSize", ["controls", "numbers", "live.bufferMB"], .number))
    f.append(.init("enableSystemProxy", ["apiProxy", "enabled"], .flag))
    f.append(.init("systemProxyHost", ["apiProxy", "host"], .text))
    f.append(.init("systemProxyPort", ["apiProxy", "port"], .text))
    f.append(.init("enableBackgroundPlay", ["controls", "flags", "play.systemMedia"], .flag))
    for (up, key) in [
      ("horizontalScreen", "layout.horizontal"),
      ("horizontalMemberPage", "layout.member"), ("enableVerticalExpand", "layout.verticalMedia"),
      ("dynamicsWaterfallFlow", "social.waterfall"),
    ] {
      f.append(.init(up, ["controls", "flags", key], .flag))
    }
    f.append(.init("memberTab", ["controls", "numbers", "creator.initialSection"], .integer))
    f.append(.init("upPanelPosition", ["controls", "numbers", "social.upPanelPosition"], .integer))
    f.append(
      .init("dynamicDetailRatio", ["controls", "numbers", "reading.bodyPercent"], .splitRatio))
    f.append(.init("CDNService", ["vodLine"], .text))
    f.append(.init("cdnSpeedTest", ["controls", "flags", "vod.speedTest"], .flag))
    f.append(.init("disableAudioCDN", ["controls", "flags", "vod.independentAudio"], .flag))
    f.append(.init("liveCdnUrl", ["liveCDN"], .nullableText))
    f.append(.init("liveStream", ["liveStream"], .liveFormat))
    f.append(.init("audioPlayMode", ["listenRepeat"], .audioMode))
    f.append(.init("videoSync", ["videoSync"], .text))
    f.append(.init("autosync", ["autosync"], .text))
    f.append(.init("maxCacheSize", ["controls", "numbers", "images.cacheBytes"], .number))
    f.append(.init("followOrderType", ["controls", "numbers", "follow.sort"], .integer))
    f.append(.init("p1080", ["controls","flags","play.guestPublicHD"], .flag))
    f.append(.init("enableHttp2", ["controls", "flags", "network.negotiateHTTP2"], .flag))
    f.append(.init("retryCount", ["controls", "numbers", "network.retryCount"], .integer))
    f.append(.init("retryDelay", ["controls", "numbers", "network.retryDelay"], .integer))
    f.append(.init("keyboardControl", ["controls", "flags", "player.keyboard"], .flag))
    f.append(.init("checkDynamic", ["controls", "flags", "badge.periodic"], .flag))
    for (up, key) in [
      ("dynamicBadgeMode", "badge.dynamicMode"), ("msgBadgeMode", "badge.messageMode"),
      ("dynamicPeriod", "badge.minutes"),
    ] { f.append(.init(up, ["controls", "numbers", key], .integer)) }
    f.append(.init("msgUnReadTypeV2", ["controls", "numbers", "badge.messageMask"], .unreadKinds))
    f.append(.init("enableCommAntifraud", ["controls", "flags", "social.verifyReply"], .flag))
    f.append(.init("enableCreateDynAntifraud", ["controls", "flags", "social.verifyPost"], .flag))
    f.append(.init("defaultDynamicType", ["controls", "numbers", "social.defaultFeed"], .integer))
    for (up, local) in [
      ("showDynInteraction", "social.interaction"), ("showDynDispute", "social.dispute"),
      ("showDynActionBar", "social.actionBar"), ("dynamicsShowAllFollowedUp", "social.allFollowed"),
      ("expandDynLivePanel", "social.expandLive"),
    ] { f.append(.init(up, ["controls", "flags", local], .flag)) }
    f.append(.init("autoPlayEnable", ["controls", "flags", "play.onEntry"], .flag))
    f.append(.init("continuePlayInBackground", ["controls", "flags", "play.background"], .flag))
    f.append(.init("bufferSec", ["controls", "numbers", "play.bufferSeconds"], .number))
    f.append(.init("liveBufferSec", ["controls", "numbers", "live.bufferSeconds"], .number))
    func add(_ mapping: [String: String], _ parent: [String], _ kind: Kind) {
      for (up, local) in mapping { f.append(.init(up, parent + [local], kind)) }
    }
    add(
      [
        "enableQuickDouble": "player.quickDouble",
        "enableSlideVolumeBrightness": "player.slideLevels",
        "useRelativeSlide": "player.relativeSeek", "enableAutoLongPressSpeed": "player.doubleSpeed",
        "enableAi": "detail.summary", "showViewPoints": "detail.chapters",
        "showRelatedVideo": "detail.related",
        "showBangumiReply": "detail.episodeReplies", "slideDismissReplyPage": "reply.edgeDismiss",
        "showVideoReply": "detail.replies", "coinWithLike": "detail.coinLike",
        "autoPiP": "play.autoPiP",
        "enableDragSubtitle": "caption.drag", "saveReply": "reply.save",
        "enableHotKey": "search.hot",
        "enableSearchRcmd": "search.picks", "searchSuggestion": "search.suggest",
        "enableShowLiveDanmaku": "live.showChat",
        "badCertificateCallback": "network.allowInvalidCertificates",
      ],
      ["controls", "flags"], .flag)
    add(
      [
        "fastForBackwardDuration": "player.seekStep", "sliderOffset": "player.slideRange",
        "subtitlePaddingH": "caption.horizontal", "subtitlePaddingB": "caption.bottom",
      ], ["controls", "numbers"], .integer)
    add(
      ["subtitleBgOpaticy": "caption.opacity", "subtitleStrokeWidth": "caption.stroke"],
      ["controls", "numbers"], .number)
    add(
      [
        "showVipDanmaku": "showVIP", "mergeDanmaku": "merge", "danmakuFixedV": "fixedVelocity",
        "danmakuStatic2Scroll": "convertFixed", "danmakuMassiveMode": "dense",
      ], ["danmakuStyle"], .flag)
    add(["danmakuWeight": "minimumWeight"], ["danmakuStyle"], .integer)
    add(
      [
        "danmakuDuration": "duration", "danmakuStaticDuration": "staticDuration",
        "strokeWidth": "stroke",
        "danmakuLineHeight": "lineHeight",
      ], ["danmakuStyle"], .number)
    add(
      [
        "minDurationForRcmd": "minimumSeconds", "minPlayForRcmd": "minimumViews",
        "minLikeRatioForRecommend": "minimumLikePercent",
      ], ["recommendation"], .integer)
    add(
      ["banWordForRecommend": "titlePattern", "banWordForZone": "zonePattern"], ["recommendation"],
      .text)
    add(
      ["exemptFilterForFollowed": "exemptFollowed", "applyFilterToRelatedVideos": "filterRelated"],
      ["recommendation"], .flag)
    add(
      [
        "antiGoodsReply": "goods", "blockAtOnlyReply": "mentionsOnly",
        "filterIntro": "duplicateIntro",
      ], ["replyFilter"], .flag)
    add(["banWordForReply": "pattern"], ["replyFilter"], .text)
    add(["blockReplyAtCount": "threshold"], ["replyFilter"], .optionalInteger)
    add(
      ["replySortType": "reply.mainSort", "reply2SortType": "reply.detailSort"],
      ["controls", "numbers"], .integer)
    add(
      ["enableQuickFav": "detail.quickFav", "feedBackEnable": "ui.haptics"], ["controls", "flags"],
      .flag)
    add(
      [
        "enableAutoEnter": "theater.autoEnter", "enableAutoExit": "theater.autoExit",
        "enableSlideFS": "theater.swipe", "fullScreenGestureReverse": "theater.reverseSwipe",
      ], ["controls", "flags"], .flag)
    add(["fullScreenMode": "theater.orientation"], ["controls", "numbers"], .orientation)
    add(
      ["enablePlayAll": "library.playAll", "continuePlayingPart": "play.continuePart"],
      ["controls", "flags"], .flag)
    add(["quickFavId": "quickFolder"], ["controls"], .decimalID)
    add(["replyLengthLimit": "lines"], ["replyFilter"], .integer)
    add(
      [
        "defaultVideoQa": "wifiVideo", "defaultVideoQaCellular": "cellVideo",
        "defaultAudioQa": "wifiAudio", "defaultAudioQaCellular": "cellAudio",
        "liveQuality": "wifiLive", "liveQualityCellular": "cellLive",
      ], ["networkMedia"], .integer)
    add(
      ["preferCodecs": "wifiCodecs", "preferCodecsCellular": "cellCodecs"], ["networkMedia"],
      .stringList)
    add(
      ["showSeekPreview": "player.seekPreview", "showDmChart": "player.trend"],
      ["controls", "flags"], .flag)
    add(
      [
        "showHotRcmd": "feed.hotEntrances", "appRcmd": "feed.mobile",
        "enableSaveLastData": "feed.keepPrevious",
        "savedRcmdTip": "feed.retainedTip",
        "enableSearchWord": "search.defaultWord", "enableOnlineTotal": "detail.online",
      ], ["controls", "flags"], .flag)
    add(["blockSettings": "modes"], ["sponsorRules"], .integerList)
    add(["blockColor": "colors"], ["sponsorRules"], .stringList)
    add(["blockLimit": "minimum"], ["sponsorRules"], .number)
    add(["blockToast": "toast", "blockTrack": "track"], ["sponsorRules"], .flag)
    add(["enableTapDm": "dm.tap"], ["controls", "flags"], .flag)
    add(
      ["enableFullScreenSC": "live.paidFullscreen", "showMedal": "live.medal"],
      ["controls", "flags"], .flag)
    add(["superChatType": "live.paidMode"], ["controls", "numbers"], .integer)
    add(
      [
        "fullScreenSCOpacity": "live.paidOpacity", "fullScreenSCScale": "live.paidScale",
        "fullScreenSCWidth": "live.paidWidth",
      ], ["controls", "numbers"], .number)
    add(
      [
        "enableLivePhoto": "images.live", "horizontalPreview": "images.sidePreview",
        "silentDownImg": "images.silentSave", "enableImgMenu": "images.longMenu",
      ], ["controls", "flags"], .flag)
    add(
      ["defaultPicQa": "images.quality", "previewQuality": "images.previewQuality"],
      ["controls", "numbers"], .integer)
    add(
      ["showFsLockBtn": "theater.lockButton", "showFsScreenshotBtn": "theater.captureButton"],
      ["controls", "flags"], .flag)
    return f
  }()
  static func read(_ data: Data) throws -> Map {
    guard !data.isEmpty, data.count <= limit else { throw ServiceError("设置备份超过大小限制或为空") }
    guard let m = try JSONSerialization.jsonObject(with: data) as? Map else {
      throw ServiceError("不是设置备份")
    }
    return m
  }
  static func serialize(_ map: Map) throws -> Data {
    let d = try JSONSerialization.data(
      withJSONObject: map, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    guard d.count <= limit else { throw ServiceError("设置备份过大") }
    return d
  }
  private static func put(_ value: Any, path: ArraySlice<String>, into m: inout Map) {
    guard let first = path.first else { return }
    if path.count == 1 {
      m[first] = value
      return
    }
    var child = m[first] as? Map ?? [:]
    put(value, path: path.dropFirst(), into: &child)
    m[first] = child
  }
  private static let dmModes = [2: "hideScroll", 4: "hideBottom", 5: "hideTop", 6: "monochrome", 7: "hideSpecial"]
  private static func overlay(_ old: Map, _ new: Map) -> Map {
    old.merging(new) { a, b in
      if let x = a as? Map, let y = b as? Map { return overlay(x, y) }; return b
    }
  }
  // Upstream settings whose Swift presentation is unavailable may be carried back to Flutter.
  // Only names in the fixed SettingBoxKey/VideoBoxKey inventories enter persistent storage.
  private static let portableKeys = Set("""
    angleDegrees audioOutput desktopVolume displayMode dynamicColor enableDocProvider isWindowMaximized
    maxVolume minimizeOnExit setSystemBrightness showTrayIcon showWindowTitleBar windowPosition windowSize danmakuBlockType
    """.split(whereSeparator: \.isWhitespace).map(String.init))
  static let forbidden: Set<String> = ["webdavUri","webdavUsername","webdavPassword","webdavDirectory","downloadPath","imageSavePath","blockUserID","biliSendCommAntifraud"]
  static func remainder(_ archive: Map) -> Map {
    var out: Map = [:]
    for name in ["setting","video"] {
      let mapped = Set(fields.filter { $0.box == name }.map(\.key))
      var extras = (archive[name] as? Map ?? [:]).filter { portableKeys.contains($0.key) && !mapped.contains($0.key) }
      if name == "setting", let modes = extras["danmakuBlockType"] as? [Int] {
        extras["danmakuBlockType"] = modes.filter { dmModes[$0] == nil }
      }
      out[name] = extras
    }
    return out
  }
  static func mergedCarry(_ saved: Map, _ remote: Map?) -> Map {
    guard let remote else { return saved }
    guard remote["setting"] != nil || remote["video"] != nil else { return saved }
    return overlay(saved, remote)
  }
  /// The Flutter importer clears both boxes. Reset absent represented preferences to their
  /// device defaults without resetting native-only preferences, credentials or locally generated identity.
  static func restorationBase(_ archive: Map, current: Map, defaults: Map) -> Map {
    guard archive["piliNative"] == nil, let setting = archive["setting"] as? Map,
      let video = archive["video"] as? Map else { return current }
    var result = current
    func replace(_ path: ArraySlice<String>, from source: Map, in map: inout Map) {
      guard let k = path.first else { return }
      if path.count == 1 { map[k] = source[k]; return }
      var nested = map[k] as? Map ?? [:]
      replace(path.dropFirst(),from:source[k] as? Map ?? [:],in:&nested)
      if !nested.isEmpty || map[k] != nil { map[k] = nested }
    }
    for field in fields where field.key != "buvid" {
      if (field.box == "video" ? video : setting)[field.key] == nil { replace(field.path[...],from:defaults,in:&result) }
    }
    if setting["danmakuBlockType"] == nil {
      for key in dmModes.values { replace(["danmakuStyle",key][...],from:defaults,in:&result) }
    }
    return result
  }
  static func native(_ archive: Map, current: Map) throws -> (Map, Int) {
    if archive["setting"] == nil && archive["video"] == nil && archive["piliNative"] == nil {
      guard let v = archive["version"], (try? Kind.integer.convert(v, importing: true)) as? Int == 1
      else { throw ServiceError("无法识别备份版本") }
      return (overlay(current, archive), 0)
    }
    guard var setting = archive["setting"] as? Map, let video = archive["video"] as? Map else {
      throw ServiceError("备份缺少设置或视频配置")
    }
    var m: Map
    if let raw = archive["piliNative"] {
      guard let ext = raw as? Map, let v = ext["version"],
        (try? Kind.integer.convert(v, importing: true)) as? Int == 1
      else { throw ServiceError("原生设置格式无效") }
      m = overlay(current, ext)
      // An explicitly stored controls dictionary is complete at its own schema version;
      // absence of a per-control override inside it restores the default behavior.
      if let controls = ext["controls"] as? Map, var target = m["controls"] as? Map {
        for key in ["flags","numbers"] where controls[key] != nil { target[key] = controls[key] }
        m["controls"] = target
      }
    } else {
      m = current
    }
    for (old, key) in [("showDecorate","showDynDecorate"), ("alwaysExpandIntroPanel","alwaysExapndIntroPanel"), ("expandIntroPanelH","exapndIntroPanelH")] {
      if setting[key] == nil, let oldValue = setting.removeValue(forKey: old) { setting[key] = oldValue }
    }
    let nativeLayout = (archive["piliNative"] as? Map)?["layout"] as? Map
    let oldFont = m["typeface"] as? Map
    var count = 0
    if let raw = setting["danmakuBlockType"] {
      let ids = Set(try Kind.integerList.convert(raw, importing: true) as! [Int])
      var style = (m["danmakuStyle"] as? Map) ?? (current["danmakuStyle"] as? Map) ?? [:]
      for (id, name) in dmModes { style[name] = ids.contains(id) }
      m["danmakuStyle"] = style
      count += 1
    }
    for field in fields {
      let box = field.box == "video" ? video : setting
      guard let raw = box[field.key] else { continue }
      if field.path.count > 1, let parent = field.path.first, m[parent] == nil {
        m[parent] = current[parent]
      }
      // Older native dual-format backups used a one-based fontWeight in both objects.
      if field.key == "appFont", let marker = raw as? String, marker.contains("/") {
        // A Hive custom family is an alias for the optional font file in a full data pack, never a path to open.
        // DataPack imports the separate font bytes only if the user selected that part.
        let alias = marker.split(separator: "/").last.map(String.init)
        if let existing = oldFont?["name"] as? String, existing == alias { count += 1 }
        continue
      }
      if field.key == "fontWeight", archive["piliNativeFormat"] == nil,
        let ext = archive["piliNative"] as? Map, let style = ext["danmakuStyle"] as? Map,
        let own = style["fontWeight"] as? Int, (1...9).contains(own), (raw as? NSNumber)?.intValue == own {
        count += 1
        continue
      }
      do {
        put(try field.kind.convert(raw, importing: true), path: field.path[...], into: &m)
      } catch { throw ServiceError("无法读取备份项：" + field.key) }
      count += 1
    }
    if setting["appFont"] != nil, var font = m["typeface"] as? Map, oldFont?["name"] as? String != font["name"] as? String {
      font["file"] = ""
      m["typeface"] = font
    }
    if setting["navBarSort"] != nil || setting["defaultHomePage"] != nil, var layout = m["layout"] as? Map {
      let originalTabs = ["home","dynamics","mine"]
      if let imported = layout["tabs"] as? [String], let ext = nativeLayout?["tabs"] as? [String],
        ext.filter(originalTabs.contains) == imported || (imported == originalTabs && ext == ["search"]) {
        layout["tabs"] = ext
      }
      if let tabs = layout["tabs"] as? [String], let first = tabs.first,
        !tabs.contains(layout["launch"] as? String ?? "home") {
        layout["launch"] = first
      }
      m["layout"] = layout
    }
    return (m, setting.count + video.count - count)
  }
  static func export(native: Map, over existing: Map? = nil) throws -> Data {
    var root = existing ?? [:]
    // Refuse to overwrite an unrelated JSON document.
    if let existing, existing["setting"] == nil && existing["video"] == nil {
      guard existing["version"] != nil else { throw ServiceError("远程文件不是设置备份") }
      root = [:]
    }
    var setting = (root["setting"] as? Map ?? [:]).filter { !forbidden.contains($0.key) }
    var video = (root["video"] as? Map ?? [:]).filter { !forbidden.contains($0.key) }
    root = [:]
    if let style = native["danmakuStyle"] as? Map, dmModes.values.contains(where: { style[$0] is Bool }) {
      let extra = (setting["danmakuBlockType"] as? [Int] ?? []).filter { dmModes[$0] == nil }
      let selected = dmModes.compactMap { style[$0.value] as? Bool == true ? $0.key : nil }
      setting["danmakuBlockType"] = Set(extra + selected).sorted()
    }
    for field in fields {
      let local = field.path.reduce(native as Any?) { ($0 as? Map)?[$1] }
      if field.key == "appFont", let font = native["typeface"] as? Map, let file = font["file"] as? String, !file.isEmpty {
        setting.removeValue(forKey: field.key)
        continue
      }
      if field.key == "defaultHomePage", local as? String == "search" {
        setting.removeValue(forKey: field.key)
        continue
      }
      if let points = local as? Double, (field.key == "danmakuFontScaleFS" && points > 37.5 || field.key == "subtitleFontScaleFS" && points > 40) {
        // Older native versions admitted 42 pt. Keep it in the native extension only.
        setting.removeValue(forKey: field.key)
        continue
      }
      if field.key == "audioPlayMode", local as? String == "随机播放" {
        setting.removeValue(forKey: field.key)
        continue
      }
      let v = try local.map { try field.kind.convert($0, importing: false) }
      if field.box == "video" { video[field.key] = v } else { setting[field.key] = v }
    }
    root["setting"] = setting
    root["video"] = video
    root["piliNativeFormat"] = 2
    root["piliNative"] = native
    return try serialize(root)
  }
}
