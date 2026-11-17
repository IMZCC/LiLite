import CoreImage.CIFilterBuiltins
import Photos
import SwiftUI

private actor QRPassport {
  private let session: BiliServiceSession = {
    let c = URLSessionConfiguration.ephemeral
    let proxy = APIProxy.current()
    proxy.apply(to: c)
    c.urlCredentialStorage = nil
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    return BiliServiceSession(
      native: URLSession(configuration: c, delegate: APIRedirectPolicy(), delegateQueue: nil),
      proxy: proxy)
  }()
  deinit { session.native.finishTasksAndInvalidate() }
  struct Ticket: Decodable {
    let url: String
    let qrcode_key: String
  }
  struct Poll: Decodable {
    let code: Int
    let url: String?
  }
  private struct Reply<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
  }
  private func request<T: Decodable>(_ method: String, key: String? = nil, as: T.Type) async throws
    -> (T, [HTTPCookie])
  {
    var c = URLComponents()
    c.scheme = "https"
    c.host = "passport.bilibili.com"
    c.path = "/x/passport-login/web/qrcode/" + method
    if let key { c.queryItems = [URLQueryItem(name: "qrcode_key", value: key)] }
    var r = URLRequest(url: c.url!, timeoutInterval: 15)
    r.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    let (d, response, cookies) = try await session.response(for: r)
    guard response.statusCode == 200 else {
      throw ServiceError("登录服务暂时不可用")
    }
    let reply = try JSONDecoder().decode(Reply<T>.self, from: d)
    guard reply.code == 0, let data = reply.data else {
      throw ServiceError(reply.message ?? "登录失败")
    }
    return (data, cookies)
  }
  func generate() async throws -> Ticket { try await request("generate", as: Ticket.self).0 }
  func poll(_ ticket: Ticket) async throws -> (Int, [String: String]) {
    let (p, responseCookies) = try await request("poll", key: ticket.qrcode_key, as: Poll.self)
    guard p.code == 0 else { return (p.code, [:]) }
    let allowed = Set(["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"])
    var cookies: [String: String] = [:]
    for cookie in responseCookies where allowed.contains(cookie.name) {
      cookies[cookie.name] = cookie.value
    }
    if let raw = p.url, let comps = URLComponents(string: raw),
      comps.scheme == "https", let host = comps.host,
      host == "bilibili.com" || host.hasSuffix(".bilibili.com")
    {
      for q in comps.queryItems ?? [] where allowed.contains(q.name) && cookies[q.name] == nil {
        cookies[q.name] = q.value
      }
    }
    return (
      0,
      cookies.filter {
        !$0.value.contains(";") && !$0.value.contains("\r") && !$0.value.contains("\n")
      }
    )
  }
}
/// Sign-in page laid out like the original: 密码 / 短信 / 扫码 / Cookie tabs under the title, the
/// web-page methods tucked into the toolbar menu.
struct QRLoginView: View {
  private enum Method: Hashable { case password, sms, qr, cookie }
  private enum Extra: Hashable { case web, webQR }
  @State private var method = Method.password
  @State private var extra: Extra?
  var body: some View {
    VStack(spacing: 0) {
      LoginTabStrip(
        tabs: [
          (.password, "密码", "key"), (.sms, "短信", "message"), (.qr, "扫码", "qrcode"),
          (.cookie, "Cookie", "birthday.cake"),
        ],
        selection: $method)
      Group {
        switch method {
        case .password: NativeLoginForm(method: .password, expectedUID: nil).id(Method.password)
        case .sms: NativeLoginForm(method: .sms, expectedUID: nil).id(Method.sms)
        case .qr: NativeLoginForm(method: .qr, expectedUID: nil).id(Method.qr)
        case .cookie: CookieLogin()
        }
      }
      .frame(maxHeight: .infinity)
    }
    .navigationTitle("登录").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      Menu {
        Button("网页登录", systemImage: "safari") { extra = .web }
        Button("网页二维码", systemImage: "qrcode.viewfinder") { extra = .webQR }
      } label: {
        Label("更多登录方式", systemImage: "ellipsis")
      }
    }
    .navigationDestination(item: $extra) { kind in
      switch kind {
      case .web: WebsiteLogin().navigationTitle("网页登录").navigationBarTitleDisplayMode(.inline)
      case .webQR: WebQRLoginView().navigationTitle("网页二维码").navigationBarTitleDisplayMode(.inline)
      }
    }
  }
}
private struct WebQRLoginView: View {
  @EnvironmentObject var accounts: AccountContext
  @Environment(\.dismiss) var dismiss
  @State private var image: UIImage?
  @State private var status = "正在获取二维码"
  @State private var epoch = 0
  @State private var stopped = false
  @State private var displayed: URL?
  @State private var expiry: Date?
  @State private var note: String?

