import SwiftUI

struct SponsorSourceSheet: View {
  let source:SponsorSource
  @AppStorage("sponsor.server") private var server = "https://www.bsbsb.top"
  @AppStorage("sponsor.enabled") private var enabled = false
  @Environment(\.dismiss) private var dismiss
  @State private var verified = false
  @State private var current:String?
  @State private var busy=false
  @State private var issue:String?
  @State private var confirm=false
  @State private var refresh=0
  var body:some View {
    PiliNavigationStack { Form {
      LabeledContent("YouTube 视频",value:source.youtube)
      NavigationLink("打开原视频"){SitePage(url:source.original)}
      if verified {
        if current == source.youtube {Label("已绑定这个原视频",systemImage:"checkmark.circle")}
        else {
          if let current {LabeledContent("现有绑定",value:current)}
          Button(current == nil ? "绑定原视频":"更换原视频"){confirm=true}.disabled(!enabled || busy)
        }
      } else if issue == nil {ProgressView("读取绑定信息")}
      if let issue { Text(issue).foregroundStyle(.secondary); Button("重新读取"){refresh += 1}.disabled(busy) }
    }.navigationTitle("空降标记同步").toolbar{Button("完成"){dismiss()}}
      .task(id:"\(source.id):\(server):\(enabled):\(refresh)") {
        let address=server; verified=false;current=nil;issue=nil
        guard enabled else{dismiss();return}
        do {let res=try await SponsorAPI(address).originVideo(source)
          try Task.checkCancellation();guard address==server && enabled else{return}
          current=res;verified=true
        } catch {if !Task.isCancelled, address==server {issue=error.localizedDescription}}
      }
      .confirmationDialog(current == nil ? "将这条分 P 绑定到原视频？":"将这条分 P 的绑定更换为此原视频？",isPresented:$confirm,titleVisibility:.visible){
        Button("确认绑定"){let address=server;Task {await publish(address)}}
        Button("取消",role:.cancel){}
      }
    }
  }
  @MainActor private func publish(_ address:String) async {
    guard enabled, verified, current != source.youtube, !busy,address==server else{return}
    busy=true;defer{busy=false}
    do {try await SponsorAPI(address).linkOrigin(source)
      if address==server, enabled {current=source.youtube;issue=nil}
    } catch {if address==server {issue=error.localizedDescription}}
  }
}
