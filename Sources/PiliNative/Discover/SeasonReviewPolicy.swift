import Foundation

struct SeasonReview: Decodable, Identifiable {
  struct Author: Decodable { let mid: Int64?, uname: String?, level: Int?, avatar: String? }
  struct Stat: Decodable { let likes: Int?, liked: Int?, disliked: Int? }
  let review_id: Int64?, article_id: Int64?, author: Author?, stat: Stat?, title: String?,
    content: String?, score: Int?, push_time_str: String?
  var id: Int64 { review_id ?? article_id ?? 0 }
  var stars: Int { min(5, max(0, (score ?? 0) / 2)) }
}
enum SeasonReviewPolicy {
  static func post(
    media: Int64, stars: Int, body: String, share: Bool, editing: SeasonReview?, owner: String
  ) -> [String: String]? {
    guard media > 0, (1...5).contains(stars), body.count <= 100, !owner.isEmpty else { return nil }
    var fields = ["media_id": String(media), "score": String(stars * 2), "content": body]
    if let editing {
      guard let n = editing.review_id, n > 0, editing.author?.mid.map(String.init) == owner else {
        return nil
      }
      fields["review_id"] = String(n)
    } else if share {
      fields["share_feed"] = "1"
    }
    return fields
  }
  static func report(_ review: Int64, media: Int64) -> URL? {
    guard review > 0, media > 0 else { return nil }
    var c = URLComponents(string: "https://www.bilibili.com/appeal/")!
    c.queryItems = [
      .init(name: "reviewId", value: String(review)), .init(name: "type", value: "shortComment"),
      .init(name: "mediaId", value: String(media)),
    ]
    return c.url
  }
  static func longEditor(media: Int64, dark: Bool) -> URL? {
    guard media > 0 else { return nil }
    var c = URLComponents(string: "https://member.bilibili.com/article-text/mobile")!
    c.queryItems = [
      .init(name: "theme", value: dark ? "1" : "0"), .init(name: "media_id", value: String(media)),
    ]
    return c.url
  }
}
