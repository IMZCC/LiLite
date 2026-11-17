import SwiftUI

@MainActor final class CloudWatchProgress {
  private static let sessions = NSHashTable<CloudWatchProgress>.weakObjects()
  init() { Self.sessions.add(self) }
  static func flushPending() async {
    let writes = sessions.allObjects.compactMap(\.writer)
    for write in writes { await write.value }
  }
  private var account: String?
  private var fields: [String: String] = [:]
  private var allowed = false
  private var last: Int?
  private var stamp = UUID()
  private var status: Task<Void, Never>?
  private var writer: Task<Void, Never>?
  func begin(uid: String?, fields: [String: String]) {
    stamp = UUID()
    let gen = stamp
    status?.cancel()
    account = uid
    self.fields = fields
    allowed = false
    last = nil
    guard let uid, UserDefaults.standard.object(forKey: "history.sync") as? Bool != false else {
      return
    }
    status = Task {
      let paused = try? await BiliAPI.shared.read(
        "/x/v2/history/shadow", ["jsonp": "jsonp"], expectedAccount: uid, as: Bool.self)
      if stamp == gen, !Task.isCancelled { allowed = paused == false }
    }
  }
  func record(_ seconds: Double, duration: Double, final: Bool = false) {
    guard allowed, let account,
      UserDefaults.standard.object(forKey: "history.sync") as? Bool != false, seconds.isFinite,
      seconds > 0, seconds < Double(Int.max)
    else { return }
    let t = Int(seconds)
    let finished = duration > 0 && seconds >= duration - 0.6
    let value = finished ? -1 : t
    guard last != value, final || finished || (last.map { abs($0 - value) >= 15 } ?? true) else {
      return
    }
    last = value
    var f = fields
    f["played_time"] = "\(value)"
    let previous = writer
    writer = Task {
      await previous?.value
      try? await BiliAPI.shared.submit(
        "/x/click-interface/web/heartbeat", f, expectedAccount: account)
    }
  }
  func end(_ time: Double, duration: Double) {
    record(time, duration: duration, final: true)
    status?.cancel()
    stamp = UUID()
    allowed = false
    last = nil
    account = nil
  }
}
struct HistorySettings: View {
  let uid: String
  @AppStorage("history.sync") private var sync = true
  @State private var paused: Bool?
  @State private var issue: String?
  @State private var busy = false
  @State private var clear = false
  @State private var retry = 0
  var body: some View {
    Form {
      Section {
        SettingToggle(title: "在此设备同步观看进度", symbol: "arrow.triangle.2.circlepath", color: .blue, isOn: $sync)
      } footer: {
        Text("关闭后播放进度只保存在本机")
      }
      Section {
        if let paused {
          SettingToggle(
            title: "暂停账号历史记录", symbol: "pause.circle", color: .orange,
            isOn: Binding(get: { paused }, set: { value in Task { await update(value) } })
          ).disabled(busy)
        } else if issue == nil {
          ProgressView().frame(maxWidth: .infinity)
        }
        if let issue {
          Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
          Button("重试") { retry += 1 }
        }
      } header: {
        Text("观看历史 · UID " + uid)
      } footer: {
        Text("暂停后，在任何设备观看的视频都不会记入该账号的历史")
      }
      Section {
        Button("清空账号观看历史", role: .destructive) { clear = true }.disabled(busy || paused == nil)
      }
    }.navigationTitle("观看历史设置").navigationBarTitleDisplayMode(.inline).task(id: retry) {
      do {
        paused = try await BiliAPI.shared.read(
          "/x/v2/history/shadow", ["jsonp": "jsonp"], expectedAccount: uid, as: Bool.self)
        issue = nil
      } catch { issue = error.localizedDescription }
    }
    .confirmationDialog("清空该账号的全部观看历史？", isPresented: $clear) {
      Button("清空全部历史", role: .destructive) {
        Task {
          guard !busy else { return }
          busy = true
          defer { busy = false }
          do {
            try await BiliAPI.shared.submit(
              "/x/v2/history/clear", ["jsonp": "jsonp"], expectedAccount: uid)
            issue = nil
          } catch { issue = error.localizedDescription }
        }
      }
    }
  }
  func update(_ value: Bool) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await BiliAPI.shared.submit(
        "/x/v2/history/shadow/set", ["switch": value ? "true" : "false", "jsonp": "jsonp"],
        expectedAccount: uid)
      paused = value
      issue = nil
    } catch { issue = error.localizedDescription }
  }
}
