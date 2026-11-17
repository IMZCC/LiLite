import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum HTTP11Message {
  static func requiresSystemSession(negotiate: Bool, contentType: String?) -> Bool {
    negotiate || contentType?.lowercased().hasPrefix("application/grpc") == true
  }
  static func mutatingGET(_ path: String) -> Bool {
    [
      "/xlive/app-interface/v2/index/feedback", "/x/feed/dislike", "/x/feed/dislike/cancel",
      "/session_svr/v1/session_svr/update_ack", "/x/sys-msg/update_cursor", "/x/passport-login/web/qrcode/generate", "/x/passport-login/web/qrcode/poll",
    ].contains(path)
  }
  static func allowsRedirect(method: String, from: URL, to: URL) -> Bool {
    ["GET", "HEAD"].contains(method.uppercased()) && !mutatingGET(from.path)
      && !mutatingGET(to.path)
      && from.scheme?.lowercased() == "https" && to.scheme?.lowercased() == "https"
      && from.host != nil && from.host?.lowercased() == to.host?.lowercased()
      && (from.port ?? 443) == (to.port ?? 443)
      && from.user == nil && from.password == nil && to.user == nil && to.password == nil
  }
  static func token(_ s: String) -> Bool {
    !s.isEmpty
      && s.utf8.allSatisfy { b in
        (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b)
          || "!#$%&'*+-.^_|\u{60}~".utf8.contains(b)
      }
  }
  static func request(_ request: URLRequest) throws -> Data {
    guard let u = request.url, u.scheme?.lowercased() == "https", u.user == nil, u.password == nil,
      let parts = URLComponents(url: u, resolvingAgainstBaseURL: false), let name = parts.host,
      !name.isEmpty, !name.utf8.contains(where: { $0 <= 32 || $0 >= 127 }),
      request.httpBodyStream == nil
    else { throw URLError(.badURL) }
    let port = parts.port ?? 443
    guard (1...65535).contains(port) else { throw URLError(.badURL) }
    let method = request.httpMethod ?? "GET"
    guard token(method), !["CONNECT", "TRACE"].contains(method.uppercased()) else {
      throw URLError(.unsupportedURL)
    }
    let path =
      (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath)
      + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    guard path.hasPrefix("/"), !path.utf8.contains(where: { $0 <= 32 || $0 >= 127 }) else {
      throw URLError(.badURL)
    }
    let host = name.contains(":") && !name.hasPrefix("[") ? "[" + name + "]" : name
    var header =
      "\(method) \(path) HTTP/1.1\r\nHost: \(host)\(port == 443 ? "" : ":\(port)")\r\nConnection: close\r\nAccept-Encoding: identity\r\n"
    let reserved = [
      "host", "content-length", "connection", "transfer-encoding", "te", "expect", "trailer",
      "upgrade", "accept-encoding", "proxy-connection", "proxy-authorization",
    ]
    for (k, v) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
      guard token(k), v.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else {
        throw URLError(.badURL)
      }
      if !reserved.contains(k.lowercased()) { header += "\(k): \(v)\r\n" }
    }
    let body = request.httpBody
    if body != nil || ["POST", "PUT", "PATCH"].contains(method.uppercased()) {
      header += "Content-Length: \(body?.count ?? 0)\r\n"
    }
    guard header.utf8.count < 64 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
    var data = Data((header + "\r\n").utf8)
    if let body { data.append(body) }
    return data
  }
}
struct HTTP11Reply {
  enum State {
    case headers
    case fixed(Int)
    case untilClose, chunkSize
    case chunk(Int)
    case terminator, trailers, done
  }
  let method: String, limit: Int
  private var buffer = Data(), state = State.headers, interim = 0, trailerBytes = 0
  private(set) var status = 0, fields: [String: String] = [:], body = Data(),
    setCookie: [String] = []
  init(method: String = "GET", limit: Int) {
    self.method = method
    self.limit = limit
  }
  var complete: Bool {
    if case .done = state { return true }
    return false
  }
  private static let ending = Data([13, 10]), block = Data([13, 10, 13, 10])
  private static func latin1(_ bytes: Data) -> String {
    String(String.UnicodeScalarView(bytes.map { UnicodeScalar($0) }))
  }
  private func invalid() -> URLError { .init(.cannotParseResponse) }
  private mutating func line(_ max: Int) throws -> String? {
    guard let r = buffer.range(of: Self.ending) else {
      if buffer.count > max { throw invalid() }
      return nil
    }
    let n = buffer.distance(from: buffer.startIndex, to: r.lowerBound)
    guard n <= max else { throw invalid() }
    let s = Self.latin1(buffer.prefix(n))
    buffer.removeFirst(n + 2)
    return s
  }
  private static func field(_ line: String) throws -> (String, String) {
    guard let split = line.firstIndex(of: ":") else { throw URLError(.cannotParseResponse) }
    let name = String(line[..<split]).lowercased()
    let value = String(line[line.index(after: split)...])
    guard HTTP11Message.token(name), value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 })
    else { throw URLError(.cannotParseResponse) }
    return (name, value.trimmingCharacters(in: .whitespaces))
  }
  private mutating func append(_ n: Int) throws {
    guard n >= 0, n <= buffer.count, n <= limit - body.count else {
      throw URLError(.dataLengthExceedsMaximum)
    }
    body.append(buffer.prefix(n))
    buffer.removeFirst(n)
  }
  /// Input is split into small records by the transport. All framing and body sizes remain bounded.
  mutating func receive(_ bytes: Data, end: Bool) throws {
    buffer.append(bytes)
    processing: while true {
      switch state {
      case .headers:
        guard let r = buffer.range(of: Self.block) else {
          if buffer.count > 65536 { throw invalid() }
          break processing
        }
        let n = buffer.distance(from: buffer.startIndex, to: r.lowerBound)
        guard n <= 65536 else { throw invalid() }
        let raw = Self.latin1(buffer.prefix(n))
        buffer.removeFirst(n + 4)
        let lines = raw.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", maxSplits: 2)
        guard first.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(first[0]), first[1].count == 3,
          let code = Int(first[1]), (100...599).contains(code), code != 101
        else { throw invalid() }
        var headers: [String: String] = [:]
        var cookies: [String] = []
        for line in lines.dropFirst() {
          let (k, v) = try Self.field(line)
          if k == "set-cookie" {
            cookies.append(v)
            if headers[k] == nil { headers[k] = v }
            continue
          }
          if let previous = headers[k] {
            if k == "content-length" {
              guard previous == v else { throw invalid() }
            } else {
              headers[k] = previous + ", " + v
            }
          } else {
            headers[k] = v
          }
        }
        if code < 200 {
          interim += 1
          if interim > 8 { throw invalid() }
          continue
        }
        status = code
        fields = headers
        setCookie = cookies
        let te = headers["transfer-encoding"]?.lowercased()
        let cl = headers["content-length"]
        guard te == nil || cl == nil else { throw invalid() }
        if method.uppercased() == "HEAD" || [204, 205, 304].contains(code) {
          state = .done
        } else if let te {
          guard te == "chunked" else { throw invalid() }
          state = .chunkSize
        } else if let cl {
          guard !cl.isEmpty, cl.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(cl) else {
            throw invalid()
          }
          guard n <= limit else { throw URLError(.dataLengthExceedsMaximum) }
          state = n == 0 ? .done : .fixed(n)
        } else {
          state = .untilClose
        }
      case .fixed(let left), .chunk(let left):
        if buffer.isEmpty { break processing }
        let n = min(left, buffer.count)
        try append(n)
        if case .chunk = state {
          state = left == n ? .terminator : .chunk(left - n)
        } else {
          state = left == n ? .done : .fixed(left - n)
        }
      case .chunkSize:
        guard let raw = try line(4096) else { break processing }
        let text = raw.prefix(while: { $0 != ";" })
        guard !text.isEmpty, text.count <= 16,
          text.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
          }),
          let n = Int(text, radix: 16)
        else { throw invalid() }
        guard n <= limit - body.count else { throw URLError(.dataLengthExceedsMaximum) }
        state = n == 0 ? .trailers : .chunk(n)
      case .terminator:
        guard buffer.count >= 2 else { break processing }
        guard buffer.prefix(2) == Self.ending else { throw invalid() }
        buffer.removeFirst(2)
        state = .chunkSize
      case .trailers:
        guard let raw = try line(8192) else { break processing }
        trailerBytes += raw.utf8.count + 2
        guard trailerBytes <= 32768 else { throw invalid() }
        if raw.isEmpty { state = .done } else { _ = try Self.field(raw) }
      case .untilClose:
        try append(buffer.count)
        if end { state = .done }
        break processing
      case .done: break processing
      }
    }
    if end && !complete { throw URLError(.networkConnectionLost) }
    if complete && !buffer.isEmpty { throw invalid() }
  }
}
