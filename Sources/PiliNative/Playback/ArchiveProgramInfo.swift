import AVFoundation
import CoreMedia
import SwiftUI

struct ArchiveProgramInfo:View {
  let player:any PlaybackEngine
  var model:PlayerModel?
  @State private var current:AnyObject?
  @State private var tracks:[String]=[]
  var body:some View{
    Form{
      if let m=model{
        Section("来源"){
          LabeledContent("画质",value:StreamQuality.name(m.quality))
          if let video=m.selectedVideoStream{
            LabeledContent("视频编码",value:video.codecs)
            if let fps=video.frameRate{LabeledContent("源帧率",value:fps.formatted()+" fps")}
            if video.bandwidth>0{LabeledContent("视频码率",value:String(video.bandwidth/1000)+" kbps")}
          }
          if let audio=m.selectedAudioStream{LabeledContent("音频编码",value:audio.codecs)}
          if let name=m.spokenTracks.first(where:{$0.id==m.spokenLanguage})?.label{LabeledContent("音轨",value:name)}
          LabeledContent("解码路线",value:m.decoderName)
        }
      }
      if let current{
        Section("播放状态"){
          TimelineView(.periodic(from:.now,by:1)){ _ in
            VStack(alignment:.leading,spacing:8){
              LabeledContent("状态",value:player.timeControlStatus == .playing ? "播放中":player.timeControlStatus == .paused ? "已暂停":"缓冲中")
              let size=player.playbackSize
              if size.width.isFinite,size.height.isFinite,size.width>0,size.height>0{LabeledContent("画面尺寸",value:"\(Int(size.width)) × \(Int(size.height))")}
              let t=player.currentTime().seconds,d=player.playbackDuration
              if t.isFinite,d.isFinite{LabeledContent("进度",value:clockText(t)+" / "+clockText(d))}
              LabeledContent("速度",value:player.defaultRate.formatted()+"×")
              LabeledContent("音量",value:player.isMuted ? "静音":String(Int(player.presentationVolume*100))+"%")
              if let log=(current as? AVPlayerItem)?.accessLog()?.events.last{
                if log.observedBitrate.isFinite,log.observedBitrate>0{LabeledContent("实测码率",value:"\(Int(log.observedBitrate/1000)) kbps")}
                if log.numberOfStalls>=0{LabeledContent("缓冲次数",value:String(log.numberOfStalls))}
                if log.numberOfDroppedVideoFrames>=0{LabeledContent("丢帧",value:String(log.numberOfDroppedVideoFrames))}
              }
            }
          }
        }
      }
      if !tracks.isEmpty{Section("输出轨道"){ForEach(Array(tracks.enumerated()),id:\.offset){_,line in Text(line).textSelection(.enabled)}}}
    }.navigationTitle("播放信息")
    .onReceive(player.itemPublisher){current=$0}
    .task(id:current.map(ObjectIdentifier.init)){
      tracks=[];guard let item=current as? AVPlayerItem,let streams=try? await item.asset.load(.tracks) else{return}
      var result=[String]()
      for track in streams.prefix(16){
        let kind=track.mediaType
        guard kind == .audio || kind == .video,let desc=try? await track.load(.formatDescriptions).first else{continue}
        let c=CMFormatDescriptionGetMediaSubType(desc),bytes=[24,16,8,0].map{UInt8(truncatingIfNeeded:c>>$0)}
        let codec=bytes.allSatisfy{(32...126).contains($0)} ? String(decoding:bytes,as:UTF8.self).trimmingCharacters(in:.whitespaces):String(format:"%08X",c)
        var line=(kind == .video ? "视频 ":"音频 ")+codec
        if kind == .audio,let info=CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee{line+=" · \(Int(info.mSampleRate)) Hz · \(info.mChannelsPerFrame) 声道"}
        result.append(line)
      }
      if !Task.isCancelled,item===player.playbackItem{tracks=result}
    }
  }
}
struct ArchiveSourceTools:View{
  @ObservedObject var model:PlayerModel
  var body:some View{
    NavigationLink("播放信息"){ArchiveProgramInfo(player:model.engine,model:model)}
    if let grant=model.addressGrant{NavigationLink("播放地址"){ArchiveSourceEditor(model:model,grant:grant)}}
    Button("重载视频"){Task{await model.reloadPlayback()}}.disabled(model.switching || model.timeline.source==nil)
  }
}
