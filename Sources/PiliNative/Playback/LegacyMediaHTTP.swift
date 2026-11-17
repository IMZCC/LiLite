import Foundation
import Network

final class LegacyMediaHTTP: @unchecked Sendable {
  typealias Body = (data: Data, type: String)
  private let handler: @Sendable (String) async throws -> Body
  private let queue = DispatchQueue(label: "pilinative.legacy-slices"), token = UUID().uuidString
  private var listener: NWListener?, waiting = true
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var jobs: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var paths: [ObjectIdentifier: String] = [:]
  init(handler: @escaping @Sendable (String) async throws -> Body) { self.handler = handler }
  func start() async throws -> URL {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let server = try NWListener(using: parameters); listener = server
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      server.stateUpdateHandler = { state in
        guard self.waiting else { return }
        switch state {
        case .ready:
          self.waiting = false
          if let port = server.port { continuation.resume(returning: port.rawValue) }
          else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
        case .failed(let error): self.waiting = false; continuation.resume(throwing: error)
        case .cancelled: self.waiting = false; continuation.resume(throwing: CancellationError())
        default: break
        }
      }
      server.newConnectionHandler = { [weak self] connection in
        guard let self else { connection.cancel(); return }
        let key = ObjectIdentifier(connection); self.connections[key] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
          guard let connection else { return }
          switch state {
          case .failed, .cancelled:
            self?.jobs.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            self?.paths.removeValue(forKey: ObjectIdentifier(connection))
          default: break
          }
        }
        connection.start(queue: self.queue); self.receive(connection, input: Data())
      }
      server.start(queue: queue)
    }
    return URL(string: "http://127.0.0.1:\(port)/\(token)/master.m3u8")!
  }
  func cancelRequests() {
    queue.async {
      self.jobs.values.forEach { $0.cancel() }; self.jobs.removeAll()
      self.connections.values.forEach { $0.cancel() }; self.connections.removeAll()
    }
  }
  func close() { cancelRequests(); queue.async { self.listener?.cancel(); self.listener = nil } }
  func cancelSlices(near n: Int) {
    queue.async {
      for (key, path) in self.paths {
        guard let name = path.split(separator: "/").last,
          let fragment = DecoderFragment.request(String(name)), abs(fragment.index - n) > 2 else { continue }
        self.jobs.removeValue(forKey: key)?.cancel(); self.connections[key]?.cancel()
      }
    }
  }
  private func receive(_ connection: NWConnection, input: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, done, error in
      guard let self, let bytes, !bytes.isEmpty, error == nil else { connection.cancel(); return }
      let data = input + bytes
      guard data.count <= 8192 else { connection.cancel(); return }
      guard let request = String(data: data, encoding: .utf8), request.contains("\r\n\r\n") else {
        if done { connection.cancel() } else { self.receive(connection, input: data) }; return
      }
      let lines = request.components(separatedBy: "\r\n"), fields = lines[0].split(separator: " ")
      guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD", fields[1].hasPrefix("/\(self.token)/") else { connection.cancel(); return }
      let path = String(fields[1].dropFirst(self.token.count + 2)), head = fields[0] == "HEAD"
      self.paths[ObjectIdentifier(connection)] = path
      let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces).lowercased() }
      self.jobs[ObjectIdentifier(connection)] = Task {
        do {
          let body = try await self.handler(path); try Task.checkCancellation()
          guard body.data.count <= 48 * 1024 * 1024 else { throw DecoderProblem.size }
          var data = body.data, code = 200, extra = ""
          if let range {
            guard let span = RelayRange(range, length: Int64(data.count)) else {
              let packet = Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(data.count)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
              self.queue.async { connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() }) }
              return
            }
            extra = "Content-Range: bytes \(span.first)-\(span.last)/\(data.count)\r\n"
            data = data.subdata(in: Int(span.first)..<Int(span.last + 1)); code = 206
          }
          let header = "HTTP/1.1 \(code) OK\r\nContent-Type: \(body.type)\r\nContent-Length: \(data.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\n\(extra)Connection: close\r\n\r\n"
          let packet = Data(header.utf8) + (head ? Data() : data)
          self.queue.async { connection.send(content: packet, completion: .contentProcessed { _ in connection.cancel() }) }
        } catch {
          if Task.isCancelled { connection.cancel() }
          else { connection.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() }) }
        }
      }
    }
  }
}