  var body: some View {
    qrPage
  }
  private var qrPage: some View {
    LoginPane(headline: "使用哔哩哔哩 App 扫描网页登录码", footnote: LoginCopy.trusted) {
      if let expiry, displayed != nil, !stopped {
        TimelineView(.periodic(from: .now, by: 1)) { t in
          Text("剩余有效时间：\(max(0, Int(ceil(expiry.timeIntervalSince(t.date))))) 秒")
            .font(.subheadline.monospacedDigit()).foregroundStyle(.tint)
        }
      }
      HStack(spacing: 18) {
        Button("刷新二维码", systemImage: "arrow.clockwise") { epoch += 1 }
        if let displayed, let expiry, !stopped {
          Button("保存至相册", systemImage: "square.and.arrow.down") { Task { await saveQR() } }
          Button("其他应用打开", systemImage: "arrow.up.forward.app") {
            guard Date() < expiry else { return }
            OfficialAppHandoff.shared.open(displayed) { note = "未能打开哔哩哔哩，可保存二维码后在哔哩哔哩中扫一扫" }
          }
        }
      }
      .font(.subheadline).labelStyle(.titleAndIcon).buttonStyle(.borderless)
      LoginQRCode(image: image, loading: image == nil && !stopped)
      Text(status).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if let displayed, let expiry, !stopped {
        Button {
          guard Date() < expiry else { return }
          UIPasteboard.general.setItems(
            [["public.utf8-plain-text": displayed.absoluteString]],
            options: [.localOnly: true, .expirationDate: expiry])
          note = "已复制到剪贴板，可粘贴至已登录的哔哩哔哩私信处发送，然后点击已发送的链接打开"
        } label: {
          Text(displayed.absoluteString).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            .multilineTextAlignment(.center).lineLimit(3)
        }
        .buttonStyle(.plain)
      }
    }
    .task(id: epoch) { await login() }.onDisappear {
      displayed = nil
      expiry = nil
      image = nil
    }
    .alert("扫码登录", isPresented: .init(get: { note != nil }, set: { if !$0 { note = nil } })) {
      Button("好") {}
    } message: {
      Text(note ?? "")
    }
  }
  @MainActor private func saveQR() async {
    guard let image, let expiry, let ticket = displayed, Date() < expiry else { return }
    let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard permission == .authorized || permission == .limited else {
      note = "未获准保存到照片"
      return
    }
    guard displayed == ticket, Date() < expiry else { return }
    let size = CGFloat(660)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let out = UIGraphicsImageRenderer(size: rect.size).image { ctx in
      UIColor.white.setFill()
      ctx.fill(rect)
      ctx.cgContext.interpolationQuality = .none
      image.draw(in: rect.insetBy(dx: 46, dy: 46))
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAsset(from: out)
      }
      note = "二维码已保存"
    } catch { note = error.localizedDescription }

  }
  @MainActor private func login() async {
    stopped = false
    displayed = nil
    expiry = nil
    note = nil
    image = nil
    status = "正在获取二维码"
    do {
      let generation = try await AccountJar.shared.packStamp().generation
      let api = QRPassport()
      let ticket = try await api.generate()
      try Task.checkCancellation()
      guard let address = URL(string: ticket.url), address.scheme?.lowercased() == "https",
        address.host?.lowercased() == "passport.bilibili.com", address.user == nil,
        address.password == nil, address.port == nil, !ticket.qrcode_key.isEmpty
      else { throw ServiceError("无效的登录二维码") }
      let until = Date().addingTimeInterval(180)
      displayed = address
      expiry = until
      let f = CIFilter.qrCodeGenerator()
      f.message = Data(ticket.url.utf8)
      f.correctionLevel = "M"
      guard let output = f.outputImage?.transformed(by: .init(scaleX: 6, y: 6)),
        let cg = CIContext().createCGImage(output, from: output.extent)
      else { throw ServiceError("二维码生成失败") }
      image = UIImage(cgImage: cg)
      status = "使用哔哩哔哩客户端扫码"
      while Date() < until {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let (code, cookies) = try await api.poll(ticket)
        try Task.checkCancellation()
        switch code {
        case 0:
          let verified = try await WebLoginIdentity.verify(cookies)
          try Task.checkCancellation()
          try await AccountJar.shared.add(verified.cookies, label: verified.name, expectedGeneration: generation)
          await accounts.refresh()
          dismiss()
          return
        case 86090: status = "已扫码，请在哔哩哔哩客户端确认"
        case 86101: continue
        case 86038: throw ServiceError("二维码已过期")
        default: throw ServiceError("登录未完成（\(code)）")
        }
      }
      throw ServiceError("二维码已过期")
    } catch {
      if !Task.isCancelled {
        image = nil
        displayed = nil
        expiry = nil
        status = error.localizedDescription
        stopped = true
      }
    }
  }
}
