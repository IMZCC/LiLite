import SwiftUI

struct ViewportSettings: View {
  @AppStorage("player.bottomProgress") private var progress = 0
  @AppStorage("player.longControls") private var longer = false
  @AppStorage(UpscaleSession.key) private var upscaleMode = 0
  @AppStorage("player.shrink") private var shrink = true
  @AppStorage("player.edgeToEdge") private var edges = false
  var body: some View {
    Form {
      Section {
        Picker("底部进度条", selection: $progress) {
          ForEach(ViewportProgress.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
        }.settingAnchor("ViewportSettings/底部进度条")
        Toggle("延长播放控件显示时间", isOn: $longer).settingAnchor("ViewportSettings/延长播放控件显示时间")
      } footer: {
        Text("延长至 30 秒，便于切换控件焦点")
      }
      Section {
        Picker("番剧与国创超分辨率", selection: $upscaleMode) { ForEach(UpscaleMode.allCases) { Text($0.label).tag($0.rawValue) } }.settingAnchor("ViewportSettings/番剧与国创超分辨率")
        Toggle("双指允许缩小画面", isOn: $shrink).settingAnchor("ViewportSettings/双指允许缩小画面")
        Toggle("播放画面延伸到屏幕边缘", isOn: $edges).settingAnchor("ViewportSettings/播放画面延伸到屏幕边缘")
      }
    }.navigationTitle("画面与控件")
  }
}

struct ViewportAspect: Layout {
  let expanded: Bool
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let w = max(1, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320)
    let h = proposal.height.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (w * 9 / 16)
    return CGSize(width: w, height: expanded ? h : min(h, w * 9 / 16))
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    subviews.first?.place(
      at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
  }
}

struct PlaybackEdgeInsets: ViewModifier {
  var fullscreen = false
  @AppStorage("player.edgeToEdge") private var edges = false
  func body(content: Content) -> some View {
    content.ignoresSafeArea(
      .container, edges: edges ? (fullscreen ? .all : [.top, .horizontal]) : []
    )
    .statusBarHidden(edges)
  }
}
