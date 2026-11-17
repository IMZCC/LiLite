import SwiftUI
import WebKit

struct GeetestView: View {
  let challenge: MobileCaptcha, completed: (MobileCaptchaSolution) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var issue: String?
  @State private var revision = 0
  var body: some View {
    PiliNavigationStack {
      VStack {
        CaptchaBrowser(challenge: challenge) { solution in completed(solution); dismiss() } failed: {
          issue = "验证码未能加载，请重试"
        } closed: { dismiss() }.id(revision)
        if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
        Button("重新加载") { issue = nil; revision += 1 }.padding(.bottom)
      }.navigationTitle("安全验证").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
  }
}
private struct CaptchaBrowser: UIViewRepresentable {
  let challenge: MobileCaptcha, completed: (MobileCaptchaSolution) -> Void, failed: () -> Void, closed: () -> Void
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    config.userContentController.add(context.coordinator, name: "piliCaptcha")
    let browser = WKWebView(frame: .zero, configuration: config); browser.navigationDelegate = context.coordinator
    browser.isOpaque = false; browser.backgroundColor = .clear
    browser.loadHTMLString(Self.html(challenge), baseURL: URL(string: "https://passport.bilibili.com/"))
    return browser
  }
  func updateUIView(_ view: WKWebView, context: Context) {}
  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading(); view.configuration.userContentController.removeScriptMessageHandler(forName: "piliCaptcha")
  }
  private static func html(_ challenge: MobileCaptcha) -> String {
    func literal(_ value: String) -> String {
      let data = try! JSONSerialization.data(withJSONObject: [value])
      return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description.replacingOccurrences(of: "<", with: "\\u003c")
    }
    var c = URLComponents(string: "https://api.geetest.com/gettype.php")!
    c.queryItems = [.init(name: "gt", value: challenge.gt), .init(name: "callback", value: "piliGeetestConfig")]
    let configURL = c.url!.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    return """
      <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"></head><body>
      <script>
      let config,ready=false,captcha;
      const report=(type,result)=>window.webkit.messageHandlers.piliCaptcha.postMessage({type,result});
      function start(){if(!config||!ready||captcha)return;
        captcha=Geetest(config).onSuccess(()=>report('success',captcha.getValidate())).onError(()=>report('error',{})).onClose(()=>report('close',{}));
        captcha.onReady(()=>captcha.verify());}
      function piliGeetestConfig(d){if(!d||d.status!=='success'){report('error',{});return;}
        config=Object.assign({},d.data,{gt:\(literal(challenge.gt)),challenge:\(literal(challenge.challenge)),offline:false,new_captcha:true,product:'bind',width:'100%',https:true,protocol:'https://'});start();}
      </script>
      <script src="https://static.geetest.com/static/js/fullpage.0.0.0.js" onload="ready=true;start()" onerror="report('error',{})"></script>
      <script src="\(configURL)" onerror="report('error',{})"></script></body></html>
      """
  }
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let parent: CaptchaBrowser
    private var finished = false
    init(_ parent: CaptchaBrowser) { self.parent = parent }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
      guard !finished, message.frameInfo.isMainFrame,
        message.frameInfo.securityOrigin.host == "passport.bilibili.com",
        let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
      if type == "success", let result = body["result"] as? [String: Any],
        let challenge = result["geetest_challenge"] as? String, let validate = result["geetest_validate"] as? String,
        let seccode = result["geetest_seccode"] as? String,
        [challenge, validate, seccode].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }),
        challenge.hasPrefix(String(parent.challenge.challenge.prefix(32)))
      {
        finished = true; parent.completed(.init(challenge: challenge, validate: validate, seccode: seccode, token: parent.challenge.token))
      } else if type == "close" { finished = true; parent.closed() }
      else { parent.failed() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      if let frame = action.targetFrame, !frame.isMainFrame {
        decisionHandler(action.request.url?.scheme == "https" || action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
      } else {
        let url = action.request.url
        decisionHandler(url?.absoluteString == "about:blank" || (url?.scheme == "https" && url?.host == "passport.bilibili.com" && action.navigationType == .other) ? .allow : .cancel)
      }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      if (error as NSError).code != NSURLErrorCancelled { parent.failed() }
    }
  }
}
