import SwiftUI

struct LiveRoomHeader: Decodable {
  struct Room: Decodable { let title: String?, cover: String? }
  struct Anchor: Decodable {
    struct Info: Decodable { let uname: String?, face: String? }
    let base_info: Info?
  }
  struct Watched: Decodable { let text_large: String? }
  let room_info: Room?, anchor_info: Anchor?, watched_show: Watched?
}

struct LiveAnchorLine: View {
  let room: LiveRoomIdentity, info: LiveRoomHeader?, watched: String?
  var body: some View {
    HStack {
      NavigationLink {
        CreatorSpace(mid: room.uid, name: info?.anchor_info?.base_info?.uname ?? "主播")
      } label: {
        HStack {
          if let face = info?.anchor_info?.base_info?.face.flatMap(httpsURL) {
            SiteThumbnail(url: face) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
              .frame(width: 28,height: 28).clipShape(Circle())
          }
          Text(info?.anchor_info?.base_info?.uname ?? "主播主页").lineLimit(1)
        }
      }
      Spacer()
      if let value = watched ?? info?.watched_show?.text_large, !value.isEmpty {
        Text(value).font(.caption).foregroundStyle(.secondary)
      }
    }.padding(.horizontal)
  }
}
