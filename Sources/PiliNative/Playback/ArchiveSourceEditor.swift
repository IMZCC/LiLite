import AVFoundation
import AVKit
import SwiftUI

private struct SeparateMedia:Identifiable{let id=UUID(),video:URL,audio:URL?,owner:String}
private struct IndependentMovie:View {
  let media:SeparateMedia
  @State private var player:AVPlayer?
  @State private var bridge:DashBridge?
  @State private var issue:String?
  @Environment(\.dismiss) private var dismiss
  var body:some View{
    PiliNavigationStack{
      Group{
        if let issue{ContentUnavailableView(issue,systemImage:"play.slash")}
        else if let player,let item=player.currentItem{VideoPlayer(player:player)
          .onReceive(item.publisher(for:\.status)){status in if status == .failed{issue="这个媒体地址暂时无法播放";player.pause()}}
        }
        else{ProgressView("正在打开媒体")}
      }.navigationTitle("媒体播放").navigationBarTitleDisplayMode(.inline).toolbar{Button("关闭"){dismiss()}}
    }.task(id:media.id){
      do{
        if !DecoderPreference.allowsSystemFallback{
          let result=try await ProgressiveDecoderBridge.independent(media.video,audio:media.audio,owner:media.owner)
          guard !Task.isCancelled else{result.bridge.close();return}
          bridge=result.bridge;let p=AVPlayer(url:result.url);player=p;p.play();return
        }
        let opts:[String:Any]=[AVURLAssetHTTPCookiesKey:[HTTPCookie]()]
        let video=AVURLAsset(url:media.video,options:opts)
        MediaCertificatePolicy.apply(to:video)
        guard try await !video.load(.hasProtectedContent) else{throw ServiceError("此媒体需要服务提供方授权")}
        let asset:AVAsset
        if let url=media.audio{
          let audio=AVURLAsset(url:url,options:opts)
          MediaCertificatePolicy.apply(to:audio)
          guard try await !audio.load(.hasProtectedContent),
            let v=try await video.loadTracks(withMediaType:.video).first,
            let a=try await audio.loadTracks(withMediaType:.audio).first else{throw ServiceError("无法读取指定音视频轨道")}
          let vr=try await v.load(.timeRange),ar=try await a.load(.timeRange)
          let length=CMTimeMinimum(vr.duration,ar.duration)
          guard length.isNumeric,length.seconds>0 else{throw ServiceError("这两个地址无法同步播放")}
          let mix=AVMutableComposition()
          guard let vt=mix.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid),
            let at=mix.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else{throw ServiceError("无法建立音视频轨道")}
          try vt.insertTimeRange(.init(start:vr.start,duration:length),of:v,at:.zero)
          try at.insertTimeRange(.init(start:ar.start,duration:length),of:a,at:.zero)
          vt.preferredTransform=try await v.load(.preferredTransform);asset=mix
        }else{asset=video}
        try Task.checkCancellation()
        let item=AVPlayerItem(asset:asset)
        let p=AVPlayer(playerItem:item);ItemAudioGain.attach(item);player=p;p.play()
      }catch{if !Task.isCancelled{issue=(error as? ServiceError)?.localizedDescription ?? "暂时无法播放这个媒体地址"}}
    }.onDisappear{player?.pause();player?.replaceCurrentItem(with:nil);player=nil;bridge?.close();bridge=nil}
  }
}
struct ArchiveSourceEditor:View{
  @ObservedObject var model:PlayerModel
  let grant:ArchiveAddressGrant
  @State private var picture:String
  @State private var sound:String
  @State private var issue:String?
  @State private var busy=false
  @State private var media:SeparateMedia?
  @State private var paused:AnyObject?
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts:AccountContext
  init(model:PlayerModel,grant:ArchiveAddressGrant){
    self.model=model;self.grant=grant;_picture=State(initialValue:grant.picture.first?.absoluteString ?? "");_sound=State(initialValue:grant.sound.first?.absoluteString ?? "")
  }
  var body:some View{
    Form{
      field("视频地址",$picture,grant.picture)
      field("音频地址",$sound,grant.sound)
      if let issue{Text(issue).foregroundStyle(.secondary)}
      Button("播放"){
        guard !busy,model.addressGrant?.key==grant.key else{return}
        busy=true;issue=nil
        Task{@MainActor in defer{busy=false}
          do{
            switch try grant.pick(video:picture,audio:sound){
            case .issued(let v,let a):try await model.useAddress(v,audio:a,grant:grant);dismiss()
            case .external(let v,let a):
              if model.playing,let item=model.engine.playbackItem{paused=item;model.engine.pause()}
              media = .init(video:v,audio:a,owner:grant.owner)
            }
          }catch{if !Task.isCancelled{issue=(error as? ServiceError)?.localizedDescription ?? "无法切换至所选地址"}}
        }
      }.disabled(busy || picture.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
    }.navigationTitle("播放地址")
    .onChange(of:accounts.state.owner(.role(.video)) ?? ""){_,_ in media=nil;paused=nil;dismiss()}
    .onChange(of:model.timeline.source?.cid){_,_ in media=nil;paused=nil;dismiss()}
    .piliFullScreenCover(item:$media,onDismiss:{
      if UIApplication.shared.applicationState == .active,let old=paused,old===model.engine.playbackItem,model.addressGrant?.key==grant.key{model.engine.playImmediately(atRate:model.rate)};paused=nil
    }){IndependentMovie(media:$0)}
  }
  private func field(_ label:String,_ value:Binding<String>,_ addresses:[URL])->some View{
    Section(label){
      TextField(label,text:value,axis:.vertical).font(.caption.monospaced()).textInputAutocapitalization(.never)
        .autocorrectionDisabled().keyboardType(.URL).lineLimit(1...3).privacySensitive()
      if !addresses.isEmpty{Menu("选择服务线路"){
        ForEach(Array(addresses.enumerated()),id:\.offset){i,url in Button("\(i+1) · "+(url.host ?? "线路")){value.wrappedValue=url.absoluteString}}
      }}
    }
  }
}
