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
    List {
      if loading {
        ProgressView("正在读取总结")
      } else if let error {
        Text(error)
        Button("重试") { attempt += 1 }
      } else {
        if let text = result?.summary, !text.isEmpty {
          Section("摘要") { Text(text).textSelection(.enabled) }
        }
        ForEach(Array((result?.outline ?? []).enumerated()), id: \.offset) { _, section in
          Section(section.title ?? "内容要点") {
            ForEach(Array((section.part_outline ?? []).enumerated()), id: \.offset) { _, p in
              if let t = p.timestamp, t >= 0 {
                Button {
                  jump(Double(t))
                  dismiss()
                } label: {
                  HStack {
                    Text(clockText(Double(t))).monospacedDigit()
                    Text(p.content ?? "跳转至此处")
                  }
                }
              } else if let content = p.content {
                Text(content)
              }
            }
          }
        }
        if (result?.summary ?? "").isEmpty && (result?.outline ?? []).isEmpty {
          Text("这个视频暂无总结").foregroundStyle(.secondary)
        }
      }
    }.modifier(ReplyEdgeDismiss()).navigationTitle("视频总结").task(id: "\(video.bvid):\(cid):\(owner):\(attempt)") {
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
