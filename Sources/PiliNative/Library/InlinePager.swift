import Observation
import SwiftUI

/// Pages of rows that live inside a page's own scroll view (a creator space section under a
/// pinned tab bar), instead of a list with its own scroller. The owner keeps it, so switching
/// sections and coming back keeps what was loaded.
@MainActor @Observable final class InlinePager<Item: Identifiable> where Item.ID: Hashable {
  typealias Fetch = (String?) async throws -> Page<Item>
  private(set) var items: [Item] = []
  private(set) var next: String?
  private(set) var busy = false
  private(set) var loaded = false
  private(set) var failure: String?
  @ObservationIgnored private(set) var key: String?
  @ObservationIgnored private var fetch: Fetch?
  @ObservationIgnored private var task: Task<Void, Never>?

  /// Starts over when `key` changes; otherwise keeps the loaded rows.
  func start(key: String, fetch: @escaping Fetch) {
    guard self.key != key else { return }
    self.fetch = fetch
    self.key = key
    task?.cancel()
    items = []
    next = nil
    loaded = false
    failure = nil
    busy = false
    load(reset: true)
  }
  func reload() { load(reset: true) }
  func more() {
    guard loaded, next != nil, !busy, failure == nil else { return }
    load(reset: false)
  }
  func retry() { load(reset: !loaded) }
  func remove(where match: (Item) -> Bool) { items.removeAll(where: match) }
  private func load(reset: Bool) {
    guard let fetch else { return }
    task?.cancel()
    let cursor = reset ? nil : next
    let key = self.key
    busy = true
    failure = nil
    task = Task { [weak self] in
      do {
        let page = try await fetch(cursor)
        try Task.checkCancellation()
        guard let self, self.key == key else { return }
        let previous = reset ? [] : self.items
        var seen = Set(previous.map(\.id))
        let added = page.items.filter { seen.insert($0.id).inserted }
        self.items = previous + added
        // A page that repeats its cursor or brings nothing new ends the list instead of looping.
        self.next = page.next != cursor && (reset || !added.isEmpty) ? page.next : nil
        self.loaded = true
        self.busy = false
      } catch {
        guard let self, !Task.isCancelled, self.key == key else { return }
        self.failure = error.localizedDescription
        self.busy = false
      }
    }
  }
}

/// Loading, retry, empty and "no more" states under an `InlinePager`'s rows, and the trigger that
/// fetches the next page as the end comes into view.
struct InlinePagerFooter<Item: Identifiable>: View where Item.ID: Hashable {
  let pager: InlinePager<Item>
  var empty = "暂无内容"
  var body: some View {
    Group {
      if let failure = pager.failure {
        VStack(spacing: 10) {
          Text(failure).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Button("重试") { pager.retry() }.piliGlassButton()
        }
        .frame(maxWidth: .infinity).padding(.vertical, pager.items.isEmpty ? 60 : 16)
      } else if pager.busy || !pager.loaded {
        ProgressView().frame(maxWidth: .infinity).padding(.vertical, pager.items.isEmpty ? 60 : 16)
      } else if pager.items.isEmpty {
        ContentUnavailableView(empty, systemImage: "tray").padding(.vertical, 24)
      } else if let next = pager.next {
        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
          .onAppear { pager.more() }.id(next)
      } else {
        Text("没有更多了").font(.footnote).foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity).padding(.vertical, 16)
      }
    }
  }
}
