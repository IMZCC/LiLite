import SwiftUI

struct ConversationTimeline<Row: View>: View {
  let revision: Int
  let fetch: (String?) async throws -> Page<DirectMessage>
  @ViewBuilder let row: (DirectMessage) -> Row
  @State private var window = ChatWindow<DirectMessage>()
  @State private var stateID = UUID()
  @State private var busy = false
  @State private var started = false
  @State private var error: String?
  @State private var failedOlder = false
  @State private var allowLoad = false
  @State private var request: Task<Void, Never>?
  @State private var requestID: UUID?
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if window.next != nil {
            Button("更早的消息") { startLoad(older: true, proxy: proxy) }.disabled(busy).frame(
              maxWidth: .infinity)
          }
          if let error {
            HStack {
              Text(error).foregroundStyle(.secondary)
              Button("重试") { startLoad(older: failedOlder, proxy: proxy) }
            }
          }
          if busy { ProgressView().frame(maxWidth: .infinity) }
          if !busy && started && window.rows.isEmpty && error == nil {
            ContentUnavailableView("暂无私信", systemImage: "bubble.left.and.bubble.right")
          }
          ForEach(window.rows) { msg in
            row(msg).frame(maxWidth: .infinity, alignment: .leading).id(msg.id).onAppear {
              if allowLoad && msg.id == window.rows.first?.id && window.next != nil && !busy
                && error == nil
              {
                allowLoad = false
                startLoad(older: true, proxy: proxy)
              }
            }
          }
        }.padding()
      }.defaultScrollAnchor(.bottom).simultaneousGesture(
        DragGesture(minimumDistance: 12).onChanged { _ in allowLoad = true }
      )
      .piliRefreshable { cancelRequest(); await load(older: false, proxy: proxy) }
      .toolbar {
        Button {
          startLoad(older: false, proxy: proxy)
        } label: {
          Label("刷新会话", systemImage: "arrow.clockwise")
        }.disabled(busy)
      }
      .task(id: revision) { cancelRequest(); await load(older: false, proxy: proxy) }
      .onDisappear {
        cancelRequest()
        stateID = UUID()
        busy = false
      }
    }
  }
  @MainActor private func cancelRequest() {
    request?.cancel()
    request = nil
    requestID = nil
  }
  @MainActor private func startLoad(older: Bool, proxy: ScrollViewProxy) {
    guard !older || !busy else { return }
    cancelRequest()
    let id = UUID()
    requestID = id
    request = Task {
      await load(older: older, proxy: proxy)
      if requestID == id { request = nil; requestID = nil }
    }
  }
  @MainActor private func load(older: Bool, proxy: ScrollViewProxy) async {
    guard !Task.isCancelled else { return }
    let before = older ? window.next : nil
    if older && (busy || before == nil) { return }
    let stamp = UUID()
    stateID = stamp
    busy = true
    error = nil
    let top = window.rows.first?.id
    defer {
      if stateID == stamp {
        busy = false
        started = true
      }
    }
    do {
      let page = try await fetch(before)
      try Task.checkCancellation()
      guard stateID == stamp else { return }
      window.receive(page.items, next: page.next, older: older)
      allowLoad = false
      let target = older ? top : window.rows.last?.id
      if let target {
        await Task.yield()
        guard stateID == stamp, !Task.isCancelled else { return }
        proxy.scrollTo(target, anchor: older ? .top : .bottom)
      }
    } catch {
      if !Task.isCancelled && stateID == stamp {
        self.error = error.localizedDescription
        failedOlder = older
      }
    }
  }
}
