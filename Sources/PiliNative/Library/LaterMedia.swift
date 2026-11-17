import Foundation

struct LaterMedia: Decodable, Identifiable {
  struct Bangumi: Decodable { let ep_id: Int64? }
  struct Rights: Decodable { let is_cooperation: Int? }
  struct Charge: Decodable { let level: Int? }
  let aid: Int64?, bvid: String?, cid: Int64?, title: String?, pic: String?, subtitle: String?,
    duration: Int?, progress: Int?, state: Int?
  let is_pgc: Bool?, is_pugv: Bool?, bangumi: Bangumi?, redirect_url: String?, pgc_label: String?,
    charging_pay: Charge?, owner: Video.Owner?, rights: Rights?
  var stat: Video.Stat? = nil
  var pubdate: Int64? = nil
  var resource: Int64? {
    if let aid, aid > 0 { return aid }
    return bvid.flatMap(ArchiveNumber.av)
  }
  var id: String {
    if let ep = bangumi?.ep_id, ep > 0 { return "ep:" + String(ep) }
    if let bvid, !bvid.isEmpty { return bvid }
    return resource.map { "av:" + String($0) } ?? ""
  }
  var route: SharedLink? {
    guard state.map({ $0 >= 0 }) ?? true else { return nil }
    if is_pugv == true { return resource.map { .course($0, false) } }
    if is_pgc == true || bangumi?.ep_id != nil {
      if let episode = bangumi?.ep_id, episode > 0 { return .episode(episode) }
      guard let raw = redirect_url else { return nil }
      switch SharedLink.parse(raw) {
      case .episode(let e): return .episode(e)
      case .season(let s): return .season(s)
      default: return nil
      }
    }
    if let bvid, case .video? = SharedLink.parse(bvid) { return .video(bvid, nil) }
    return resource.flatMap(ArchiveNumber.bv).map { .video($0, nil) }
  }
  var cover: URL? { pic.flatMap(httpsURL) }
  var name: String {
    if let title, !title.isEmpty { return title }
    return "已失效的视频"
  }
  var badge: String? {
    if state.map({ $0 < 0 }) == true { return "已失效" }
    if charging_pay?.level != nil { return "充电专属" }
    if rights?.is_cooperation == 1 { return "合作" }
    if let pgc_label, !pgc_label.isEmpty { return pgc_label }
    if is_pugv == true { return "课堂" }
    return nil
  }
  var progressText: String? {
    guard let progress, progress != 0 else { return nil }
    if progress == -1 { return "已看完" }
    guard progress > 0 else { return nil }
    return "已看 " + clockText(Double(progress))
  }
  var caption: String {
    [badge, progressText, owner?.name, subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(
      separator: " · ")
  }
}
