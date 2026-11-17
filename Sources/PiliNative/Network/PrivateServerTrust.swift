import CryptoKit

import Foundation

import Security

import SwiftUI

import UniformTypeIdentifiers

/// Only installed on a dedicated WebDAV or user-configured SponsorBlock session; never on BiliAPI.

enum PrivateServerTrust {
  private static func query(_ target: PrivateServiceOrigin) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "PiliNative.PrivateTLS",
      kSecAttrAccount as String: target.key, kSecAttrSynchronizable as String: false,
    ]
  }
  static func read(_ target: PrivateServiceOrigin) throws -> Data? {
    var q = query(target)
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    q[kSecReturnData as String] = true
    var data: CFTypeRef?
    let rc = SecItemCopyMatching(q as CFDictionary, &data)
    if rc == errSecItemNotFound { return nil }
    guard rc == errSecSuccess, let bytes = data as? Data else { throw ServiceError("未能读取本机证书") }
    return bytes
  }
  static func validate(_ bytes: Data, for target: PrivateServiceOrigin) throws -> PrivateCertificate
  {
    guard let cert = try? PrivateCertificate(bytes), cert.valid(),
      SecCertificateCreateWithData(nil, cert.der as CFData) != nil
    else {
      throw ServiceError("请选择有效期内的 X.509 证书（PEM 或 DER）")
    }
    guard cert.authority || cert.matches(target.host) else { throw ServiceError("证书名称与当前服务器不匹配") }
    return cert
  }
  static func set(_ bytes: Data?, for origin: PrivateServiceOrigin) throws {
    let q = query(origin)
    if let bytes {
      let cert = try validate(bytes, for: origin)
      let rc = SecItemUpdate(q as CFDictionary, [kSecValueData as String: cert.der] as CFDictionary)
      if rc == errSecItemNotFound {
        var item = q
        item[kSecValueData as String] = cert.der
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
          throw ServiceError("未能保存本机证书")
        }
      } else if rc != errSecSuccess {
        throw ServiceError("未能更新本机证书")
      }
    } else {
      let rc = SecItemDelete(q as CFDictionary)
      guard rc == errSecSuccess || rc == errSecItemNotFound else { throw ServiceError("未能移除本机证书") }
    }
  }
  static func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
  }
}
final class PrivateServiceDelegate: NSObject, URLSessionTaskDelegate {
  let target: PrivateServiceOrigin?, anchor: Data?, denyRedirect: Bool
  private let authentication: SelfHostedHTTPAuthentication?
  init(service: PrivateServiceOrigin.Service, url: URL, denyRedirect: Bool, user: String? = nil, password: String? = nil) throws {
    target = PrivateServiceOrigin(service, url)
    anchor = try target.map { try PrivateServerTrust.read($0) } ?? nil
    self.denyRedirect = denyRedirect
    authentication = service == .dav && user?.isEmpty == false
      ? .init(origin: url, user: user!, password: password ?? "") : nil
  }
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let space = challenge.protectionSpace
    if let authentication, SelfHostedHTTPAuthentication.handles(space.authenticationMethod) {
      guard let credential = authentication.credential(for: challenge) else {
        completionHandler(.cancelAuthenticationChallenge, nil); return
      }
      completionHandler(.useCredential, credential); return
    }
    if let credential = ServerCertificatePolicy.credential(for: challenge) {
      completionHandler(.useCredential, credential)
      return
    }
    guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    guard let target, let anchor else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    guard target.matches(space.host, space.port), space.protocol?.lowercased() == "https",
      challenge.previousFailureCount == 0, let trust = space.serverTrust,
      let policy = try? PrivateServerTrust.validate(anchor, for: target),
      let root = SecCertificateCreateWithData(nil, anchor as CFData)
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    var current: CFArray?
    guard SecTrustCopyPolicies(trust, &current) == errSecSuccess,
      let original = current as? [SecPolicy],
      SecTrustSetPolicies(
        trust, (original + [SecPolicyCreateSSL(true, target.host as CFString)]) as CFArray)
        == errSecSuccess,
      SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
      SecTrustEvaluateWithError(trust, nil),
      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let first = chain.first,
      let leaf = try? PrivateCertificate(SecCertificateCopyData(first) as Data),
      leaf.matches(target.host), policy.authority || leaf.der == anchor,
      chain.allSatisfy({
        (try? PrivateCertificate(SecCertificateCopyData($0) as Data).valid()) == true
      })
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(trust: trust))
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    urlSession(session, didReceive: challenge, completionHandler: completionHandler)
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard !denyRedirect, let original = task.originalRequest,
      let a = original.url, let b = request.url,
      SelfHostedServiceURL.allowsReadRedirect(method: original.httpMethod ?? "GET", from: a, to: b)
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
struct PrivateTrustPanel: View {
  let origin: PrivateServiceOrigin
  @State private var current: Data?
  @State private var pending: Data?
  @State private var importing = false
  @State private var removing = false
  @State private var issue: String?
  var body: some View {
    Form {
      LabeledContent("服务器", value: origin.display)
      if let current {
        group(current, label: "已信任的证书")
        Button("移除证书", role: .destructive) { removing = true }
      }
      Button(current == nil ? "选择证书" : "选择新证书") { importing = true }
      if let pending {
        group(pending, label: "待导入证书")
        Button("为这个服务器信任证书") {
          do {
            try PrivateServerTrust.set(pending, for: origin)
            current = pending
            self.pending = nil
            issue = nil
          } catch { issue = error.localizedDescription }
        }
        Button("取消导入") { self.pending = nil }
      }
      if let issue { Text(issue).foregroundStyle(.secondary) }
    }.navigationTitle("服务器证书").onAppear {
      do { current = try PrivateServerTrust.read(origin) } catch {
        issue = error.localizedDescription
      }
    }
    .confirmationDialog("移除此服务器的自定义证书？", isPresented: $removing) {
      Button("移除", role: .destructive) {
        do {
          try PrivateServerTrust.set(nil, for: origin)
          current = nil
          issue = nil
        } catch { issue = error.localizedDescription }
      }
    }.fileImporter(isPresented: $importing, allowedContentTypes: [.x509Certificate, .data]) {
      result in
      do {
        let url = try result.get()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
          size <= 128 * 1024
        else { throw ServiceError("请选择单个证书文件") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let c = try PrivateServerTrust.validate(
          try file.read(upToCount: 128 * 1024 + 1) ?? Data(), for: origin)
        pending = c.der
        issue = nil
      } catch {
        if (error as NSError).code != NSUserCancelledError { issue = error.localizedDescription }
      }
    }
  }
  @ViewBuilder private func group(_ data: Data, label: String) -> some View {
    Section(label) {
      if let c = try? PrivateCertificate(data) {
        LabeledContent("类型", value: c.authority ? "证书颁发机构" : "服务器证书")
        LabeledContent("有效期至", value: c.after.formatted(date: .abbreviated, time: .omitted))
      }
      Text("SHA-256").font(.caption)
      Text(PrivateServerTrust.fingerprint(data)).font(.caption.monospaced()).textSelection(.enabled)
    }
  }
}
