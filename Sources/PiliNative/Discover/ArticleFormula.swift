import SwiftUI
import WebKit

struct ArticleFormulaView: View {
  let formula: String
  @Environment(\.colorScheme) private var theme
  @State private var image: Data?
  @State private var height: CGFloat = 32
  var body: some View {
    Group {
      if let image {
        FormulaSVG(data: image, dark: theme == .dark).frame(height: height).accessibilityLabel(
          formula)
      } else {
        Text(verbatim: formula).font(.body.monospaced()).textSelection(.enabled)
      }
    }
    .task(id: formula) {
      image = nil
      guard !formula.isEmpty, formula.utf8.count <= 6000 else { return }
      do {
        guard let result = try await ArticleFormulaStore.shared.image(formula) else { return }
        try Task.checkCancellation()
        if let measured = result.height { height = CGFloat(measured) }
        image = result.data
      } catch {}
    }
  }
}
private struct FormulaSVG: UIViewRepresentable {
  let data: Data, dark: Bool
  final class State { var data: Data?, dark = false }
  func makeCoordinator() -> State { State() }
  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: .zero, configuration: config)
    view.isOpaque = false
    view.backgroundColor = .clear
    view.scrollView.backgroundColor = .clear
    view.scrollView.isScrollEnabled = false
    view.isUserInteractionEnabled = false
    return view
  }
  func updateUIView(_ web: WKWebView, context: Context) {
    let state = context.coordinator
    guard state.data != data || state.dark != dark else { return }
    state.data = data
    state.dark = dark
    let style = dark ? "filter:invert(1);" : ""
    web.loadHTMLString(
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\"><style>*{margin:0}html,body{width:100%;height:100%;background:transparent}img{max-width:100%;height:100%;object-fit:contain;object-position:left center;\(style)}</style><img alt=\"\" src=\"data:image/svg+xml;base64,\(data.base64EncodedString())\">",
      baseURL: nil)
  }
}
