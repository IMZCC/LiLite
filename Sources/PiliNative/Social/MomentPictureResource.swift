import SwiftUI

/// Pinned rich picture nodes carry either their pictures or an independent picture resource identifier.
struct DynamicRichContent: View {
  let nodes: [RichNode], maxLines: Int, permitsPreview: Bool, dynamicID: String
  private enum Segment {
    case text([RichNode])
    case images([GalleryPicture])
  }
  private var segments: [Segment] {
    var out = [Segment]()
    var run = [RichNode]()
    for node in nodes {
      if case .gallery(let images) = node.target {
        if !run.isEmpty {
          out.append(.text(run))
          run = []
        }
        out.append(.images(images))
      } else {
        run.append(node)
      }
    }
    if !run.isEmpty { out.append(.text(run)) }
    return out
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .text(let part):
          ReplyRichText(
            nodes: part, maxLines: maxLines, permitsPreview: permitsPreview, dynamicID: dynamicID)
        case .images(let pics):
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 4)], spacing: 4) {
            ForEach(pics.indices, id: \.self) { i in
              GalleryLink(pics, index: i) {
                GalleryThumb(photo: pics[i]).aspectRatio(1, contentMode: .fit).clipped()
              }
            }
          }
        }
      }
    }
  }
}
private actor MomentPictureMemo {
  static let shared = MomentPictureMemo()
  struct Key: Hashable { let actor: String, id: String }
  private var pages = [Key: [GalleryPicture]](), recent = [Key]()
  func cached(_ key: Key) -> [GalleryPicture]? {
    guard let p = pages[key] else { return nil }
    recent.removeAll { $0 == key }
    recent.append(key)
    return p
  }
  func put(_ list: [GalleryPicture], _ key: Key) {
    guard !list.isEmpty else { return }
    recent.removeAll { $0 == key }
    recent.append(key)
    pages[key] = list
    if recent.count > 48 { pages[recent.removeFirst()] = nil }
  }
}
struct MomentPictureResource: View {
  let id: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var selected: [GalleryPicture]?
  @State private var issue: String?
  @State private var retry = 0
  var body: some View {
    Group {
      if let pics = selected, !pics.isEmpty {
        NativeGallery(pics)
      } else if let issue {
        ContentUnavailableView {
          Label("无法查看图片", systemImage: "photo")
        } description: {
          Text(issue)
        } actions: {
          Button("重试") { retry += 1 }
        }
      } else if selected != nil {
        ContentUnavailableView("暂无图片", systemImage: "photo")
      } else {
        ProgressView()
      }
    }.navigationTitle("查看图片")
      .task(id: "\(id):\(accounts.state.active ?? ""):\(retry)") {
        let uid = accounts.state.active ?? ""
        let key = MomentPictureMemo.Key(actor: uid, id: id)
        selected = nil
        issue = nil
        do {
          guard let n = UInt64(id), n > 0, String(n) == id else { throw ServiceError("图片编号无效") }
          if let hit = await MomentPictureMemo.shared.cached(key) {
            try Task.checkCancellation()
            selected = hit
            return
          }
          let data = try await BiliAPI.shared.fetch(
            "/x/polymer/web-dynamic/v1/detail/pic", ["id": id, "web_location": "333.1368"],
            host: "api.bilibili.com", expectedAccount: uid)
          try Task.checkCancellation()
          guard (accounts.state.active ?? "") == uid else { return }
          let pics = try MomentPictureReply.photos(data)
          selected = pics
          await MomentPictureMemo.shared.put(pics, key)
        } catch {
          if !Task.isCancelled && (accounts.state.active ?? "") == uid {
            issue = error.localizedDescription
          }
        }
      }
  }
}
