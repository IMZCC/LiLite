import PiliWire
import SwiftUI

extension BiliAPI {
  func unreadMessages(_ uid: String, mask: Int) async throws -> Int64 {
    let direct: [String: Int64]
    let feed: [String: Int64]
    if mask & 1 != 0 {
      direct = try await read(
        "/session_svr/v1/session_svr/single_unread",
        ["build": "0", "mobi_app": "web", "unread_type": "0", "web_location": "333.1365"],
        host: "api.vc.bilibili.com", expectedAccount: uid, as: IMUnreadFields.self
      ).values
    } else {
      direct = [:]
    }
    if mask & 30 != 0 {
      feed = try await read(
        "/x/msgfeed/unread", ["build": "0", "mobi_app": "web"], expectedAccount: uid,
        as: IMUnreadFields.self
      ).values
    } else {
      feed = [:]
    }
    return UnreadTotals.messages(mask, direct, feed)
  }
  func unreadDynamics(_ uid: String) async throws -> Int64? {
    guard let owner = try await AccountJar.shared.current(), owner.id == uid else {
      throw ServiceError("账号已切换")
    }
    if owner.mobileToken?.isEmpty == false {
      return try await socialService(for: uid).unseenCount()
    }
    guard let baseline = UserDefaults.standard.string(forKey: "social.feed.baseline." + uid),
      !baseline.isEmpty
    else { return nil }
    struct Update: Decodable { let update_num: Int64 }
    return try await read(
      "/x/polymer/web-dynamic/v1/feed/all/update", ["type": "all", "update_baseline": baseline],
      expectedAccount: uid, as: Update.self
    ).update_num
  }
}
@MainActor final class UnreadIndicators: ObservableObject {
  @Published private(set) var messages: Int64 = 0
  @Published private(set) var dynamics: Int64 = 0
  private var owner: String?, generation = UUID()
  func count(for uid: String?, messages wantMessages: Bool) -> Int64 {
    guard let uid, uid == owner else { return 0 }
    return wantMessages ? messages : dynamics
  }
  func clearDynamics() { if dynamics != 0 { dynamics = 0 } }
  func track(
    uid: String?, active: Bool, showMessages: Bool, showDynamics: Bool, mask: Int, periodic: Bool,
    minutes: Int
  ) async {
    let stamp = UUID()
    generation = stamp
    if owner != uid {
      owner = uid
      if messages != 0 { messages = 0 }
      if dynamics != 0 { dynamics = 0 }
    }
    if !showMessages && messages != 0 { messages = 0 }
    if !showDynamics && dynamics != 0 { dynamics = 0 }
    guard let uid, active, showMessages || showDynamics else { return }
    var first = true
    repeat {
      let readMessages = first && showMessages
      await withTaskGroup(of: (Bool, Int64?).self) { group in
        if readMessages {
          group.addTask { (true, try? await BiliAPI.shared.unreadMessages(uid, mask: mask)) }
        }
        if showDynamics { group.addTask { (false, try? await BiliAPI.shared.unreadDynamics(uid)) } }
        for await (isMessage, number) in group {
          guard !Task.isCancelled, generation == stamp, let number else { continue }
          let value = max(0, number)
          if isMessage { if messages != value { messages = value } }
          else if dynamics != value { dynamics = value }
        }
      }
      first = false
      guard showDynamics && periodic && active && !Task.isCancelled && generation == stamp else {
        return
      }
      do { try await Task.sleep(for: .seconds(min(1440, max(1, minutes)) * 60)) } catch { return }
    } while !Task.isCancelled && generation == stamp
  }
}
struct BadgePreferences: View {
  @AppStorage("badge.dynamicMode") private var dyn = 2
  @AppStorage("badge.messageMode") private var msg = 2
  @AppStorage("badge.messageMask") private var mask = UnreadTotals.allMask
  @AppStorage("badge.periodic") private var check = true
  @AppStorage("badge.minutes") private var minutes = 5
  var body: some View {
    Form {
      Section("角标") {
        picker("动态", value: $dyn)
        picker("消息", value: $msg)
      }.settingAnchor("BadgePreferences/角标")
      Section("计入消息未读数") {
        ForEach(UnreadKind.allCases) { kind in
          Toggle(
            kind.label,
            isOn: Binding(
              get: { mask & kind.bit != 0 },
              set: { if $0 { mask |= kind.bit } else { mask &= ~kind.bit } }))
        }
      }.settingAnchor("BadgePreferences/计入消息未读数")
      Section("动态更新") {
        Toggle("定时检查更新", isOn: $check).settingAnchor("BadgePreferences/定时检查更新")
        if check {
          SettingStepper(title: "检查间隔", value: $minutes.asDouble, range: 1...1440) { "每 \(Int($0)) 分钟" }
        }
      }.settingAnchor("BadgePreferences/动态更新")
    }.navigationTitle("未读提醒")
  }
  private func picker(_ title: String, value: Binding<Int>) -> some View {
    Picker(title, selection: value) {
      Text("隐藏").tag(0)
      Text("红点").tag(1)
      Text("数字").tag(2)
    }
  }
}
