import Combine
import Foundation
import PiliWire

@MainActor final class LiveChat: ObservableObject {
  @Published var lines: [LiveLine] = []
  @Published var status: String?
  private var socket: URLSessionWebSocketTask?
  private var generation = UUID()
  private var heartbeat: Task<Void, Never>?
  private var session: URLSession?
  @Published private(set) var watched: String?
  @Published private(set) var roomTitle: String?
  @Published private(set) var online: Int64?
  @Published private(set) var popularity: UInt32?
  @Published private(set) var paid = SuperChatLedger()
  @Published private(set) var paidIssue: String?
  private var paidSeed: Task<Void, Never>?, overlayExpiry: Task<Void, Never>?
  private var room: Int64?, reader: String?, inFullScreen = false
  private var display: SuperChatDisplay = .current
  func presentation(_ full: Bool) {
    inFullScreen = full
    if !full {
      overlayExpiry?.cancel()
      paid.dismissOverlay()
    }
  }
  func configurePaid(_ mode: SuperChatDisplay) {
    let old = display
    display = mode
    if old == .current { paid.trimExpired(at: Int64(Date().timeIntervalSince1970)) }
    if mode == .hidden {
      paidSeed?.cancel()
      paid = SuperChatLedger()
      paidIssue = nil
      lines.removeAll { $0.paidID != nil }
    } else if old == .hidden {
      loadPaid()
    }
  }
  func loadPaid() {
    paidSeed?.cancel()
    guard display != .hidden, let room else { return }
    let gen = generation
    paidSeed = Task {
      do {
        let snapshot = try await BiliAPI.shared.read(
          "/av/v1/SuperChat/getMessageList", ["room_id": String(room)],
          host: "api.live.bilibili.com", as: SuperChatSnapshot.self)
        guard !Task.isCancelled, gen == generation else { return }
        paid.seed(snapshot.items)
        if display == .current { paid.trimExpired(at: Int64(Date().timeIntervalSince1970)) }
        paidIssue = nil
      } catch {
        if !Task.isCancelled && gen == generation { paidIssue = error.localizedDescription }
      }
    }
  }
  func connect(_ id: Int64, reader accountID: String?) async {
    disconnect()
    generation = UUID()
    if room != id || reader != accountID {
      paid = SuperChatLedger()
      paidIssue = nil
    }
    room = id
    reader = accountID
    loadPaid()
    let gen = generation
    lines = []
    status = nil
    async let configRequest = BiliAPI.shared.chatConfig(id, reader: accountID)
    if let seed = try? await BiliAPI.shared.recentChat(id, reader: accountID), gen == generation {
      lines = seed
    }
    guard gen == generation, !Task.isCancelled else { return }
    popularity = nil; watched = nil; online = nil; roomTitle = nil
    do {
      let config = try await configRequest
      let account = try await AccountJar.shared.current(.role(.heartbeat))
      guard account?.id == accountID, gen == generation, !Task.isCancelled else { return }
      var seen = Set<URL>()
      let urls = config.host_list.compactMap { host -> URL? in
        let name = host.host.lowercased()
        guard name.hasSuffix(".bilibili.com") || name.hasSuffix(".bilivideo.com"),
          (1...65535).contains(host.wss_port)
        else { return nil }
        var c = URLComponents()
        c.scheme = "wss"
        c.host = name
        c.port = host.wss_port
        c.path = "/sub"
        return c.url.flatMap { seen.insert($0).inserted ? $0 : nil }
      }
      guard !urls.isEmpty else { throw ServiceError("未取得弹幕服务器") }
      var lastError: Error = ServiceError("未连接到弹幕服务器")
      for endpoint in urls {
        guard gen == generation, !Task.isCancelled else { return }
        do {
          try await receive(
            endpoint, id: id, user: account?.id, token: config.token, generation: gen)
          return
        } catch let w as WireError {
          if case .remote = w { throw w }
          lastError = w
        } catch { lastError = error }
        guard gen == generation, !Task.isCancelled else { return }
        disconnect()
      }
      throw lastError
    } catch {
      if gen == generation && !Task.isCancelled {
        status = error.localizedDescription
        disconnect()
      }
    }
  }
  private func receive(_ url: URL, id: Int64, user: String?, token: String, generation gen: UUID)
    async throws
  {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpShouldSetCookies = false
    cfg.httpCookieStorage = nil
    cfg.timeoutIntervalForRequest = 15
    let s = URLSession(configuration: cfg, delegate: CertificateSessionDelegate(), delegateQueue: nil)
    session = s
    var r = URLRequest(url: url)
    r.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
    let ws = s.webSocketTask(with: r)
    ws.maximumMessageSize = 4 * 1024 * 1024
    socket = ws
    ws.resume()
    let login: [String: Any] = [
      "uid": Int64(user ?? "") ?? 0, "roomid": id, "protover": 3, "platform": "web", "type": 2,
      "key": token,
    ]
    try await ws.send(
      .data(try LivePackets.encode(7, data: JSONSerialization.data(withJSONObject: login))))
    while gen == generation && !Task.isCancelled {
      let message = try await ws.receive()
      guard gen == generation else { return }
      if case .data(let data) = message {
        let decoding = Task.detached(priority: .userInitiated) {
          try LiveChatBatch.decode(data, room: id)
        }
        let frames = try await withTaskCancellationHandler {
          try await decoding.value
        } onCancel: { decoding.cancel() }
        guard gen == generation, !Task.isCancelled else { return }
        var nextLines = lines
        var linesChanged = false
        for frame in frames {
          switch frame {
          case .authenticated:
            guard heartbeat == nil else { continue }
            status = nil
            heartbeat = Task {
              var seq: UInt32 = 1
              while !Task.isCancelled {
                do {
                  try await Task.sleep(for: .seconds(30))
                  try Task.checkCancellation()
                  seq &+= 1
                  try await ws.send(.data(try LivePackets.encode(2, data: Data(), sequence: seq)))
                } catch { return }
              }
            }
          case .popularity(let n): if popularity != n { popularity = n }
          case .update(let update):
            switch update {
            case .title(let value): if roomTitle != value { roomTitle = value }
            case .watched(let value): if watched != value { watched = value }
            case .online(let value): if online != value { online = value }
            }
          case .line, .paid, .ignored:
            if appendEvent(frame, to: &nextLines) { linesChanged = true }
          }
        }
        if linesChanged { lines = nextLines }
      }
    }
  }
  private func appendEvent(_ event: LiveChatEvent, to lines: inout [LiveLine]) -> Bool {
    var changed = false
    if case .line(let line) = event {
      if line.sourceID == nil
        || !lines.suffix(250).contains(where: { $0.sourceID == line.sourceID && $0.uid == line.uid }
        )
      {
        lines.append(line)
        changed = true
      }
    } else if display != .hidden, case .paid(let event) = event {
      let show =
        inFullScreen
        && UserDefaults.standard.object(forKey: "live.paidFullscreen") as? Bool != false
        && UserDefaults.standard.object(forKey: "live.showChat") as? Bool != false
      let now = Int64(Date().timeIntervalSince1970)
      if display == .current { paid.trimExpired(at: now) }
      let oldID = paid.featured?.id
      if let m = paid.accept(event, now: now, fullscreen: show) {
        lines.append(
          .init(name: m.name, text: m.text, highlight: true, uid: m.uid, paidID: m.id, room: room))
        changed = true
      }
      if oldID != paid.featured?.id {
        overlayExpiry?.cancel()
        if let cutoff = paid.featured?.until {
          overlayExpiry = Task {
            try? await Task.sleep(
              for: .seconds(max(0, Double(cutoff) - Date().timeIntervalSince1970)))
            if !Task.isCancelled { paid.dismissOverlay() }
          }
        }
      }
      if case .remove(let ids) = event {
        let gone = Set(ids)
        let count = lines.count
        lines.removeAll { $0.paidID.map(gone.contains) == true }
        changed = changed || count != lines.count
      }
    }
    if lines.count > 250 {
      lines.removeFirst(lines.count - 250)
      changed = true
    }
    return changed
  }
  func close() {
    watched = nil; online = nil; roomTitle = nil; popularity = nil
    overlayExpiry?.cancel()
    overlayExpiry = nil
    paidSeed?.cancel()
    paidSeed = nil
    room = nil
    reader = nil
    inFullScreen = false
    paid = SuperChatLedger()
    paidIssue = nil
    generation = UUID()
    disconnect()
  }
  private func disconnect() {
    heartbeat?.cancel()
    heartbeat = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    session?.invalidateAndCancel()
    session = nil
  }
}
