import Foundation

/// Reads only the regular playurl result for the selected video identity.
struct ArchiveStreamGrant: Decodable {
  static let guestHD = "play.guestPublicHD"
  static var prefersGuestHD: Bool { UserDefaults.standard.object(forKey: guestHD) as? Bool ?? true }
  /// The original sends `try_look=1` for a signed-out video account with "免登录 1080P" on, which
  /// makes the service return its public 1080P stream.
  static func tryLook(guest: Bool) -> Bool { guest && prefersGuestHD }
  /// Fields the original adds to every playurl request: the browser risk-control markers and,
  /// for a guest, `try_look`.
  static func requestFields(guest: Bool) -> [String: String] {
    var f = [
      "gaia_source": "pre-load", "isGaiaAvoided": "true", "web_location": "1315873",
      "dm_img_list": "[]", "dm_img_str": randomToken(16, 64), "dm_cover_img_str": randomToken(32, 128),
      "dm_img_inter": #"{"ds":[],"wh":[0,0,0],"of":[0,0,0]}"#,
    ]
    if tryLook(guest: guest) { f["try_look"] = "1" }
    return f
  }
  /// Base64 of random printable bytes without its last two characters, as the original builds it
  /// (bytes 0x26...0x7e, so the value never contains `%`).
  private static func randomToken(_ lo: Int, _ hi: Int) -> String {
    let bytes = (0..<Int.random(in: lo...hi)).map { _ in UInt8.random(in: 0x26...0x7e) }
    return String(Data(bytes).base64EncodedString().dropLast(2))
  }
  private struct Flag: Decodable {
    let on: Bool
    init(from d: Decoder) throws {
      let c = try d.singleValueContainer()
      if let v = try? c.decode(Bool.self) { on = v }
      else if let v = try? c.decode(Int.self) { on = v != 0 }
      else if let v = try? c.decode(String.self), ["0","1","true","false"].contains(v.lowercased()) { on = ["1","true"].contains(v.lowercased()) }
      else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid media permission") }
    }
  }
  private struct Format: Decodable {
    let quality: Int
    let need_login: Flag?, need_vip: Flag?
  }
  private let support_formats: [Format]?
  private let is_preview: Flag?, is_drm: Flag?
  var preview: Bool { is_preview?.on == true }
  var protected: Bool { is_drm?.on == true }
  var permitsCache: Bool { !preview && !protected }
  var advertisedQualities: [Int] { (support_formats ?? []).map(\.quality) }
  func permits(_ q: Int, guest: Bool) -> Bool {
    guard guest else { return true }
    // With try_look the service hands a guest the login-only 1080P stream, as in the original;
    // member-only formats stay out.
    let loginUnlocked = Self.tryLook(guest: true)
    // Ignore menu-only upgrades. A variant still must have a playable URL in this response.
    return !(support_formats ?? []).contains {
      $0.quality == q && ((!loginUnlocked && $0.need_login?.on == true) || $0.need_vip?.on == true)
    }
  }
  static func automaticHD(_ options: [Int], guest: Bool, enabled: Bool, explicit: Bool) -> Int? {
    guest && enabled && !explicit && options.contains(80) ? 80 : nil
  }
}

struct ArchiveGrantResponse<Body: Decodable>: Decodable {
  let grant: ArchiveStreamGrant, body: Body
  init(from d: Decoder) throws {
    grant = try .init(from: d)
    body = try .init(from: d)
  }
}
