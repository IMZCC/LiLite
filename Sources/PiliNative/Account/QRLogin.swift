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
struct QRLoginView: View {
  private enum Method: String, CaseIterable, Identifiable {
    case mobile = "客户端登录", web = "网页登录", cookie = "Cookie", webQR = "网页二维码"
    var id: Self { self }
  }
  @State private var method = Method.mobile
  var body: some View {
    VStack(spacing: 8) {
      Picker("登录方式", selection: $method) { ForEach(Method.allCases) { Text($0.rawValue).tag($0) } }
        .pickerStyle(.menu).padding(.horizontal)
      switch method {
      case .mobile: MobileClientLoginView()
      case .web: WebsiteLogin()
      case .cookie: CookieLogin()
      case .webQR: WebQRLoginView()
      }
    }.navigationTitle("登录").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        Menu("找回密码") {
          NavigationLink("手机网页版") { SitePage(url: URL(string: "https://passport.bilibili.com/h5-app/passport/login/findPassword")!) }
          NavigationLink("电脑网页版") { SitePage(url: URL(string: "https://passport.bilibili.com/pc/passport/findPassword")!) }
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
    VStack(spacing: 24) {
      if let image {
        Image(uiImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
          .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
      } else if !stopped {
        ProgressView()
      }
      Text(status).multilineTextAlignment(.center)
      if let displayed, let expiry, !stopped {
        TimelineView(.periodic(from: .now, by: 1)) { t in
          let left = max(0, Int(ceil(expiry.timeIntervalSince(t.date))))
          Text("剩余 \(left) 秒").font(.caption.monospacedDigit())
        }
        HStack {
          Button("刷新") { epoch += 1 }
          Menu("二维码") {
            Button("保存到照片") { Task { await saveQR() } }
            Button("复制登录链接") {
              guard Date() < expiry else { return }
              UIPasteboard.general.setItems(
                [["public.utf8-plain-text": displayed.absoluteString]],
                options: [.localOnly: true, .expirationDate: expiry])
              note = "已复制登录链接"
            }
            Button("使用哔哩哔哩打开") {
              guard Date() < expiry else { return }
              OfficialAppHandoff.shared.open(displayed){note="未能打开哔哩哔哩，可保存二维码后在哔哩哔哩中扫一扫"}
            }
          }
        }
      } else if stopped {
        Button("重新获取二维码") { epoch += 1 }
      }
    }.padding().task(id: epoch) { await login() }.onDisappear {
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
