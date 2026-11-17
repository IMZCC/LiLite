import Foundation

public struct ArchiveAccount: Codable {
  public var cookies: [String: String], accessKey: String?, refresh: String?, buvid: String?,
    type: [Int]?, piliNativeLabel: String?
  public init(
    cookies: [String: String], accessKey: String?, refresh: String?, buvid: String?, type: [Int],
    label: String?
  ) {
    self.cookies = cookies
    self.accessKey = accessKey
    self.refresh = refresh
    self.buvid = buvid
    self.type = type
    self.piliNativeLabel = label
  }
  /// An extension can describe "follow main" versus an explicitly pinned uid, but cannot
  /// grant any role to a different account than the original account.json records.
  public static func validateRoles(_ choices: [String: String]?, accounts: [String: Self]) throws {
    guard let choices else { return }
    guard Set(choices.keys) == ["0", "1", "2", "3"], choices["0"] != "$main",
      choices.values.allSatisfy({ $0 == "" || $0 == "$main" || accounts[$0] != nil })
    else { throw ArchiveIssue("账号角色无效") }
    for role in 0...3 {
      let choice = choices[String(role)]!
      let owner = choice == "$main" ? choices["0"]! : choice
      guard (accounts.first { $0.value.type?.contains(role) == true }?.key ?? "") == owner else {
        throw ArchiveIssue("账号角色与归档不一致")
      }
    }
  }
  public static func decode(_ data: Data) throws -> [String: Self] {
    let accounts = try JSONDecoder().decode([String: Self].self, from: data)
    guard accounts.count <= 256 else { throw ArchiveIssue("数据包中的账号过多") }
    let allowed = Set(
      "!#$%&'*+-.^_\u{60}|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    var usedRoles = Set<Int>()
    for (mid, a) in accounts {
      let roles = a.type ?? []
      guard let id = Int64(mid), id > 0, String(id) == mid, a.cookies["DedeUserID"] == mid,
        a.cookies["SESSDATA"]?.isEmpty == false, a.cookies["bili_jct"]?.isEmpty == false,
        a.cookies.count <= 128,
        a.cookies.allSatisfy({ k, v in
          !k.isEmpty && k.utf8.count <= 128 && k.utf8.allSatisfy(allowed.contains)
            && v.utf8.count <= 16384
            && v.utf8.allSatisfy { $0 >= 33 && $0 <= 126 && $0 != 59 && $0 != 34 && $0 != 92 }
        }),
        [a.refresh, a.accessKey, a.buvid].compactMap({ $0 }).allSatisfy({ s in
          s.utf8.count <= 8192 && s.rangeOfCharacter(from: .controlCharacters) == nil
        }),
        (a.piliNativeLabel?.count ?? 0) <= 256, roles.allSatisfy((0...3).contains),
        Set(roles).count == roles.count,
        usedRoles.isDisjoint(with: roles)
      else { throw ArchiveIssue("数据包中有无效的账号记录") }
      usedRoles.formUnion(roles)
    }
    return accounts
  }
}
