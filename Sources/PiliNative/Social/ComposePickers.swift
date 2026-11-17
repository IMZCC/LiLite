import SwiftUI

struct TopicChooser: View {
  let choose: (TopicLink) -> Void
  @Environment(\.dismiss) var dismiss
  var body: some View {
    TopicDirectory(select: { t in
      choose(t)
      dismiss()
    })
  }
}
extension MomentMentionGroup.User {
  var creator: Creator? {
    guard let mid = uid.flatMap(Int64.init), mid > 0, let name, !name.isEmpty else { return nil }
    return .init(mid: mid, uname: name, face: face, sign: nil)
  }
}
struct MentionChooser: View {
  let uid: String
  var suggested: Creator? = nil
  let choose: ([Creator]) -> Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var term = ""
  @State private var groups = [MomentMentionGroup]()
  @State private var selection = [Creator]()
  @State private var selecting = false
  @State private var loading = false
  @State private var issue: String?
  @State private var attempt = 0
  struct Reply: Decodable { let groups: [MomentMentionGroup]? }
  var body: some View {
    List {
      if loading { ProgressView() }
      if let issue {
        Text(issue)
        Button("重试") { attempt += 1 }
      }
      if term.isEmpty, let p = suggested { Section("原作者") { row(p, nil) } }
      ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
        let valid = (g.items ?? []).filter { $0.creator != nil }
        if !valid.isEmpty {
          Section(g.group_name ?? "用户") {
            ForEach(valid) { item in if let p = item.creator { row(p, item.fans) } }
          }
        }
      }
      if !loading && groups.isEmpty && issue == nil { Text("没有找到用户").foregroundStyle(.secondary) }
    }.navigationTitle("提到用户").searchable(text: $term, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索昵称")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button(selecting ? "完成 (\(selection.count))" : "多选") {
            if selecting {
              if !selection.isEmpty { finish(selection) } else { selecting = false }
            } else {
              selecting = true
            }
          }
        }
      }
      .task(id: "\(uid):\(term):\(attempt)") {
        loading = true
        issue = nil
        do {
          let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
          if !q.isEmpty { try await Task.sleep(nanoseconds: 260_000_000) }
          var f = ["web_location": "333.1365"]
          if !q.isEmpty { f["keyword"] = q }
          let r = try await BiliAPI.shared.read(
            "/x/polymer/web-dynamic/v1/mention/search", f, expectedAccount: uid, as: Reply.self)
          try Task.checkCancellation()
          groups = r.groups ?? []
          loading = false
        } catch {
          if !Task.isCancelled {
            groups = []
            loading = false
            issue = error.localizedDescription
          }
        }
      }
      .onChange(of: accounts.state.active) { _, v in if v != uid { dismiss() } }
  }
  private func row(_ p: Creator, _ fans: Int?) -> some View {
    Button {
      if selecting {
        if let i = selection.firstIndex(where: { $0.mid == p.mid }) {
          selection.remove(at: i)
        } else {
          selection.append(p)
        }
      } else {
        finish([p])
      }
    } label: {
      HStack {
        if let u = p.face.flatMap(GalleryPicture.source) {
          SiteThumbnail(url: u) {
            $0.resizable().scaledToFill()
          } placeholder: {
            Color.clear
          }.frame(width: 34, height: 34).clipShape(Circle())
        }
        VStack(alignment: .leading) {
          Text(p.uname ?? String(p.mid))
          if let fans { Text("\(fans) 粉丝").piliFont(.caption).foregroundStyle(.secondary) }
        }
        Spacer()
        if selecting {
          Image(
            systemName: selection.contains(where: { $0.mid == p.mid })
              ? "checkmark.circle.fill" : "circle")
        }
      }
    }
  }
  private func finish(_ people: [Creator]) {
    guard uid == accounts.state.active else { return }
    choose(people)
    dismiss()
  }
}
