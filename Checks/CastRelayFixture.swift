import Foundation
import Glibc

enum CastProblem: Error { case reply }
struct ServiceError: Error {
  let text: String
  init(_ s: String) { text = s }
}
@main enum Fixture {
  static func main() async throws {
    let origin = URL(string: CommandLine.arguments[1])!
    precondition(origin.host == "127.0.0.1")
    let media = CastMediaSource(
      urls: ["unavailable", "movie"].map { origin.appendingPathComponent("media/" + $0) },
      reference: origin.appendingPathComponent("source"))
    let first = try await media.range(0, 383)
    let file = try CastVideoFile(first.data)
    let relay = CastRelayHTTP(path: "/fixture/" + file.name, file: file, total: first.total)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    defer { _ = close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { a in
        bind(fd, a, length) == 0 && getsockname(fd, a, &length) == 0
      }
    }
    guard ok, listen(fd, 8) == 0 else { throw ServiceError("fixture listen") }
    FileHandle.standardOutput.write(Data((String(UInt16(bigEndian: addr.sin_port)) + "\n").utf8))
    var allowed = true
    for _ in 0..<10 {
      let c = accept(fd, nil, nil)
      guard c >= 0 else { throw ServiceError("fixture accept") }
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 8192)
      while !bytes.contains(Data("\r\n\r\n".utf8)), bytes.count < 16384 {
        let n = recv(c, &buffer, buffer.count, 0)
        if n <= 0 { break }
        bytes.append(contentsOf: buffer.prefix(n))
      }
      let text = String(decoding: bytes, as: UTF8.self)
      if text.hasPrefix("GET /fixture/revoke ") { allowed = false }
      do {
        try await relay.serve(
          text,
          authorized: {
            guard allowed else { throw ServiceError("revoked") }
            try await media.access()
          }, read: { lo, hi in try await media.range(lo, hi, total: first.total).data },
          write: { data in
            try data.withUnsafeBytes { b in
              var off = 0
              while off < b.count {
                let n = send(c, b.baseAddress! + off, b.count - off, Int32(MSG_NOSIGNAL))
                guard n > 0 else { throw ServiceError("peer left") }
                off += n
              }
            }
          })
      } catch {}
      _ = close(c)
    }
    await media.close()
  }
}
