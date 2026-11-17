import SwiftUI

struct UpstreamRelease: Codable, Identifiable {
  let tag_name: String, created_at: Date, body: String?, draft: Bool?, prerelease: Bool?
  var id: String { tag_name }
  /// This app's own repository (轻哩 LiLite): source, releases and issue reports.
  static let lilite = URL(string: "https://github.com/liuliuya2333/LiLite")!
  static let project = lilite
  /// The installed version; a release tagged above it is offered as an update.
  static let pinned = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
  static let pinnedDate = Date(timeIntervalSince1970: 1793691286)
  var page: URL { Self.project.appendingPathComponent("releases/tag").appendingPathComponent(tag_name) }
  var newer: Bool {
    guard tag_name != Self.pinned else { return false }
    func parts(_ s: String) -> [Int]? {
      let number = s.hasPrefix("v") ? String(s.dropFirst()) : s
      let fields = number.components(separatedBy: ".")
      guard fields.count <= 6, fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0) != nil }) else { return nil }
      return fields.compactMap(Int.init)
    }
    if let l = parts(tag_name), let r = parts(Self.pinned) {
      for index in 0..<max(l.count, r.count) {
        let a = l.indices.contains(index) ? l[index] : 0, b = r.indices.contains(index) ? r[index] : 0
        if a != b { return a > b }
      }
      return false
    }
    return created_at > Self.pinnedDate
  }
}
@MainActor final class ReleaseUpdates: ObservableObject {
  static let shared = ReleaseUpdates()
  static let enabledKey = "updates.automatic"
  @Published private(set) var latest: UpstreamRelease?
  @Published private(set) var checking = false
  @Published private(set) var issue: String?
  @Published var offer: UpstreamRelease?
  private var attempted = false
  private let cache = "updates.lastRelease.lilite"
  private init() {
    let key = cache
    Task {
      let saved = await Task.detached(priority: .utility) {
        guard let data = UserDefaults.standard.data(forKey: key), data.count <= 512_000 else { return nil as UpstreamRelease? }
        return try? JSONDecoder().decode(UpstreamRelease.self, from: data)
      }.value
      if latest == nil { latest = saved }
    }
  }
  func check(automatic: Bool) async {
    guard !checking, !automatic || !attempted else { return }
    attempted = true; checking = true; issue = nil
    defer { checking = false }
    do {
      let found = try await Self.fetchRelease(cache: cache)
      try Task.checkCancellation()
      latest = found
      if automatic, found.newer, (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true),
        UserDefaults.standard.string(forKey: "updates.notified") != found.tag_name {
        offer = found
        UserDefaults.standard.set(found.tag_name, forKey: "updates.notified")
      }
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
  // AsyncBytes iteration can resume thousands of times; none of it belongs on MainActor.
  nonisolated private static func fetchRelease(cache: String) async throws -> UpstreamRelease {
      let endpoint = URL(string: "https://api.github.com/repos/liuliuya2333/LiLite/releases?per_page=1")!
      var req = URLRequest(url: endpoint, timeoutInterval: 15)
      req.setValue("LiLite", forHTTPHeaderField: "User-Agent")
      req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      let config = URLSessionConfiguration.ephemeral
      config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
      let session = URLSession(configuration: config, delegate: CertificateSessionDelegate(), delegateQueue: nil)
      defer { session.finishTasksAndInvalidate() }
      let (stream, response) = try await session.bytes(for: req)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "api.github.com",
        http.expectedContentLength <= 512_000 else { throw ServiceError("暂时无法检查更新") }
      var bytes = Data()
      for try await byte in stream {
        guard bytes.count < 512_000 else { throw ServiceError("更新信息过长") }
        bytes.append(byte)
      }
      let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
      guard let found = try decoder.decode([UpstreamRelease].self, from: bytes).first,
        found.draft != true, !found.tag_name.isEmpty, found.tag_name.utf8.count <= 100,
        !found.tag_name.contains("/"), !found.tag_name.contains("..") else { throw ServiceError("暂时还没有发布版本") }
      try Task.checkCancellation()
      UserDefaults.standard.set(try JSONEncoder().encode(found), forKey: cache)
      return found
  }
}
struct VersionPanel: View {
  @ObservedObject private var updates = ReleaseUpdates.shared
  @AppStorage(ReleaseUpdates.enabledKey) private var automatic = true
  var body: some View {
    Form {
      Section {
        LabeledContent("轻哩 LiLite", value: UpstreamRelease.pinned)
      }
      Section {
        Toggle("提醒新版本", isOn: $automatic).settingAnchor("VersionPanel/提醒新版本")
        Button { Task { await updates.check(automatic: false) } } label: {
          HStack {
            Text("检查更新")
            Spacer()
            if updates.checking { ProgressView().transition(.opacity) }
          }
        }.settingAnchor("VersionPanel/检查更新").disabled(updates.checking)
      } footer: {
        if let issue = updates.issue { Text(issue) } else { Text("打开后，轻哩发布新版本时会提醒你。") }
      }
      if let release = updates.latest {
        Section(release.newer ? "有新版本" : "最新发布") {
          HStack {
            Text("轻哩 " + release.tag_name).font(.headline)
            Spacer()
            if release.newer {
              Text("新版本").font(.caption.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3).background(.red, in: Capsule())
            }
          }
          if let notes = release.body, !notes.isEmpty {
            Text(verbatim: notes).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
          }
          Link("在 GitHub 查看版本", destination: release.page)
        }
        .transition(.opacity)
      }
      Section {
        Link("查看全部变更", destination: UpstreamRelease.project.appendingPathComponent("commits/main"))
      }
    }
    .animation(.snappy(duration: 0.25), value: updates.checking)
    .navigationTitle("版本与更新")
  }
}
struct UpdatePrompt: ViewModifier {
  @ObservedObject private var updates = ReleaseUpdates.shared
  @AppStorage(ReleaseUpdates.enabledKey) private var enabled = true
  @Environment(\.openURL) private var openURL
  func body(content: Content) -> some View {
    content.task(id: enabled) { if enabled { await updates.check(automatic: true) } }
      .alert("轻哩有新版本", isPresented: Binding(get: { updates.offer != nil }, set: { if !$0 { updates.offer = nil } }), presenting: updates.offer) { item in
        Button("查看版本") { openURL(item.page) }
        Button("关闭自动提醒") { enabled = false }
        Button("稍后", role: .cancel) {}
      } message: { item in Text(item.tag_name + "\n" + String((item.body ?? "").prefix(400))) }
  }
}
