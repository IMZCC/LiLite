import Foundation

/// Site responses use both JSON integers and decimal strings for the same 64-bit ID.
struct ServiceID: Decodable {
  let number: Int64?
  init(_ number: Int64) { self.number = number }
  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if let n = try? c.decode(Int64.self) {
      number = n
    } else if let text = try? c.decode(String.self), !text.isEmpty,
      text.utf8.allSatisfy({ (48...57).contains($0) })
    {
      number = Int64(text)
    } else {
      number = nil
    }
  }
}
