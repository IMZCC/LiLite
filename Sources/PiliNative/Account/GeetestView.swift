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
        CaptchaBrowser(challenge: challenge) { solution in completed(solution); dismiss() } failed: { code in
          issue = code.map { "验证码未能加载（\($0)），请重试" } ?? "验证码未能加载，请重试"
        } ready: { issue = nil } closed: { dismiss() }.id(revision)
        if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
        Button("重新加载") { issue = nil; revision += 1 }.padding(.bottom)
      }.navigationTitle("安全验证").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
  }
}
private struct CaptchaBrowser: UIViewRepresentable {
  let challenge: MobileCaptcha, completed: (MobileCaptchaSolution) -> Void, failed: (String?) -> Void
  let ready: () -> Void, closed: () -> Void
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
    // gettype.php only honours JSONP callbacks named like Geetest's own, `geetest_<digits>`. Any
    // other name gets bare JSON, `{"error_code":"error_05"}` ("jsonp xss"), that is not a script:
    // the callback never ran and the captcha page stayed blank.
    let callback = "geetest_\(Int64(Date().timeIntervalSince1970 * 1000))"
    var c = URLComponents(string: "https://api.geetest.com/gettype.php")!
    c.queryItems = [.init(name: "gt", value: challenge.gt), .init(name: "callback", value: callback)]
    let configURL = c.url!.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    // A v4 registration loads gt4.js directly. A v3 one tries gettype first and, when Geetest says
    // the gt is a v4 captcha id (`error_34`, "captcha not found"), switches to v4 with the same id.
    let v3 = challenge.v4 ? "" : """
      <script src="https://static.geetest.com/static/js/fullpage.0.0.0.js" onload="ready=true;start()" onerror="fail('script')"></script>
      <script src="\(configURL)" onload="if(!config&&!v4)fail('gettype')" onerror="fail('network')"></script>
      """
    return """
      <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"></head><body>
      <script>
      let config,ready=false,captcha,shown=false,failed=false,v4=false;
      const report=(type,result)=>window.webkit.messageHandlers.piliCaptcha.postMessage({type,result});
      const fail=(code)=>{if(shown||failed)return;failed=true;report('error',{code:String(code||'')});};
      const codeOf=(e)=>String(e&&(e.error_code||e.code)||'');
      function bind(c,validate,show){c.onSuccess(()=>report('success',validate()))
        .onError((e)=>{if(!shown)fail(codeOf(e));else report('error',{code:codeOf(e)});})
        .onClose(()=>report('close',{}));
        c.onReady(()=>{shown=true;report('ready',{});show();});}
      function start(){if(!config||!ready||captcha)return;
        captcha=Geetest(config);bind(captcha,()=>captcha.getValidate(),()=>captcha.verify());}
      function startV4(){if(v4)return;v4=true;
        const s=document.createElement('script');s.src='https://static.geetest.com/v4/gt4.js';s.onerror=()=>fail('script');
        s.onload=()=>initGeetest4({captchaId:\(literal(challenge.gt)),product:'bind',language:'zho'},(c)=>{captcha=c;
          bind(c,()=>Object.assign({},c.getValidate(),{v:4}),()=>c.showCaptcha());});
        document.head.appendChild(s);}
      window[\(literal(callback))]=function(d){if(d&&d.status==='error'&&d.error_code==='error_34'){startV4();return;}
        if(!d||d.status!=='success'){fail(d&&d.error_code||'gettype');return;}
        config=Object.assign({},d.data,{gt:\(literal(challenge.gt)),challenge:\(literal(challenge.challenge)),offline:false,new_captcha:true,product:'bind',width:'100%',https:true,protocol:'https://'});start();};
      setTimeout(()=>{if(!shown)fail('timeout');},20000);
      \(challenge.v4 ? "startV4();" : "")
      </script>
      \(v3)</body></html>
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
        let solution = Self.solution(result, for: parent.challenge)
      {
        finished = true; parent.completed(solution)
      } else if type == "close" { finished = true; parent.closed() }
      else if type == "ready" { parent.ready() }
      else {
        // Only Geetest's short codes (error_34, timeout…) are shown; anything else stays generic.
        let code = ((body["result"] as? [String: Any])?["code"] as? String).flatMap { code in
          (1...32).contains(code.count) && code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) ? code : nil
        }
        parent.failed(code)
      }
    }
    /// v3's `getValidate()`, or v4's (tagged `v: 4` by the page) with its captcha id.
    static func solution(_ result: [String: Any], for registration: MobileCaptcha) -> MobileCaptchaSolution? {
      func text(_ key: String) -> String? {
        let value = (result[key] as? String) ?? (result[key] as? NSNumber)?.stringValue
        return value.flatMap { !$0.isEmpty && $0.utf8.count <= 4096 ? $0 : nil }
      }
      if (result["v"] as? NSNumber)?.intValue == 4 {
        guard let lot = text("lot_number"), let output = text("captcha_output"), let pass = text("pass_token"),
          let time = text("gen_time"), text("captcha_id").map({ $0 == registration.gt }) ?? true
        else { return nil }
        return .init(result: .v4(lotNumber: lot, output: output, passToken: pass, time: time), token: registration.token)
      }
      guard let challenge = text("geetest_challenge"), let validate = text("geetest_validate"),
        let seccode = text("geetest_seccode"), challenge.hasPrefix(String(registration.challenge.prefix(32)))
      else { return nil }
      return .init(result: .v3(challenge: challenge, validate: validate, seccode: seccode), token: registration.token)
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
      if (error as NSError).code != NSURLErrorCancelled { parent.failed(nil) }
    }
  }
}
