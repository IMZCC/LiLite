import Foundation

/// Reads only the regular playurl result for the selected video identity.
struct ArchiveStreamGrant: Decodable {
  static let guestHD = "play.guestPublicHD"
  static var prefersGuestHD: Bool { UserDefaults.standard.object(forKey: guestHD) as? Bool ?? true }
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
    // Ignore menu-only upgrades. A variant still must have a playable URL in this response.
    return !(support_formats ?? []).contains { $0.quality == q && ($0.need_login?.on == true || $0.need_vip?.on == true) }
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
