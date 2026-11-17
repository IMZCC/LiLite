import Foundation

enum CastVideoFile: Equatable {
  case mp4, flv, ts, mpeg
  var mime: String {
    switch self {
    case .mp4: "video/mp4"
    case .flv: "video/x-flv"
    case .ts: "video/mp2t"
    case .mpeg: "video/mpeg"
    }
  }
  var name: String {
    switch self {
    case .mp4: "video.mp4"
    case .flv: "video.flv"
    case .ts: "video.ts"
    case .mpeg: "video.mpg"
    }
  }
  init(_ data: Data) throws {
    let b = [UInt8](data)
    if b.count >= 8 && String(bytes: b[4..<8], encoding: .ascii) == "ftyp" {
      self = .mp4
    } else if b.starts(with: [70, 76, 86, 1]) {
      self = .flv
    } else if b.count > 188 && b[0] == 0x47 && b[188] == 0x47 {
      self = .ts
    } else if b.starts(with: [0, 0, 1, 0xba]) {
      self = .mpeg
    } else {
      throw ServiceError("投屏服务返回了不支持的视频格式")
    }
  }
}
struct CastRelayHTTP {
  let path: String, file: CastVideoFile, total: Int64
  static func empty(_ status: String, _ fields: String = "") -> Data {
    Data(
      ("HTTP/1.1 " + status + "\r\nContent-Length: 0\r\n" + fields + "Connection: close\r\n\r\n")
        .utf8)
  }
  /// Serve one immutable, device-bound lease. No request can choose an origin, inject headers or
  /// ask the phone to fetch a different path. Keep only a single 1 MiB range in transit.
  @discardableResult func serve(
    _ text: String, authorized: () async throws -> Void,
    read: (Int64, Int64) async throws -> Data, write: (Data) async throws -> Void
  ) async throws -> Int {
    guard text.utf8.count <= 16384, total > 0, text.hasSuffix("\r\n\r\n") else {
      try await write(Self.empty("400 Bad Request"))
      return 400
    }
    let lines = text.components(separatedBy: "\r\n")
    let method = lines[0].split(separator: " ")
    guard method.count == 3, method[1] == Substring(path),
      ["HTTP/1.0", "HTTP/1.1"].contains(method[2])
    else {
      try await write(Self.empty("404 Not Found"))
      return 404
    }
    guard method[0] == "GET" || method[0] == "HEAD" else {
      try await write(Self.empty("405 Method Not Allowed", "Allow: GET, HEAD\r\n"))
      return 405
    }
    let ranges = lines.dropFirst().filter { $0.lowercased().hasPrefix("range:") }
    let raw = ranges.first.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
    guard ranges.count <= 1, let span = RelayRange(raw, length: total) else {
      try await write(
        Self.empty("416 Range Not Satisfiable", "Content-Range: bytes */\(total)\r\n"))
      return 416
    }
    do { try await authorized() } catch {
      try await write(Self.empty("403 Forbidden"))
      return 403
    }
    func block(_ lo: Int64) async throws -> Data {
      let hi = lo + min(1024 * 1024 - 1, span.last - lo)
      try Task.checkCancellation()
      let d = try await read(lo, hi)
      guard d.count == hi - lo + 1 else { throw CastProblem.reply }
      try await authorized()
      return d
    }
    var first: Data?
    if method[0] == "GET" {
      do { first = try await block(span.first) } catch {
        try Task.checkCancellation()
        try await write(Self.empty("502 Bad Gateway"))
        return 502
      }
    }
    var headers =
      "HTTP/1.1 " + (raw == nil ? "200 OK" : "206 Partial Content")
      + "\r\nAccept-Ranges: bytes\r\nContent-Type: \(file.mime)\r\ntransferMode.dlna.org: Streaming\r\ncontentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0\r\nContent-Length: \(span.last-span.first+1)\r\nConnection: close\r\n"
    if raw != nil { headers += "Content-Range: bytes \(span.first)-\(span.last)/\(total)\r\n" }
    try await write(Data((headers + "\r\n").utf8))
    if let content = first { try await write(content) }
    var p = span.first + Int64(first?.count ?? 0)
    first = nil
    if method[0] == "GET" {
      while p <= span.last {
        let d = try await block(p)
        try await write(d)
        p += Int64(d.count)
      }
    }
    return raw == nil ? 200 : 206
  }
}
