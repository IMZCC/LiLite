import Foundation
import Network

/// Serves only this session's muxer output, on loopback. Tokens and filenames are exact.
final class LiveFileServer: @unchecked Sendable {
  private let folder: URL, secret = UUID().uuidString
  private let q = DispatchQueue(label: "pili.live.hls.http")
  private var listener: NWListener?, pending: CheckedContinuation<URL, Error>?
  private var clients = [ObjectIdentifier: NWConnection](), awaiting = Set<ObjectIdentifier>()
  private var stopped = false
  init(_ folder: URL) { self.folder = folder }
  func start() async throws -> URL {
    try await withCheckedThrowingContinuation { cont in
      q.async {
        guard !self.stopped else {
          cont.resume(throwing: CancellationError())
          return
        }
        do {
          let p = NWParameters.tcp
          p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
          let l = try NWListener(using: p)
          self.listener = l
          self.pending = cont
          l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self else { return }
            switch state {
            case .ready:
              if let port = l?.port {
                self.resolve(
                  .success(
                    URL(
                      string: "http://127.0.0.1:" + String(port.rawValue) + "/" + self.secret
                        + "/index.m3u8")!))
              } else {
                self.resolve(.failure(URLError(.cannotConnectToHost)))
              }
            case .failed(let err): self.resolve(.failure(err))
            case .cancelled: self.resolve(.failure(CancellationError()))
            default: break
            }
          }
          l.newConnectionHandler = { [weak self] conn in
            guard let self, !self.stopped, self.clients.count < 24 else {
              conn.cancel()
              return
            }
            let id = ObjectIdentifier(conn)
            self.clients[id] = conn
            self.awaiting.insert(id)
            conn.stateUpdateHandler = { [weak self, weak conn] state in
              guard let self, let conn else { return }
              switch state {
              case .failed, .cancelled: self.close(conn)
              default: break
              }
            }
            conn.start(queue: self.q)
            self.receive(conn, Data())
            self.q.asyncAfter(deadline: .now() + 5) { [weak self, weak conn] in
              guard let self, let conn, self.awaiting.contains(id) else { return }
              self.close(conn)
            }
          }
          l.start(queue: self.q)
        } catch { cont.resume(throwing: error) }
      }
    }
  }
  private func resolve(_ result: Result<URL, Error>) {
    let c = pending
    pending = nil
    c?.resume(with: result)
  }
  private func close(_ c: NWConnection) {
    let id = ObjectIdentifier(c)
    awaiting.remove(id)
    if clients.removeValue(forKey: id) != nil {
      c.stateUpdateHandler = nil
      c.cancel()
    }
  }
  func stop() {
    q.async {
      self.stopped = true
      self.resolve(.failure(CancellationError()))
      self.listener?.cancel()
      self.listener = nil
      for c in Array(self.clients.values) { self.close(c) }
    }
  }
  private func receive(_ c: NWConnection, _ prefix: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 2048) {
      [weak self, weak c] part, _, complete, error in
      guard let self, let c else { return }
      var all = prefix
      if let part { all.append(part) }
      guard all.count <= 12 * 1024 else {
        self.close(c)
        return
      }
      if let end = all.range(of: Data([13, 10, 13, 10])) {
        self.awaiting.remove(ObjectIdentifier(c))
        self.respond(c, String(decoding: all[..<end.lowerBound], as: UTF8.self))
        return
      }
      if complete || error != nil { self.close(c) } else { self.receive(c, all) }
    }
  }
  private func empty(_ c: NWConnection, _ code: String, extra: String = "") {
    let h = "HTTP/1.1 " + code + "\r\nConnection: close\r\nContent-Length: 0\r\n" + extra + "\r\n"
    c.send(content: Data(h.utf8), completion: .contentProcessed { [weak self] _ in self?.close(c) })
  }
  private func respond(_ c: NWConnection, _ header: String) {
    let lines = header.components(separatedBy: "\r\n")
    let fields = lines.first?.split(separator: " ") ?? []
    guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD" else {
      empty(c, "405 Method Not Allowed")
      return
    }
    guard let asset = LiveLocalAsset(target: fields[1], secret: secret) else {
      empty(c, "404 Not Found")
      return
    }
    let name = asset.name
    let mime = asset.mime
    guard let f = try? FileHandle(forReadingFrom: folder.appendingPathComponent(name)) else {
      empty(c, "404 Not Found")
      return
    }
    guard let size = try? f.seekToEnd(), size > 0, size < UInt64(Int64.max) else {
      try? f.close()
      empty(c, "404 Not Found")
      return
    }
    let range = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }.map {
      String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces)
    }
    guard let span = RelayRange(range, length: Int64(size)) else {
      try? f.close()
      empty(
        c, "416 Range Not Satisfiable", extra: "Content-Range: bytes */" + String(size) + "\r\n")
      return
    }
    do { try f.seek(toOffset: UInt64(span.first)) } catch {
      try? f.close()
      empty(c, "500 Read Error")
      return
    }
    let n = span.last - span.first + 1
    var h =
      "HTTP/1.1 " + (range == nil ? "200 OK" : "206 Partial Content")
      + "\r\nConnection: close\r\nCache-Control: no-store\r\nAccept-Ranges: bytes\r\nContent-Type: "
      + mime + "\r\nContent-Length: " + String(n) + "\r\n"
    if range != nil {
      h +=
        "Content-Range: bytes " + String(span.first) + "-" + String(span.last) + "/" + String(size)
        + "\r\n"
    }
    h += "\r\n"
    let head = fields[0] == "HEAD"
    c.send(
      content: Data(h.utf8),
      completion: .contentProcessed { [weak self] err in
        guard let self else {
          try? f.close()
          return
        }
        if head || err != nil {
          try? f.close()
          self.close(c)
        } else {
          self.copy(f, c, n)
        }
      })
  }
  private func copy(_ f: FileHandle, _ c: NWConnection, _ left: Int64) {
    guard !stopped, left > 0, let d = try? f.read(upToCount: Int(min(left, 64 * 1024))), !d.isEmpty
    else {
      try? f.close()
      close(c)
      return
    }
    c.send(
      content: d,
      completion: .contentProcessed { [weak self] err in
        guard let self else {
          try? f.close()
          return
        }
        if err != nil {
          try? f.close()
          self.close(c)
        } else {
          self.copy(f, c, left - Int64(d.count))
        }
      })
  }
}
