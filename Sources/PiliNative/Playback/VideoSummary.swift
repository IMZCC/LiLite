import SwiftUI

struct VideoSummary: Decodable {
  struct Outline: Decodable {
    struct Point: Decodable { let timestamp: Int?, content: String? }
    let title: String?, part_outline: [Point]?
  }
  let summary: String?, outline: [Outline]?
}
struct VideoSummaryView: View {
  let video: Video, cid: Int64, jump: (Double) -> Void
  @State private var result: VideoSummary?
  @State private var loading = true
  @State private var error: String?
  @State private var attempt = 0
  @EnvironmentObject private var accounts:AccountContext
  private var owner:String{accounts.state.owner(.role(.heartbeat)) ?? ""}
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        if loading {
          ProgressView("正在读取总结").frame(maxWidth: .infinity).padding(.top, 60)
        } else if let error {
          ContentUnavailableView {
            Label("总结未能载入", systemImage: "sparkles")
          } description: { Text(error) } actions: { Button("重试") { attempt += 1 } }
        } else if (result?.summary ?? "").isEmpty && (result?.outline ?? []).isEmpty {
          ContentUnavailableView("这个视频暂无总结", systemImage: "sparkles")
        } else {
          if let text = result?.summary, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              Label("AI 总结", systemImage: "sparkles").font(.footnote.weight(.semibold)).foregroundStyle(.tint)
              Text(text).font(.subheadline).lineSpacing(3).textSelection(.enabled)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
          }
          ForEach(Array((result?.outline ?? []).enumerated()), id: \.offset) { _, section in
            VStack(alignment: .leading, spacing: 10) {
              Text(section.title ?? "内容要点").font(.subheadline.weight(.semibold))
              ForEach(Array((section.part_outline ?? []).enumerated()), id: \.offset) { _, p in
                if let t = p.timestamp, t >= 0 {
                  Button {
                    jump(Double(t))
                    dismiss()
                  } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                      Text(clockText(Double(t))).font(.footnote.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tint)
                      Text(p.content ?? "跳转至此处").font(.subheadline).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    }
                  }
                  .buttonStyle(.plain)
                } else if let content = p.content {
                  Text(content).font(.subheadline)
                }
              }
            }
          }
          Text("内容由 AI 生成，仅供参考").font(.caption2).foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
    }
    .modifier(ReplyEdgeDismiss()).navigationTitle("AI 视频总结").navigationBarTitleDisplayMode(.inline)
    .task(id: "\(video.bvid):\(cid):\(owner):\(attempt)") {
      loading = true
      error = nil
      result = nil
      do {
        struct Response: Decodable { let code: Int, model_result: VideoSummary? }
        var q = ["bvid": video.bvid, "cid": String(cid)]
        if let mid = video.owner?.mid { q["up_mid"] = String(mid) }
        let api = BiliAPI.shared
        let r = try await api.read(
          "/x/web-interface/view/conclusion/get", try await api.sign(q), expectedAccount:owner, as: Response.self)
        try Task.checkCancellation()
        if r.code == 0 {
          result = r.model_result
        } else if r.code != 1 {
          throw ServiceError("视频总结暂不可用（\(r.code)）")
        }
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
      if !Task.isCancelled { loading = false }
    }
  }
}
