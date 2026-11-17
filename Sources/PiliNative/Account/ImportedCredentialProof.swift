import Foundation

/// This metadata is local to Keychain and is never accepted from account.json.
/// A missing field means a previously verified local login, for backwards compatibility.
struct ImportedCredentialProof: Codable, Equatable {
  var web: Bool
  var mobile: Bool
  var ownerConfirmed: Bool? = nil
  static func restored(previous: Self?, sameWeb: Bool, sameMobile: Bool, knownOwner: Bool = false) -> Self {
    .init(web: sameWeb && (previous?.web ?? true), mobile: sameMobile && (previous?.mobile ?? true), ownerConfirmed:knownOwner)
  }
  var requiresValidation: Bool { !web || !mobile }
  func permitsLocal(hasMobile: Bool) -> Bool { ownerConfirmed ?? (web || (hasMobile && mobile)) }
  static func require(_ actual: String, owner: String) throws {
    guard actual == owner else { throw ServiceError("导入的登录信息与账号不匹配，请重新登录") }
  }
}

enum AccountCredentials { case web, mobile, both }

/// Collapse concurrent first-use reads; a stale response is never persisted into a new session.
actor ImportedCredentialChecks {
  static let shared = ImportedCredentialChecks()
  struct Request: Hashable { let owner: String, web: Bool, material: String }
  private var pending: [Request: (UUID, Task<String, Error>)] = [:]
  func validate(_ request: Request, probe: @escaping @Sendable () async throws -> String) async throws {
    let check: (UUID, Task<String, Error>)
    if let running = pending[request] { check = running }
    else {
      check = (UUID(), Task { try await probe() }); pending[request] = check
    }
    defer { if pending[request]?.0 == check.0 { pending[request] = nil } }
    let actual = try await check.1.value
    try Task.checkCancellation()
    try ImportedCredentialProof.require(actual, owner: request.owner)
  }
}
