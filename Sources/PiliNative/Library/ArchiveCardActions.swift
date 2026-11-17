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
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if pending {
          ProgressView("正在读取总结").frame(maxWidth: .infinity).padding(.top, 60)
        } else if let issue {
          ContentUnavailableView {
            Label("总结未能载入", systemImage: "sparkles")
          } description: { Text(issue) } actions: { Button("重试") { attempt += 1 } }
        } else if model?.summary?.isEmpty != false && model?.outline?.isEmpty != false {
          ContentUnavailableView("这个视频暂无总结", systemImage: "sparkles")
        } else {
          if let s = model?.summary, !s.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Label("AI 总结", systemImage: "sparkles").font(.footnote.weight(.semibold)).foregroundStyle(.tint)
              Text(s).font(.subheadline).lineSpacing(3).textSelection(.enabled)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          }
          ForEach(Array((model?.outline ?? []).enumerated()), id: \.offset) { _, section in
            VStack(alignment: .leading, spacing: 10) {
              Text(section.title ?? "要点").font(.subheadline.weight(.semibold))
              ForEach(Array((section.part_outline ?? []).enumerated()), id: \.offset) { _, p in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                  if let t = p.timestamp, t >= 0 {
                    Text(clockText(Double(t))).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                  }
                  Text(p.content ?? "").font(.subheadline).textSelection(.enabled)
                }
              }
            }
          }
          Text("内容由 AI 生成，仅供参考").font(.caption2).foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
    }
    .navigationTitle("AI 视频总结").navigationBarTitleDisplayMode(.inline).task(id: "\(reader):\(attempt)") {
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
