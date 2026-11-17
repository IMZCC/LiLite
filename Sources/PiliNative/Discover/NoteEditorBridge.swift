import WebKit

/// Match only the official note editor for this archive. The page cannot choose an arbitrary native destination.
@MainActor final class NoteEditorBridge: NSObject, WKScriptMessageHandler {
  static let name = "piliNote"
  let oid: Int64, event: (Bool) -> Void
  init(oid: Int64, event: @escaping (Bool) -> Void) {
    self.oid = oid
    self.event = event
  }
  static func url(oid: Int64, interactive: Bool) -> URL {
    var c = URLComponents(string: "https://www.bilibili.com/h5/note-app")!
    c.queryItems = [
      .init(name: "oid", value: String(oid)), .init(name: "pagefrom", value: "ugcvideo"),
      .init(name: "is_stein_gate", value: interactive ? "1" : "0"),
    ]
    return c.url!
  }
  func matches(_ url: URL?) -> Bool {
    guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.scheme == "https", c.host == "www.bilibili.com", c.port == nil || c.port == 443,
      c.user == nil, c.password == nil, c.path == "/h5/note-app"
    else { return false }
    return c.queryItems?.filter { $0.name == "oid" }.map(\.value) == [String(oid)]
  }
  func install(_ controller: WKUserContentController) {
    controller.add(self, contentWorld: .defaultClient, name: Self.name)
    let source = """
      if (location.origin === 'https://www.bilibili.com' && location.pathname === '/h5/note-app') {
        document.addEventListener('click', function (e) {
          if (!e.isTrusted || !e.target || !e.target.closest) return;
          if (e.target.closest('.finish-btn')) window.webkit.messageHandlers.piliNote.postMessage('finish');
          else if (e.target.closest('.info-bar')) window.webkit.messageHandlers.piliNote.postMessage('video');
        }, true);
      }
      """
    controller.addUserScript(
      WKUserScript(
        source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
  }
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    guard message.name == Self.name, message.frameInfo.isMainFrame,
      matches(message.frameInfo.request.url), matches(message.webView?.url),
      let command = message.body as? String
    else { return }
    if command == "video" { event(false) } else if command == "finish" { event(true) }
  }
}
