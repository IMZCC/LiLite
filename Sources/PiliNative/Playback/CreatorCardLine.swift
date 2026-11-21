import SwiftUI

/// A creator's fans, videos and 大会员 for the video page's owner row (IntroOwnerRow), read once
/// per creator from the card service and kept for the session.
struct CreatorCardSummary: Decodable, Sendable {
  let fans: Int?, videos: Int?, annualVIP: Bool
  @MainActor static var cached: [Int64: CreatorCardSummary] = [:]
  var line: String {
    var parts: [String] = []
    if let fans { parts.append(fans.formatted(.number.notation(.compactName)) + "粉丝") }
    if let videos { parts.append(videos.formatted(.number.notation(.compactName)) + "视频") }
    return parts.joined(separator: "  ")
  }
  private enum Keys: String, CodingKey { case card, follower, archive_count }
  private struct Card: Decodable {
    struct VIP: Decodable { let type: Int?, status: Int?, vipType: Int?, vipStatus: Int? }
    let fans: Int?
    let vip: VIP?
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    let card = try? c.decodeIfPresent(Card.self, forKey: .card)
    fans = (try? c.decodeIfPresent(Int.self, forKey: .follower)) ?? card?.fans
    videos = try? c.decodeIfPresent(Int.self, forKey: .archive_count)
    let vip = card?.vip
    annualVIP = (vip?.status ?? vip?.vipStatus) == 1 && (vip?.type ?? vip?.vipType) == 2
  }
  @MainActor static func load(_ mid: Int64, owner: String?) async throws -> CreatorCardSummary {
    let summary = try await BiliAPI.shared.read(
      "/x/web-interface/card", ["mid": String(mid), "photo": "false"],
      expectedAccount: owner ?? "", as: CreatorCardSummary.self)
    if cached.count > 200 { cached.removeAll() }
    cached[mid] = summary
    return summary
  }
}
