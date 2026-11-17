import SwiftUI

struct NotebookLocalShelf: View {
  let owner: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var entries = [NotebookDisk.Saved]()
  @State private var pending: NotebookDisk.Saved?
  @State private var expected: NotebookDraft?
  @State private var issue: String?
  var body: some View {
    List {
      if let issue { Text(issue).foregroundStyle(.secondary) }
      if entries.isEmpty { ContentUnavailableView("没有本机草稿", systemImage: "note.text") }
      ForEach(entries) { row in
        NavigationLink {
          NativeNotebook(
            oid: row.oid, owner: owner, suppliedTitle: row.title, requested: row.note,
            startLocal: true)
        } label: {
          VStack(alignment: .leading) {
            Text(row.title)
            Text(row.time.formatted()).font(.caption).foregroundStyle(.secondary)
          }
        }
        .swipeActions {
          Button("删除", role: .destructive) {
            do {
              let disk = try NotebookDisk(owner: owner, oid: row.oid, note: row.note)
              expected = try disk.load()
              pending = row
            } catch { issue = error.localizedDescription }
          }
        }
      }
    }.navigationTitle("本机草稿").onAppear { read() }.onChange(of: accounts.state.active) { _, _ in
      read()
    }
    .confirmationDialog(
      "删除这份本机草稿？", isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } }),
      presenting: pending
    ) { row in
      Button("删除", role: .destructive) {
        guard accounts.state.active == owner else { return }
        do {
          try NotebookDisk(owner: owner, oid: row.oid, note: row.note).discard(expected)
          read()
        } catch { issue = error.localizedDescription }
      }
    }
  }
  private func read() {
    guard owner == accounts.state.active else {
      entries = []
      return
    }
    do {
      entries = try NotebookDisk.saved(owner: owner)
      issue = nil
    } catch { issue = error.localizedDescription }
  }
}
