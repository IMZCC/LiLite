import AVKit
import SwiftUI

struct SponsorEditor: View {
  @ObservedObject var model: PlayerModel
  var embedded = false
  @Environment(\.dismiss) private var dismiss
  @State private var confirm = false
  @State private var busy = false
  @State private var issue: String?
  @State private var preview: SponsorDraft?
  private var fallback: Double { min(max(0, model.seconds), model.duration) }
  var body: some View {
    if embedded { form } else { PiliNavigationStack { form } }
  }
  private var form: some View {
      Form {
        ForEach($model.sponsorDrafts) { $row in
          Section {
            Picker("类别", selection: Binding(get: { row.category }, set: { row.select($0) })) {
              ForEach(SponsorCategory.all) { c in Text(c.title).tag(c.id) }
            }
            Picker("操作", selection: $row.action) {
              ForEach(row.kind.actions, id: \.self) { a in
                Text(["skip": "跳过", "mute": "静音", "poi": "精彩时刻", "full": "整段视频"][a] ?? a).tag(a)
              }
            }
            if row.action != "full" { point("开始", $row.start, edge: 0) }
            if row.action != "full" && row.action != "poi" {
              point("结束", $row.end, edge: model.duration)
            }
            HStack {
              Button("预览") {
                do {
                  _ = try row.range(duration: model.duration)
                  preview = row
                } catch { issue = error.localizedDescription }
              }
              Spacer()
              Button("移除", role: .destructive) {
                let id = row.id
                model.sponsorDrafts.removeAll { $0.id == id }
              }
            }.buttonStyle(.borderless)
          }
        }.onDelete { model.sponsorDrafts.remove(atOffsets: $0) }.onMove {
          model.sponsorDrafts.move(fromOffsets: $0, toOffset: $1)
        }
        Button {
          model.sponsorDrafts.insert(.init(end: fallback), at: 0)
        } label: {
          Label("添加片段", systemImage: "plus")
        }
        if let issue { Text(issue).foregroundStyle(.secondary) }
      }.disabled(busy).modifier(ReplyEdgeDismiss(standalone: !busy)).navigationTitle("提交片段")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(busy) }
          ToolbarItem(placement: .primaryAction) { EditButton().disabled(busy) }
          ToolbarItem(placement: .confirmationAction) {
            Button("提交") {
              do {
                _ = try SponsorDraft.payload(model.sponsorDrafts, duration: model.duration)
                issue = nil
                confirm = true
              } catch { issue = error.localizedDescription }
            }
            .disabled(busy || model.sponsorDrafts.isEmpty)
          }
        }.confirmationDialog(
          "提交 \(model.sponsorDrafts.count) 个片段到当前空降助手服务器？", isPresented: $confirm,
          titleVisibility: .visible
        ) {
          Button("确认提交") { Task { await publish() } }
        }.piliSheet(item: $preview) { row in SponsorPreview(model: model, draft: row) }
      .interactiveDismissDisabled(busy)
  }
  private func point(_ label: String, _ value: Binding<Double>, edge: Double) -> some View {
    HStack {
      Text(label)
      TextField("秒", value: value, format: .number).keyboardType(.decimalPad).monospacedDigit()
      Menu {
        Button("当前播放时间") { value.wrappedValue = fallback }
        Button(edge == 0 ? "视频开头" : "视频结尾") { value.wrappedValue = edge }
      } label: {
        Image(systemName: "clock.arrow.circlepath").accessibilityLabel("设置" + label + "时间")
      }
    }
  }
  @MainActor private func publish() async {
    guard !busy, let source = model.timeline.source, let bv = source.bvid else { return }
    let rows = model.sponsorDrafts
    busy = true
    defer { busy = false }
    do {
      _ = try await SponsorAPI().publish(
        bvid: bv, cid: source.cid, duration: model.duration, drafts: rows)
      guard model.timeline.source == source else { return }
      let sent = Set(rows.map(\.id))
      model.sponsorDrafts.removeAll { sent.contains($0.id) }
      await model.reloadSponsors()
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
private struct SponsorPreview: View {
  @ObservedObject var model: PlayerModel
  let draft: SponsorDraft
  @Environment(\.dismiss) private var dismiss
  @State private var player: (any PlaybackEngine)?
  @State private var replay = 0
  @State private var resume = false
  @State private var source: TimelineSource?
  @State private var issue: String?
  var body: some View {
    PiliNavigationStack {
      VStack {
        Group {
          if let native = player?.nativePlayer { VideoPlayer(player: native) }
          else if let mpv = player as? MPVPlayer { MPVVideoView(player: mpv).id(ObjectIdentifier(mpv)) }
          else { Color.black }
        }.aspectRatio(16 / 9, contentMode: .fit)
        if let issue { Text(issue) }
        Button("重新预览") { replay += 1 }
      }.navigationTitle("片段预览").toolbar { Button("完成") { dismiss() } }
    }.onAppear {
      source = model.timeline.source
      resume = model.engine.rate != 0
      if resume { model.engine.pause() }
    }.task(id: replay) { await run() }
      .onDisappear {
        player?.pause()
        player?.nativePlayer?.replaceCurrentItem(with: nil)
        (player as? MPVPlayer)?.stop()
        player = nil
        if resume, source == model.timeline.source {
          model.engine.playImmediately(atRate: model.rate)
        }
      }
  }
  @MainActor private func run() async {
    guard let item = model.engine.playbackItem else {
      issue = "没有可预览的视频"
      return
    }
    do {
      let range = try draft.range(duration: model.duration)
      player?.pause()
      let next: any PlaybackEngine
      if let native = item as? AVPlayerItem { next = AVPlayer(playerItem: AVPlayerItem(asset: native.asset)) }
      else if let copy = (model.engine as? MPVPlayer)?.previewCopy() { next = copy }
      else { throw ServiceError("没有可预览的视频") }
      self.player = next
      let player = next
      player.isMuted = false
      for _ in 0..<400 where !player.playbackReady {
        try await Task.sleep(for: .milliseconds(50))
      }
      guard player.playbackReady else { throw ServiceError("无法播放预览") }
      let a = range[0]
      let b = range[1]
      let begin = draft.action == "full" ? 0 : max(0, a - 3)
      func seek(_ t: Double) async -> Bool {
        await player.seek(
          to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero,
          toleranceAfter: .zero)
      }
      guard await seek(begin), !Task.isCancelled else { return }
      player.play()
      var crossed = false
      while !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(65))
        if !player.playbackReady { throw ServiceError("无法播放预览") }
        let t = player.currentTime().seconds
        if t.isFinite && t >= a && !crossed {
          crossed = true
          if draft.action == "skip" { _ = await seek(b) }
        }
        if draft.action == "mute" { player.isMuted = t >= a && t < b }
        if t.isFinite && t >= min(model.duration, b + 4) {
          player.pause()
          break
        }
      }
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
}
