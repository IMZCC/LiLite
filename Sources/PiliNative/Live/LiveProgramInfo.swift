import AVFoundation
import SwiftUI

struct LiveStartedLabel: View {
  let timestamp: Int64?
  var body: some View {
    if let timestamp, timestamp > 0, Double(timestamp) <= Date().timeIntervalSince1970 {
      let start = Date(timeIntervalSince1970: Double(timestamp))
      TimelineView(.periodic(from:.now,by:60)) { tick in
        let mins = max(0,Int(tick.date.timeIntervalSince(start)/60))
        Text(mins == 0 ? "刚刚开播" : mins < 60 ? "已播 \(mins) 分钟" : "已播 \(mins/60) 小时 \(mins%60) 分钟")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct LiveProgramInfo: View {
  @ObservedObject var transport: NativeLivePlayback
  let started: Int64?, audioOnly: Bool
  var body: some View {
    Form {
      Section("直播") {
        LabeledContent("模式",value:audioOnly ? "仅音频":"音视频")
        if let f = transport.format { LabeledContent("格式",value:f.label) }
        if let host = transport.currentHost { LabeledContent("线路",value:host) }
        if let track = transport.selectedAudio { LabeledContent("音轨",value:track.title) }
        LiveStartedLabel(timestamp:started)
      }
      if let player = transport.player, let item = player.currentItem {
        Section("播放状态") {
          TimelineView(.periodic(from:.now,by:2)) { _ in
            VStack(alignment:.leading,spacing:8) {
              LabeledContent("状态",value:player.timeControlStatus == .playing ? "播放中" : player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? "缓冲中":"已暂停")
              let size = item.presentationSize
              if !audioOnly, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
                LabeledContent("分辨率",value:"\(Int(size.width)) × \(Int(size.height))")
              }
              if let event = item.accessLog()?.events.last {
                if event.observedBitrate.isFinite,event.observedBitrate > 0 {
                  LabeledContent("实测码率",value:"\(Int(event.observedBitrate/1000)) kbps")
                }
                if event.numberOfStalls >= 0 { LabeledContent("缓冲次数",value:"\(event.numberOfStalls)") }
                if event.numberOfDroppedVideoFrames >= 0, !audioOnly { LabeledContent("丢帧",value:"\(event.numberOfDroppedVideoFrames)") }
              }
            }
          }
        }
      }
      NavigationLink("播放器音量") { AudioLevelSettings() }
    }.navigationTitle("播放信息")
  }
}
