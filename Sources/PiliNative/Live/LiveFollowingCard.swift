import SwiftUI

struct LiveFollowingCard: View {
  let room: LiveFollowPage.Row
  @State private var showCover = false
  var body: some View {
    let cover = room.room_cover.flatMap(GalleryPicture.source)
    NavigationLink {
      LivePlayer(id:room.id,title:room.title ?? "直播间")
    } label: {
      VStack(alignment:.leading,spacing:5) {
        Rectangle().fill(.quaternary).aspectRatio(16/9,contentMode:.fit).overlay {
          SiteThumbnail(url:cover){$0.resizable().scaledToFill()} placeholder:{Color.clear}
        }.clipped().clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
        Text(room.title ?? "直播间").lineLimit(2)
        if let name = room.uname { Text(name).piliFont(.caption) }
        let subtitle = [room.area_name,room.text_small].compactMap{$0}.filter{!$0.isEmpty}.joined(separator:" · ")
        if !subtitle.isEmpty { Text(subtitle).lineLimit(1).font(.caption2).foregroundStyle(.secondary) }
      }
    }.contextMenu {
      if cover != nil {Button("查看封面"){showCover=true}}
    }.piliSheet(isPresented:$showCover){
      if let cover {PiliNavigationStack{NativeGallery([GalleryPicture(cover)],index:0).toolbar{Button("完成"){showCover=false}}}}
    }
  }
}
