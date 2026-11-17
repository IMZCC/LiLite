import SwiftUI

struct DynamicPortal: Decodable {
  struct Person: Decodable, Identifiable {
    let mid: Int64, uname: String?, face: String?
    var has_update: Bool?
    init(mid: Int64, uname: String?, face: String? = nil) {
      self.mid = mid
      self.uname = uname
      self.face = face
    }
    var id: Int64 { mid }
    enum Keys: String, CodingKey { case mid, uname, face, has_update }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      mid = try c.decode(ServiceID.self, forKey: .mid).number ?? 0
      face = try c.decodeIfPresent(String.self, forKey: .face)
      uname = try c.decodeIfPresent(String.self, forKey: .uname)
      has_update =
        (try? c.decode(Bool.self, forKey: .has_update))
        ?? (try? c.decode(Int.self, forKey: .has_update)).map { $0 != 0 }
    }
  }
  struct Live: Decodable {
    struct Room: Decodable, Identifiable {
      let mid: Int64?, uname: String?, title: String?, face: String?, room_id: Int64?
      var id: Int64 { room_id ?? mid ?? 0 }
      enum Keys: String, CodingKey { case mid, uname, title, face, room_id }
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        mid = try? c.decode(ServiceID.self, forKey: .mid).number
        room_id = try? c.decode(ServiceID.self, forKey: .room_id).number
        uname = try c.decodeIfPresent(String.self, forKey: .uname)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        face = try? c.decode(String.self, forKey: .face)
      }
    }
    let count: ServiceID?, items: [Room]?
  }
  struct Users: Decodable { let items: [Person]?, has_more: Bool?, offset: String? }
  let up_list: Users?, live_users: Live?
}
struct CommunityFilterPanel: View {
  @AppStorage("social.upPanelPosition") private var position = FeedPanelPosition.leftFixed.rawValue
  @AppStorage("social.waterfall") private var waterfall: Bool?
  @AppStorage("layout.horizontal") private var horizontal =
    UIDevice.current.userInterfaceIdiom == .pad
  @AppStorage(FeedScope.setting) private var defaultFeed = 0
  @AppStorage("social.dispute") private var showDispute = false
  @AppStorage("social.interaction") private var showInteraction = true
  @AppStorage("social.actionBar") private var actionBar = true
  @AppStorage("social.allFollowed") private var allFollowed = false
  @AppStorage("social.expandLive") private var expandLive = false
  @AppStorage("social.verifyPost") private var verifyPost = false
  @AppStorage("social.verifyReply") private var verifyReply = false
  @AppStorage("social.dynamicRegex") private var regex = ""
  @AppStorage("social.hideGoods") private var goods = false
  @State private var draft = ""
  @State private var issue: String?
  var body: some View {
    Form {
      Section("发布后检查公开可见性") {
        Toggle("评论", isOn: $verifyReply).settingAnchor("CommunityFilterPanel/评论")
        Toggle("公开动态和转发", isOn: $verifyPost).settingAnchor("CommunityFilterPanel/公开动态和转发")
      }.settingAnchor("CommunityFilterPanel/发布后检查公开可见性")
      Section("动态") {
        Picker("UP 主面板", selection: $position) {
          ForEach(FeedPanelPosition.allCases) { Text($0.label).tag($0.rawValue) }
        }.settingAnchor("CommunityFilterPanel/UP 主面板")
        Toggle("瀑布流布局", isOn: Binding(get: { waterfall ?? horizontal }, set: { waterfall = $0 })).settingAnchor("CommunityFilterPanel/瀑布流布局")
        if waterfall != nil { Button("布局跟随横屏设置") { waterfall = nil }.settingAnchor("CommunityFilterPanel/布局跟随横屏设置") }
        Picker("默认分类", selection: $defaultFeed) {
          ForEach(FeedScope.allCases) { Text($0.label).tag($0.rawValue) }
        }.settingAnchor("CommunityFilterPanel/默认分类")
        Toggle("显示关注的全部 UP 主", isOn: $allFollowed).settingAnchor("CommunityFilterPanel/显示关注的全部 UP 主")
        Toggle("展开正在直播的 UP 主", isOn: $expandLive).settingAnchor("CommunityFilterPanel/展开正在直播的 UP 主")
        Toggle("显示互动摘要", isOn: $showInteraction).settingAnchor("CommunityFilterPanel/显示互动摘要")
        Toggle("显示争议信息", isOn: $showDispute).settingAnchor("CommunityFilterPanel/显示争议信息")
        Toggle("显示动态详情操作栏", isOn: $actionBar).settingAnchor("CommunityFilterPanel/显示动态详情操作栏")
        Toggle("隐藏带货动态", isOn: $goods).settingAnchor("CommunityFilterPanel/隐藏带货动态")
      }.settingAnchor("CommunityFilterPanel/动态")
      Section("屏蔽动态关键词（正则表达式）") {
        TextField("输入表达式", text: $draft).settingAnchor("CommunityFilterPanel/输入表达式").textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("保存") {
          do {
            if !draft.isEmpty {
              _ = try NSRegularExpression(pattern: draft, options: .caseInsensitive)
            }
            regex = draft
            issue = nil
          } catch { issue = "表达式无效" }
        }
        if let issue { Text(issue).foregroundStyle(.secondary) }
      }.settingAnchor("CommunityFilterPanel/屏蔽动态关键词（正则表达式）")
    }.navigationTitle("动态筛选").onAppear { draft = regex }
  }
}
