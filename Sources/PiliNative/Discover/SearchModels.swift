import Foundation

struct SearchSuggestionsPayload: Decodable {
  struct Tags: Decodable {
    struct Tag: Decodable { let term: String? }
    let tag: [Tag]?
  }
  let result: Tags?
}
