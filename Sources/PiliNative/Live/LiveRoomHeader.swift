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
