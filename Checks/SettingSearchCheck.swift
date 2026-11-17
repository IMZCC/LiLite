import Foundation

@main enum SettingSearchCheck {
  static func main() {
    let key = UUID().uuidString
    let prefs = UserDefaults(suiteName:key)!
    defer { prefs.removePersistentDomain(forName:key) }
    func locate(_ q:String,_ target:String)->Bool { SettingSearchRow.matches(q,defaults:prefs).contains { $0.anchor == target } }
    let all = SettingSearchRow.all
    precondition(Set(all.map(\.id)).count == all.count)
    precondition(Set(all.map(\.anchor)).count == SettingSearchData.anchors.split(separator:"\n").count)
    precondition(SettingSearchRow.matches(" \t ",defaults:prefs).isEmpty)
    precondition(locate("自动同步","PlayerPreferencePanel/音频时钟平滑"))
    precondition(locate("ＭＰＶ 视频同步","PlayerPreferencePanel/音画同步"))
    prefs.set("473",forKey:"play.autosync")
    precondition(locate("473 时钟","PlayerPreferencePanel/音频时钟平滑"))
    let mobile = "RecommendationSettings/使用移动端推荐"
    prefs.set(false,forKey:"feed.mobile")
    precondition(locate("移动端推荐 已关闭",mobile))
    precondition(!locate("移动端推荐 已开启",mobile))
    prefs.set(true, forKey: "network.allowInvalidCertificates")
    precondition(locate("badCertificateCallback 已开启", "ConnectionSettings/允许无效证书"))
    prefs.set(false, forKey: "play.continuePart")
    precondition(locate("continuePlayingPart 已关闭", "PlayerPreferencePanel/续播上次观看的分 P"))
    precondition(!locate("continuePlayingPart 已开启", "PlayerPreferencePanel/续播上次观看的分 P"))
    prefs.set(true, forKey: "ui.haptics")
    precondition(locate("feedBackEnable 已开启", "PlayerPreferencePanel/触感反馈"))
    prefs.set(1.75, forKey: "play.rate")
    precondition(locate("1.75 默认倍速", "SettingsView/默认倍速"))
    prefs.set(false, forKey:"feed.keepPrevious")
    let retained = all.first { $0.anchor == "RecommendationSettings/标出上次刷新的位置" }!
    precondition(retained.location(prefs).anchor == "RecommendationSettings/保留上次推荐")
    let hdr = all.filter { $0.anchor == "MediaProfilePanel/音质" }
    precondition(hdr.count == 2 && Set(hdr.compactMap(\.cellular)) == [false,true])
    precondition(all.filter { $0.anchor == "MediaProfilePanel/与 Wi-Fi 相同" }.allSatisfy { $0.cellular == true })
    print("Settings search: unique control targets, upstream titles, live scalar values, width folding and network profiles passed")
  }
}
