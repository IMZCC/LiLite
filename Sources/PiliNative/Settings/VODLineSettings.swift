import SwiftUI

struct VODLineSettings: View {
  var sample: [URL] = []
  var reference: URL? = nil
  var sampleOwner: String? = nil
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage(VODLine.key) private var selected = VODLine.backupUrl.rawValue
  @AppStorage(VODLine.audioKey) private var independent = false
  @AppStorage(VODLine.testKey) private var testing = true
  @State private var run = 0
  @State private var states: [VODLine: Result] = [:]
  @State private var issue: String?
  @State private var busy = false
  private enum Result {
    case checking, unavailable, failed
    case measured(Double)
    var text: String {
      switch self {
      case .checking: return "测速中"
      case .unavailable: return "样片不提供"
      case .failed: return "未连通"
      case .measured(let bps):
        return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .decimal) + "/秒"
      }
    }
  }
  private var fastest: VODLine? {
    VODLine.allCases.compactMap { line -> (VODLine, Double)? in
      guard case .measured(let n) = states[line] else { return nil }
      return (line, n)
    }.max { $0.1 < $1.1 }?.0
  }
  var body: some View {
    Form {
      Section {
        Toggle("音频单独选线", isOn: $independent).settingAnchor("VODLineSettings/音频单独选线")
        Toggle("进入时测速", isOn: $testing).settingAnchor("VODLineSettings/进入时测速")
        if testing {
          if let issue { Text(issue).foregroundStyle(.secondary) }
          Button(busy ? "停止测速" : "重新测速") { run = busy ? -1 : max(1, run + 1) }
          if !busy, let fastest { Button("选择最快：\(fastest.label)") { selected = fastest.rawValue }.settingAnchor("VODLineSettings/选择最快") }
        }
      } footer: {
        Text("音频单独选线时优先使用服务提供的地址。测速每条线路最多读取 256 KB")
      }
      Section("优先线路") {
        ForEach(VODLine.allCases) { line in
          Button {
            selected = line.rawValue
          } label: {
            HStack {
              Text(line.label).foregroundStyle(.primary)
              Spacer()
              if testing, let result = states[line] {
                Text(result.text).font(.caption).foregroundStyle(.secondary)
              }
              if selected == line.rawValue {
                Image(systemName: "checkmark").accessibilityLabel("已选")
              }
            }
          }
        }
      }.settingAnchor("VODLineSettings/优先线路")
    }.navigationTitle("视频线路")
      .onChange(of: testing) { _, enabled in if enabled { run = 0 } }
      .task(id: "\(testing):\(run):\(accounts.state.owner(.role(.video)) ?? "")") {
        busy = false
        guard testing, run >= 0 else { return }
        await measure()
      }
  }
  @MainActor private func measure() async {
    busy = true
    issue = nil
    states = [:]
    defer { if !Task.isCancelled { busy = false } }
    let transport = RangeTransport()
    defer { transport.close() }
    do {
      let viewer = try await AccountJar.shared.current(.role(.video))?.id ?? ""
      func authorized() async throws {
        try Task.checkCancellation()
        guard try await AccountJar.shared.current(.role(.video))?.id ?? "" == viewer else {
          throw ServiceError("取流账号已切换")
        }
      }
      let urls: [URL]
      let ref: URL
      if !sample.isEmpty, let reference {
        guard sampleOwner == viewer else { throw ServiceError("取流账号已切换，请重新选择视频") }
        urls = sample
        ref = reference
      } else {
        let dash = try await BiliAPI.shared.formats("BV1fK4y1t7hj", cid: 196_018_899, expectedAccount: viewer)
        guard let stream = dash.video.first else { throw ServiceError("没有可用的测速样片") }
        urls = stream.originals
        ref = URL(string: "https://www.bilibili.com/video/BV1fK4y1t7hj/")!
      }
      var cache: [URL: Result] = [:]
      for line in VODLine.allCases {
        try await authorized()
        guard let url = line.candidate(urls) else {
          states[line] = .unavailable
          continue
        }
        if let previous = cache[url] {
          states[line] = previous
          continue
        }
        states[line] = .checking
        let result: Result
        do {
          let measurement = try await VODSpeedProbe.sample(url, reference: ref, via: transport)
          result = .measured(measurement.bytesPerSecond)
        } catch {
          try Task.checkCancellation()
          result = .failed
        }
        try await authorized()
        cache[url] = result
        states[line] = result
      }
    } catch {
      if !Task.isCancelled { issue = error.localizedDescription }
    }
  }
}

struct PlayerLineButton: View {
  @ObservedObject var model: PlayerModel
  @State private var show = false
  @State private var initial = ""
  private var preferences: String {
    (UserDefaults.standard.string(forKey: VODLine.key) ?? VODLine.backupUrl.rawValue)
      + ":" + String(UserDefaults.standard.bool(forKey: VODLine.audioKey))
  }
  var body: some View {
    Button {
      initial = preferences
      show = true
    } label: {
      Label("视频线路", systemImage: "point.3.connected.trianglepath.dotted")
    }.labelStyle(.iconOnly)
      .piliSheet(
        isPresented: $show,
        onDismiss: {
          if preferences != initial { Task { await model.reloadLine() } }
        }
      ) {
        PiliNavigationStack {
          VODLineSettings(sample: model.lineSample, reference: model.lineReference, sampleOwner: model.lineSampleOwner)
            .toolbar { Button("完成") { show = false } }
        }
      }
  }
}
