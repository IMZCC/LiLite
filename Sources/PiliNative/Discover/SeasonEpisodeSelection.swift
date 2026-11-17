import SwiftUI

struct SeasonEpisodeSelection: View {
  let episodes: [SeasonInfo.Episode], current: Int64, course: Bool,
    choose: (SeasonInfo.Episode) async throws -> Void
  @State private var reversed = false
  @State private var resolving: Int64?
  @State private var error: String?
  private var visible: [SeasonInfo.Episode] { reversed ? Array(episodes.reversed()) : episodes }
  var body: some View {
    ScrollViewReader { proxy in
      VStack {
        HStack(spacing: 14) {
          Text("共 \(episodes.count) 集").font(.subheadline.weight(.semibold))
          Spacer()
          Menu {
            Button("第一项") { if let e = visible.first { proxy.scrollTo(e.id, anchor: .top) } }
            Button("最后一项") { if let e = visible.last { proxy.scrollTo(e.id, anchor: .bottom) } }
            Button("正在播放") { proxy.scrollTo(current, anchor: .center) }
          } label: {
            Label("定位", systemImage: "scope")
          }
          Button {
            reversed.toggle()
          } label: {
            Label(reversed ? "倒序" : "正序", systemImage: "arrow.up.arrow.down")
          }
        }
        .font(.subheadline).labelStyle(.titleAndIcon).buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 6)
        List(visible) { e in
          Button {
            guard e.id != current, resolving == nil else { return }
            resolving = e.id
            Task {
              defer { resolving = nil }
              do { try await choose(e) } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
              }
            }
          } label: {
            HStack {
              EpisodeCatalogRow(episode: e, course: course)
              Spacer()
              if resolving == e.id {
                ProgressView()
              } else if e.id == current {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(.tint)
                  .accessibilityLabel("正在播放")
              }
            }
          }.disabled(resolving != nil || !(course ? e.canRequestPlayback : e.catalogPlayable)).id(
            e.id)
        }.listStyle(.plain)
      }.onAppear { proxy.scrollTo(current, anchor: .center) }.alert(
        "选集", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })
      ) {
        Button("好") {}
      } message: {
        Text(error ?? "")
      }
    }
  }
}

struct SeasonPlaybackLine: View {
  @ObservedObject var model: PlayerModel
  @AppStorage(VODLine.key) private var selected = VODLine.backupUrl.rawValue
  @State private var applying = false
  var body: some View {
    Menu {
      ForEach([VODLine.baseUrl, VODLine.backupUrl]) { line in
        Button {
          guard !applying else { return }
          selected = line.rawValue
          if model.ready, model.quality > 0 {
            let q = model.quality
            applying = true
            Task {
              defer { applying = false }
              await model.changeQuality(q)
            }
          }
        } label: {
          if selected == line.rawValue {
            Label(line.label, systemImage: "checkmark")
          } else {
            Text(line.label)
          }
        }
      }
    } label: {
      Label("播放线路：" + (VODLine(rawValue: selected)?.label ?? "默认"), systemImage: "network")
    }.disabled(applying)
  }
}
