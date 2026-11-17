import SwiftUI

struct OfflinePlayingList:View{
  let rows:[OfflineVideo],current:String,choose:(OfflineVideo)->Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts:AccountContext
  var body:some View{
    PiliNavigationStack{
      ScrollViewReader{reader in
        List{
          ForEach(rows.filter{$0.phase == .saved && $0.matchesOwner(accounts.state.owner(.role(.video)) ?? "")},id:\.token){row in
            Button{
              dismiss();if row.token != current{choose(row)}
            }label:{
              HStack{OfflineCoverCell(row:row)
                VStack(alignment:.leading,spacing:4){Text(row.title).lineLimit(2)
                  if !row.part.isEmpty,row.part != row.title{Text(row.part).font(.caption).foregroundStyle(.secondary)}
                  OfflineReceiptLine(row:row)
                }
                Spacer();if row.token==current{Image(systemName:"speaker.wave.2.fill").accessibilityLabel("正在播放")}
              }
            }.buttonStyle(.plain).id(row.token)
          }
        }.onAppear{reader.scrollTo(current,anchor:.center)}
      }.navigationTitle("缓存列表").toolbar{Button("完成"){dismiss()}}
    }
  }
}
