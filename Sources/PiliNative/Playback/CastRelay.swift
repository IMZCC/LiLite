import Darwin
import Foundation
import Network

// Cancellation may race listener construction, its callbacks or the local network permission prompt.
private final class CastPortGate: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<UInt16, Error>?, continuation: CheckedContinuation<UInt16, Error>?
  func install(_ c: CheckedContinuation<UInt16, Error>) {
    lock.lock()
    if let result {
      lock.unlock()
      c.resume(with: result)
    } else {
      continuation = c
      lock.unlock()
    }
  }
  @discardableResult func finish(_ r: Result<UInt16, Error>) -> Bool {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      return false
    }
    result = r
    let c = continuation
    continuation = nil
    lock.unlock()
    c?.resume(with: r)
    return true
  }
}
/// One user-selected movie; receivers can request byte ranges but cannot choose an upstream URL.
final class CastRelay: @unchecked Sendable {
  private let queue = DispatchQueue(label: "piliplus.cast.relay")
  private let media: CastMediaSource
  private var listener: NWListener?, closed = false,
    connections: [ObjectIdentifier: NWConnection] = [:]
  private let token = UUID().uuidString
  private var length: Int64 = 0
  private var file = CastVideoFile.mp4, target = "",
    jobs: [ObjectIdentifier: Task<Void, Never>] = [:]
  init(_ source: PlaybackSource, owner: String, mobileToken: String?) {
    media = CastMediaSource(
      urls: [source.url] + source.backups, reference: source.reference,
      authorize: {
        let identity = try await AccountJar.shared.current(.role(.video),credentials:.mobile)
        guard (identity?.id ?? "") == owner, identity?.mobileToken == mobileToken else {
          throw CastProblem.stale
        }
      })
  }
  func start(for device: CastDevice) async throws -> (URL, String) {
    let endpoint = try CastLAN.address(device.endpoint)
    let lan = endpoint.local
    target = endpoint.remote
    let sample = try await media.range(0, 383)
    length = sample.total
    file = try CastVideoFile(sample.data)
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(lan), port: .any)
    let l = try NWListener(using: params)
    let gate = CastPortGate()
    let port: UInt16 = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { cont in
        gate.install(cont)
        queue.async {
          guard !self.closed else {
            gate.finish(.failure(CancellationError()))
            l.cancel()
            return
          }
          self.listener = l
          l.stateUpdateHandler = { state in
            switch state {
            case .ready:
              if let p = l.port {
                gate.finish(.success(p.rawValue))
              } else {
                gate.finish(.failure(CastProblem.network))
                l.cancel()
              }
            case .waiting(let e):
              if case .posix(let r) = e, r == .EACCES || r == .EPERM {
                gate.finish(.failure(CastProblem.localPermission))
                l.cancel()
              }
            case .failed(let e):
              gate.finish(.failure(e))
              l.stateUpdateHandler = nil
            case .cancelled:
              gate.finish(.failure(CancellationError()))
              l.stateUpdateHandler = nil
            default: break
            }
          }
          l.newConnectionHandler = { [weak self] c in
            guard let self, self.connections.count < 8,
              CastLAN.peer(c.endpoint, matches: self.target)
            else {
              c.cancel()
              return
            }
            let id = ObjectIdentifier(c)
            self.connections[id] = c
            c.stateUpdateHandler = { [weak self] s in
              switch s {
              case .cancelled, .failed:
                self?.connections[id] = nil
                self?.jobs.removeValue(forKey: id)?.cancel()
              default: break
              }
            }
            c.start(queue: self.queue)
            self.receive(c, Data())
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak c] in
              if let c, self?.awaitingHeaders.contains(id) == true {
                c.cancel()
                self?.awaitingHeaders.remove(id)
              }
            }
          }
          l.start(queue: self.queue)
          self.queue.asyncAfter(deadline: .now() + 8) {
            if gate.finish(.failure(CastProblem.timeout)) { l.cancel() }
          }
        }
      }
    } onCancel: {
      gate.finish(.failure(CancellationError()))
      l.cancel()
    }
    try Task.checkCancellation()
    guard let url = URL(string: "http://\(CastLAN.literal(lan)):\(port)/\(token)/\(file.name)")
    else { throw CastProblem.address }
    return (url, file.mime)
  }
  private var awaitingHeaders = Set<ObjectIdentifier>()
  private func receive(_ c: NWConnection, _ prefix: Data) {
    let id = ObjectIdentifier(c)
    awaitingHeaders.insert(id)
    c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] d, _, done, error in
      guard let self, let d, !d.isEmpty, error == nil else {
        self?.awaitingHeaders.remove(id)
        c.cancel()
        return
      }
      let full = prefix + d
      guard full.count <= 16384 else {
        self.awaitingHeaders.remove(id)
        c.cancel()
        return
      }
      guard let end = full.range(of: Data("\r\n\r\n".utf8)) else {
        if done {
          self.awaitingHeaders.remove(id)
          c.cancel()
        } else {
          self.receive(c, full)
        }
        return
      }
      self.awaitingHeaders.remove(id)
      let text = String(decoding: full[..<end.upperBound], as: UTF8.self)
      self.jobs[id] = Task {
        await self.serve(c, text)
        self.queue.async { self.jobs[id] = nil }
      }
    }
  }
  private func write(_ c: NWConnection, _ bytes: Data) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      c.send(
        content: bytes,
        completion: .contentProcessed { e in
          if let e { cont.resume(throwing: e) } else { cont.resume() }
        })
    }
  }
  private func serve(_ c: NWConnection, _ header: String) async {
    defer { c.cancel() }
    let route = CastRelayHTTP(path: "/\(token)/\(file.name)", file: file, total: length)
    do {
      try await route.serve(
        header, authorized: { try await self.media.access() },
        read: { lo, hi in
          try await self.media.range(lo, hi, total: self.length).data
        }, write: { d in try await self.write(c, d) })
    } catch {}
  }

  func close() {
    Task { await media.close() }
    queue.async {
      self.closed = true
      self.listener?.cancel()
      self.listener = nil
      for c in self.connections.values { c.cancel() }
      self.jobs.values.forEach { $0.cancel() }
      self.jobs.removeAll()
      self.connections = [:]
      self.awaitingHeaders = []
    }
  }
}
