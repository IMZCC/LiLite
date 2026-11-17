import SwiftUI

struct DynamicEntityInput: View {
  @Binding var draft: ReplyDraft
  @Binding var cursor: NSRange?
  let uid: String, allowVote: Bool
  var suggested: DynamicDraftFile.Tag? = nil
  @EnvironmentObject private var accounts: AccountContext
  @State private var hint: (NSRange, String)?
  @State private var showingMention = false
  @State private var typedAt: NSRange?
  private var entityRanges: [NSRange] {
    var start = 0
    var ranges = [NSRange]()
    for p in draft.pieces {
      let n = (p.raw as NSString).length
      if p.kind != 1 { ranges.append(.init(location: start, length: n)) }
      start += n
    }
    return ranges
  }
  private var existingVote: VoteRef? {
    guard let p = draft.momentRange(kind: 4)?.1, let id = Int64(p.business) else { return nil }
    return .init(id: id, title: p.raw)
  }
  private var text: Binding<String> {
    Binding(
      get: { draft.text },
      set: { next in
        let change = hint
        draft.change(to: next, hint: change)
        hint = nil
        if let (range, replacement) = change, replacement == "@",
          let valid = Range(NSRange(location: range.location, length: 1), in: next),
          next[valid] == "@"
        {
          typedAt = NSRange(location: range.location, length: 1)
          showingMention = true
        }
      })
  }
  var body: some View {
    EmoteInput(
      text: text, prompt: "动态正文", cursor: $cursor, willEdit: { hint = ($0, $1) },
      insertEmote: { token in
        cursor = draft.replace(cursor, with: token, url: token, kind: 9, addSpace: false)
      }, entityRanges: entityRanges)
    Button("提到用户", systemImage: "at") {
      typedAt = nil
      showingMention = true
    }
    .piliSheet(isPresented: $showingMention) {
      PiliNavigationStack {
        MentionChooser(
          uid: uid,
          suggested: suggested.map { Creator(mid: $0.id, uname: $0.name, face: nil, sign: nil) }
        ) { people in
          insertMentions(people)
        }.toolbar { Button("取消") { showingMention = false } }
      }
    }
    if allowVote {
      NavigationLink(existingVote?.title ?? "添加投票") {
        NewVote(existing: existingVote) { v in
          guard accounts.state.active == uid else { return }
          let original = draft.momentRange(kind: 4)?.0
          cursor = draft.replace(
            original ?? cursor, with: v.title, url: v.title, kind: 4, business: String(v.id),
            addSpace: original == nil)
        }
      }
      if let (range, _) = draft.momentRange(kind: 4) {
        Button("移除投票") { cursor = draft.replace(range, with: "") }
      }
    }
  }
  private func insertMentions(_ people: [Creator]) {
    guard accounts.state.active == uid else { return }
    var position =
      typedAt.flatMap { r in Range(r, in: draft.text).flatMap { draft.text[$0] == "@" ? r : nil } }
      ?? cursor
    var seen = Set<Int64>()
    for p in people where p.mid > 0 && seen.insert(p.mid).inserted {
      let raw = "@" + (p.uname ?? String(p.mid))
      position = draft.replace(position, with: raw, url: raw, kind: 2, business: String(p.mid))
    }
    cursor = position
    typedAt = nil
    showingMention = false
  }
}
