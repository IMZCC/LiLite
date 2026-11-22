import SwiftUI

extension BiliAPI {
  func defaultSearchWord(owner:String?=nil) async throws -> String {
    struct Response: Decodable { let name: String? }
    let r = try await read(
      "/x/web-interface/wbi/search/default", try await sign(["web_location": "333.1365"]),
      expectedAccount:owner,as: Response.self)
    return (r.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }
  func onlineCount(_ source: TimelineSource,owner:String?=nil) async throws -> String? {
    struct Response: Decodable {
      let total: String?
      enum K: String, CodingKey { case total }
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if let s = try? c.decode(String.self, forKey: .total) {
          total = s
        } else {
          total = (try? c.decode(Int.self, forKey: .total)).map(String.init)
        }
      }
    }
    var q = ["cid": String(source.cid)]
    q["aid"] = source.aid.map(String.init)
    q["bvid"] = source.bvid
    return try await read("/x/player/online/total",q,expectedAccount:owner,as:Response.self).total
  }
}
struct OnlineViewers: View {
  @ObservedObject var timeline: TimelineState
  var fallback:TimelineSource?=nil
  /// The official counts line's "N人正在看", in the line's own font and colour.
  var inline = false
  @Environment(\.scenePhase) private var scene
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("detail.online") private var enabled = false
  @State private var count: String?
  private struct Key: Hashable { let on: Bool, source: TimelineSource?, uid: String? }
  var body: some View {
    let key = Key(
      on: enabled && scene == .active, source:fallback ?? timeline.source, uid: accounts.state.owner(.role(.heartbeat)))
    VStack(alignment: .leading, spacing: 0) {
      if enabled, let count, !count.isEmpty {
        if inline {
          HStack(spacing: OfficialIntro.d(3)) {
            Image(systemName: "person.2").officialSymbol(11)
            Text(count + "人正在看")
          }
        } else {
          Label(count + " 人正在观看", systemImage: "eye").piliFont(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .task(id: key) {
      count = nil
      guard key.on,let source=key.source else{return}
      while !Task.isCancelled{
        if let value=try? await BiliAPI.shared.onlineCount(source,owner:key.uid ?? ""),!Task.isCancelled {count=value}
        do{try await Task.sleep(for:.seconds(10))}catch{return}
      }
    }
  }
}
