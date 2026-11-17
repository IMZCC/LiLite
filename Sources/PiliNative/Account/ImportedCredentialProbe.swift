import Foundation

enum MobileIdentityRequest {
  static func make(_ token: String, device: String = MobileDeviceID.guest(), timestamp: Int64 = Int64(Date().timeIntervalSince1970)) throws -> URLRequest {
    guard (8...1024).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) })
    else { throw ServiceError("授权令牌格式无效") }
    guard MobileDeviceID.valid(device) else { throw ServiceError("设备标识无效") }
    var url = URLComponents(string: "https://app.bilibili.com/x/v2/account/myinfo")!
    let fields = MobileClientSigning.signed(["access_key": token, "mobi_app": "iphone", "platform": "ios"], timestamp: timestamp)
    url.percentEncodedQuery = MobileClientSigning.formEncoded(fields)
    guard let address = url.url else { throw URLError(.badURL) }
    var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    request.httpShouldHandleCookies = false
    request.setValue(MobileClientSigning.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(device, forHTTPHeaderField: "buvid")
    request.setValue("android_hd", forHTTPHeaderField: "app-key")
    request.setValue("prod", forHTTPHeaderField: "env")
    return request
  }
  static func owner(_ bytes: Data, status: Int) throws -> Int64 {
    struct Packet: Decodable {
      struct Person: Decodable { let mid: Int64 }
      let code: Int, data: Person?
    }
    guard status == 200,
      let packet = try? JSONDecoder().decode(Packet.self, from: bytes), packet.code == 0,
      let uid = packet.data?.mid, uid > 0 else { throw ServiceError("授权令牌无效或已过期") }
    return uid
  }
}

enum ImportedCredentialProbe {
  /// Deliberately token-only: a working web cookie cannot make the wrong mobile token pass.
  static func mobileOwner(_ token: String) async throws -> Int64 {
    let request = try MobileIdentityRequest.make(token)
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.httpShouldSetCookies = false
    config.urlCredentialStorage = nil; config.urlCache = nil
    let proxy = APIProxy.current(); proxy.apply(to:config)
    let native = URLSession(configuration:config,delegate:APIRedirectPolicy(),delegateQueue:nil)
    defer { native.finishTasksAndInvalidate() }
    let bytes:Data, response:URLResponse
    do { (bytes,response) = try await BiliServiceSession(native:native,proxy:proxy).data(for:request) }
    catch {
      try Task.checkCancellation()
      throw ServiceError("暂时无法连接账号服务")
    }
    try Task.checkCancellation()
    return try MobileIdentityRequest.owner(bytes, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
  }
}
