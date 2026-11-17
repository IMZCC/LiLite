import Foundation

enum OfflineShelfFilter {
  static func rows(_ rows: [OfflineVideo], search: String, shelf: Int, owner: String)
    -> [OfflineVideo]
  {
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return rows.filter { v in
      guard v.visible(to: owner) else { return false }
      if shelf == 2 && v.phase == .saved { return false }
      if (shelf == 1 || (shelf == 0 && !term.isEmpty)) && v.phase != .saved { return false }
      return term.isEmpty
        || [v.title, v.part, v.bvid, String(v.cid), v.uploader ?? "", v.collectionTitle ?? ""]
          .contains { $0.localizedCaseInsensitiveContains(term) }
    }
  }
}
