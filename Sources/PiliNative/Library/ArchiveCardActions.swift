import SwiftUI

struct DiscoveryCardRemoval { let archive: String, creator: Int64? }
private struct ArchiveActionKey: EnvironmentKey {
  static let defaultValue: ((DiscoveryCardRemoval) -> Void)? = nil
}
extension EnvironmentValues {
  var discoveryCardRemoval: ((DiscoveryCardRemoval) -> Void)? {
    get { self[ArchiveActionKey.self] }
    set { self[ArchiveActionKey.self] = newValue }
  }
}
struct CardVideoSummary: View {
  let video: Video, cid: Int64
  @State private var model: VideoSummary?
  @State private var issue: String?
  @State private var pending = true
  @State private var attempt = 0
  @EnvironmentObject private var accounts: AccountContext
  private var reader: String { accounts.state.owner(.role(.heartbeat)) ?? "" }
  var body: some View {
    List {
      if pending {
        ProgressView()
      } else if let issue {
        Text(issue)
        Button("重试") { attempt += 1 }
      } else {
        if let s = model?.summary, !s.isEmpty { Section("摘要") { Text(s).textSelection(.enabled) } }
        ForEach(Array((model?.outline ?? []).enumerated()), id: \.offset) { _, section in
          Section(section.title ?? "要点") {
            ForEach(Array((section.part_outline ?? []).enumerated()), id: \.offset) { _, p in
              HStack {
                if let t = p.timestamp, t >= 0 {
                  Text(clockText(Double(t))).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(p.content ?? "").textSelection(.enabled)
              }
            }
          }
        }
        if model?.summary?.isEmpty != false && model?.outline?.isEmpty != false {
          Text("这个视频暂无总结").foregroundStyle(.secondary)
        }
      }
    }.navigationTitle("视频总结").task(id: "\(reader):\(attempt)") {
      model = nil
      issue = nil
      pending = true
      do {
        struct Result: Decodable { let code: Int, model_result: VideoSummary? }
        var q = ["bvid": video.bvid, "cid": String(cid)]
        q["up_mid"] = video.owner?.mid.map(String.init)
        let api = BiliAPI.shared
        let r = try await api.read(
          "/x/web-interface/view/conclusion/get", try await api.sign(q), expectedAccount: reader,
          as: Result.self)
        try Task.checkCancellation()
        guard r.code == 0 || r.code == 1 else { throw ServiceError("视频总结暂不可用（\(r.code)）") }
        model = r.model_result
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
      if !Task.isCancelled { pending = false }
    }
  }
}
