import Foundation

struct TypefaceChoice: Codable, Equatable {
  var name = "", file = "", weight = 4, scale = 1.0
  static let key = "appearance.typeface"
  static var standard: Self { .init() }
  func validate() throws {
    guard (1...9).contains(weight), (0.85...1.6).contains(scale), name.count <= 180,
      file.isEmpty
        || (file.range(of: "^[0-9a-f]{64}\\.(?:ttf|ttc|otf)\\z", options: .regularExpression) != nil
          && !name.isEmpty)
    else { throw ServiceError("字体设置无效") }
  }
  private static let decoded = DecodedSettingCache<Self>()
  static func decode(_ data: Data) -> Self {
    decoded.value(for: data) { bytes in
      guard let s = try? JSONDecoder().decode(Self.self, from: bytes), (try? s.validate()) != nil
      else { return .standard }
      return s
    }
  }
  static func current(_ d: UserDefaults) -> Self { decode(d.data(forKey: key) ?? Data()) }
  func encoded() throws -> Data {
    try validate()
    return try JSONEncoder().encode(self)
  }
}
