import SwiftUI

/// The video page's creator, as the original draws it: the name (pink for 大会员) over
/// "3.3万粉丝  540视频". The counts are read once per creator from the card service and kept for
/// the session.
struct CreatorCardLine: View {
  let mid: Int64?
  let name: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var card: CreatorCardSummary?
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
        .foregroundStyle(card?.annualVIP == true ? Color.pink : Color.primary)
      if let card, !card.line.isEmpty {
        Text(card.line).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.2), value: card?.line)
    .task(id: mid) {
      guard let mid, mid > 0 else { card = nil; return }
      card = CreatorCardSummary.cached[mid]
      guard card == nil else { return }
      if let loaded = try? await CreatorCardSummary.load(mid, owner: accounts.state.active), !Task.isCancelled {
        card = loaded
      }
    }
  }
}

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
