import CFNetwork

import Foundation

import Network

import Security

private enum HTTP11Proxy {
  typealias Row = [String: Any]
  private final class PACResult { var rows: [Row]? }
  private static func pac(_ u: URL, endpoint: URL) throws -> [Row] {
    let box = PACResult()
    var context = CFStreamClientContext(
      version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: CFProxyAutoConfigurationResultCallback = { opaque, list, error in
      if error == nil {
        Unmanaged<PACResult>.fromOpaque(opaque).takeUnretainedValue().rows = list as? [Row]
      }
      CFRunLoopStop(CFRunLoopGetCurrent())
    }
    let source = CFNetworkExecuteProxyAutoConfigurationURL(
      u as CFURL, endpoint as CFURL, callback, &context)
    let loop = CFRunLoopGetCurrent()
    CFRunLoopAddSource(loop, source, .defaultMode)
    defer {
      CFRunLoopSourceInvalidate(source)
      CFRunLoopRemoveSource(loop, source, .defaultMode)
    }
    CFRunLoopRunInMode(.defaultMode, 6, false)
    guard let rows = box.rows else { throw URLError(.cannotConnectToHost) }
    return rows
  }
  private static func choose(_ rows: [Row], _ url: URL, depth: Int) throws -> ProxyConfiguration? {
    guard depth < 3, let row = rows.first, let kind = row[kCFProxyTypeKey as String] as? String
    else { throw ServiceError("无法读取系统代理") }
    if kind == kCFProxyTypeNone as String { return nil }
    if kind == kCFProxyTypeAutoConfigurationURL as String,
      let u = row[kCFProxyAutoConfigurationURLKey as String] as? URL
    {
      return try choose(pac(u, endpoint: url), url, depth: depth + 1)
    }
    if kind == kCFProxyTypeAutoConfigurationJavaScript as String,
      let script = row[kCFProxyAutoConfigurationJavaScriptKey as String] as? String
    {
      var error: Unmanaged<CFError>?
      let result = CFNetworkCopyProxiesForAutoConfigurationScript(
        script as CFString, url as CFURL, &error)?.takeRetainedValue()
      if let error {
        _ = error.takeRetainedValue()
        throw ServiceError("系统代理配置不可用")
      }
      return try choose(result as? [Row] ?? [], url, depth: depth + 1)
    }
    guard let host = row[kCFProxyHostNameKey as String] as? String, !host.isEmpty,
      let n = row[kCFProxyPortNumberKey as String] as? Int,
      let p = UInt16(exactly: n), p > 0, let port = NWEndpoint.Port(rawValue: p)
    else { throw ServiceError("系统代理地址无效") }
    let endpoint = NWEndpoint.hostPort(host: .init(host), port: port)
    var proxy: ProxyConfiguration
    if kind == kCFProxyTypeHTTP as String || kind == kCFProxyTypeHTTPS as String {
      proxy = .init(httpCONNECTProxy: endpoint)
    } else if kind == kCFProxyTypeSOCKS as String {
      proxy = .init(socksv5Proxy: endpoint)
    } else {
      throw ServiceError("系统代理类型不支持，可选择自动协商")
    }
    proxy.allowFailover = false
    if let user = row[kCFProxyUsernameKey as String] as? String,
      let password = row[kCFProxyPasswordKey as String] as? String
    {
      proxy.applyCredential(username: user, password: password)
    }
    return proxy
  }
  static func resolve(_ preference: APIProxy, url: URL) async throws -> ProxyConfiguration? {
    if preference.enabled {
      let proxy = try preference.validated()
      guard let n = UInt16(proxy.port), let port = NWEndpoint.Port(rawValue: n) else {
        throw ServiceError("无效的接口代理")
      }
      var config = ProxyConfiguration(
        httpCONNECTProxy: .hostPort(host: .init(proxy.host), port: port))
      config.allowFailover = false
      return config
    }
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        do {
          guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else {
            throw ServiceError("无法读取系统代理")
          }
          let routes = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue()
          continuation.resume(returning: try choose(routes as? [Row] ?? [], url, depth: 0))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
private struct HTTP11Result { let data: Data, response: HTTPURLResponse, setCookie: [String] }
private final class HTTP11Job: @unchecked Sendable {
  private let queue = DispatchQueue(label: "PiliNative.HTTP11")
  private let connection: NWConnection, url: URL, request: Data, timeout: Double
  private var parser: HTTP11Reply, stopped = false,
    continuation: CheckedContinuation<HTTP11Result, Error>?
  private var deadline: DispatchWorkItem?
  init(_ input: URLRequest, proxy: ProxyConfiguration?, limit: Int) throws {
    guard let url = input.url, let name = url.host, let n = UInt16(exactly: url.port ?? 443),
      let port = NWEndpoint.Port(rawValue: n), n > 0
    else { throw URLError(.badURL) }
    self.url = url
    request = try HTTP11Message.request(input)
    parser = .init(method: input.httpMethod ?? "GET", limit: limit)
    timeout = max(1, min(120, input.timeoutInterval))
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_set_peer_authentication_required(options, true)
    sec_protocol_options_set_tls_server_name(options, name)
    sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
    if ServerCertificatePolicy.enabled() {
      sec_protocol_options_set_verify_block(options, { _, _, complete in
        complete(ServerCertificatePolicy.enabled())
      }, queue)
    }
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    if let proxy {
      let context = NWParameters.PrivacyContext(description: "PiliNative.HTTP11.proxy")
      context.disableLogging()
      context.proxyConfigurations = [proxy]
      parameters.setPrivacyContext(context)
    }
    connection = NWConnection(host: .init(name), port: port, using: parameters)
  }
  func perform() async throws -> HTTP11Result {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { c in
        queue.async { [self] in
          if stopped {
            c.resume(throwing: CancellationError())
            return
          }
          continuation = c
          let timeoutAction = DispatchWorkItem { [weak self] in
            self?.finish(.failure(URLError(.timedOut)))
          }
          deadline = timeoutAction
          queue.asyncAfter(deadline: .now() + timeout, execute: timeoutAction)
          connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
              self.connection.send(
                content: self.request,
                completion: .contentProcessed { [weak self] error in
                  guard let self, !self.stopped else { return }
                  if let error {
                    self.finish(.failure(Self.network(error)))
                  } else {
                    self.receive()
                  }
                })
            case .failed(let e), .waiting(let e): self.finish(.failure(Self.network(e)))
            case .cancelled: self.finish(.failure(CancellationError()))
            default: break
            }
          }
          connection.start(queue: queue)
        }
      }
    } onCancel: {
      self.queue.async { self.finish(.failure(CancellationError())) }
    }
  }
  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, end, error in
      guard let self, !self.stopped else { return }
      do {
        if let error { throw Self.network(error) }
        try self.parser.receive(data ?? Data(), end: end)
        if self.parser.complete {
          guard
            let response = HTTPURLResponse(
              url: self.url, statusCode: self.parser.status, httpVersion: "HTTP/1.1",
              headerFields: self.parser.fields)
          else { throw URLError(.cannotParseResponse) }
          let encoding = (response.value(forHTTPHeaderField: "Content-Encoding") ?? "identity")
            .lowercased()
          guard encoding == "identity" || self.parser.body.isEmpty else {
            throw URLError(.cannotDecodeContentData)
          }
          self.finish(
            .success(
              .init(data: self.parser.body, response: response, setCookie: self.parser.setCookie)))
        } else {
          self.receive()
        }
      } catch { self.finish(.failure(error)) }
    }
  }
  private static func network(_ e: NWError) -> URLError {
    switch e {
    case .tls: return URLError(.secureConnectionFailed)
    case .dns: return URLError(.dnsLookupFailed)
    case .posix(let v):
      switch v {
      case .ETIMEDOUT: return URLError(.timedOut)
      case .ENETDOWN, .ENETUNREACH: return URLError(.notConnectedToInternet)
      case .ECONNRESET, .EPIPE: return URLError(.networkConnectionLost)
      default: return URLError(.cannotConnectToHost)
      }
    default: return URLError(.unknown)
    }
  }
  private func finish(_ result: Result<HTTP11Result, Error>) {
    guard !stopped else { return }
    stopped = true
    deadline?.cancel()
    deadline = nil
    connection.stateUpdateHandler = nil
    connection.cancel()
    let c = continuation
    continuation = nil
    c?.resume(with: result)
  }
}
struct BiliServiceSession {
  static let key = "network.negotiateHTTP2"
  let native: URLSession, proxy: APIProxy
  func data(for input: URLRequest) async throws -> (Data, URLResponse) {
    let r = try await response(for: input)
    return (r.data, r.http)
  }
  func response(for input: URLRequest) async throws -> (
    data: Data, http: HTTPURLResponse, cookies: [HTTPCookie]
  ) {
    let method = input.httpMethod?.uppercased() ?? "GET"
    let mutates = !["GET", "HEAD", "OPTIONS"].contains(method) || HTTP11Message.mutatingGET(input.url?.path ?? "")
    let done = mutates ? try SleepExitFence.shared.enter() : nil
    defer { done?() }
    // gRPC framing/trailers remain on the existing URLSession transport irrespective of the REST preference.
    if HTTP11Message.requiresSystemSession(
      negotiate: UserDefaults.standard.bool(forKey: Self.key),
      contentType: input.value(forHTTPHeaderField: "Content-Type"))
    {
      let capture = (native.delegate as? CertificateSessionDelegate).map { ResponseCookieCapture(forwarding: $0) }
      let bytes: Data, raw: URLResponse
      if let capture { (bytes, raw) = try await native.data(for: input, delegate: capture) }
      else { (bytes, raw) = try await native.data(for: input) }
      guard let http = raw as? HTTPURLResponse, http.url != nil else {
        throw URLError(.cannotParseResponse)
      }
      let cookies = (capture?.cookies ?? []) + ResponseCookieOrigin.received(http)
      return (bytes, http, cookies)
    }
    var request = input
    var receivedCookies = [HTTPCookie]()
    for hop in 0...5 {
      try Task.checkCancellation()
      guard let url = request.url else { throw URLError(.badURL) }
      let config = try await HTTP11Proxy.resolve(proxy, url: url)
      try Task.checkCancellation()
      let result: HTTP11Result
      do {
        result = try await HTTP11Job(request, proxy: config, limit: 32 * 1024 * 1024).perform()
      } catch {
        if let e = error as? URLError, e.code != .cancelled {
          DiagnosticJournal.network(url.path, "网络错误", e.errorCode)
        }
        throw error
      }
      let r = result.response
      receivedCookies += ResponseCookieOrigin.marked(result.setCookie.flatMap {
        HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": $0], for: url)
      }, from: url)
      if r.statusCode >= 400 { DiagnosticJournal.network(url.path, "HTTP", r.statusCode) }
      guard [301, 302, 303, 307, 308].contains(r.statusCode),
        let rawURL = r.value(forHTTPHeaderField: "Location"),
        let next = URL(string: rawURL, relativeTo: url)?.absoluteURL,
        HTTP11Message.allowsRedirect(method: request.httpMethod ?? "GET", from: url, to: next)
      else {
        return (result.data, r, receivedCookies)
      }
      guard hop < 5 else { throw URLError(.httpTooManyRedirects) }
      request.url = next
    }
    throw URLError(.httpTooManyRedirects)
  }
}
