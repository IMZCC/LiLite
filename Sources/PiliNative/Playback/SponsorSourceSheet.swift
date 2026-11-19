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
      Section {
        LabeledContent {
          Text(source.youtube).font(.callout.monospaced()).textSelection(.enabled)
        } label: {
          SettingsRowLabel(title: "YouTube 视频", symbol: "play.rectangle.fill", color: .red)
        }
        NavigationLink { DeferredPage { SitePage(url: source.original) } } label: {
          SettingsRowLabel(title: "打开原视频", symbol: "safari", color: .blue)
        }
      } footer: {
        Text("绑定后，这条分 P 会使用原视频的空降标记")
      }
      Section {
        if verified {
          if current == source.youtube {
            Label("已绑定这个原视频", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
          } else {
            if let current {
              LabeledContent("现有绑定") { Text(current).font(.callout.monospaced()) }
            }
            Button(current == nil ? "绑定原视频" : "更换原视频") { confirm = true }.disabled(!enabled || busy)
          }
        } else if issue == nil {
          HStack { ProgressView(); Text("读取绑定信息").foregroundStyle(.secondary) }
        }
        if let issue {
          Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
          Button("重新读取") { refresh += 1 }.disabled(busy)
        }
      } header: {
        Text("绑定状态")
      }
    }.navigationTitle("空降标记同步").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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
