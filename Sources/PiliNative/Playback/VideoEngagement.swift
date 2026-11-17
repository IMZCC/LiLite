import Foundation

/// The episode service encodes flags as integers and the archive service uses booleans.
struct VideoEngagement: Decodable, Equatable {
  var liked = false, disliked = false, starred = false, coins = 0
  var contributed: Bool { coins > 0 }
  var complete: Bool { liked && starred && contributed }
  init() {}
  enum Keys: String, CodingKey { case like, dislike, favorite, fav, coin, coin_number, multiply }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    func n(_ key: Keys) -> Int? {
      if let i = try? c.decode(Int.self, forKey: key) { return i }
      return (try? c.decode(Bool.self, forKey: key)).map { $0 ? 1 : 0 }
    }
    liked = (n(.like) ?? 0) > 0
    disliked = !liked && (n(.dislike) ?? 0) > 0
    starred = (n(.favorite) ?? n(.fav) ?? 0) > 0
    coins = max(0, n(.coin_number) ?? n(.multiply) ?? n(.coin) ?? 0)
  }
  mutating func addTriple(_ r: Self) {
    liked = liked || r.liked
    if liked { disliked=false }
    starred = starred || r.starred
    coins = max(coins, r.coins)
  }
}
struct EngagementItem: Equatable {
  let bvid: String, aid: Int64?, episode: Int64?, copyright: Int?
  var key: String { "\(episode ?? 0):" + bvid }
  var rid: Int64? { episode ?? aid }
  var type: Int { episode == nil ? 2 : 24 }
  var maxCoins: Int { copyright == 2 ? 1 : 2 }
}
