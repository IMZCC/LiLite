import CoreImage.CIFilterBuiltins
import Photos
import SwiftUI

/// Mobile-client sign-in used to (re)authorise an existing account: the same password, SMS and
/// QR panes as the main sign-in page, without the cookie and web methods.
struct MobileClientLoginView: View {
  var expectedUID: String? = nil
  @State private var method = NativeLoginMethod.password
  var body: some View {
    VStack(spacing: 0) {
      LoginTabStrip(
        tabs: [(.password, "密码", "key"), (.sms, "短信", "message"), (.qr, "扫码", "qrcode")],
        selection: $method)
      NativeLoginForm(method: method, expectedUID: expectedUID).id(method)
        .frame(maxHeight: .infinity)
    }
    .navigationTitle(expectedUID == nil ? "登录" : "移动端授权").navigationBarTitleDisplayMode(.inline)
  }
}

struct NativeLoginForm: View {
  let method: NativeLoginMethod
  @StateObject private var flow: NativeLoginFlow
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var username = ""
  @State private var password = ""
  @State private var reveal = false
  @State private var phone = ""
  @State private var code = ""
  @State private var region = LoginRegion.all[0]
  @State private var choosingRegion = false
  @State private var forgot: URL?
  @State private var note: String?
  init(method: NativeLoginMethod, expectedUID: String?) {
    self.method = method
    _flow = StateObject(wrappedValue: NativeLoginFlow(expectedUID: expectedUID))
  }
  var body: some View {
    Group {
      if flow.risk != nil {
        risk
      } else {
        switch method {
        case .qr: qr
        case .password: passwordPane
        case .sms: smsPane
        }
      }
    }
    .onAppear { flow.activate(); if method == .qr { flow.startQR() } }
    .onDisappear { flow.cancel(); password = ""; code = "" }
    .piliSheet(item: $flow.captcha, onDismiss: { flow.closedCaptcha() }) { challenge in
      GeetestView(challenge: challenge) { flow.solved($0, challengeID: challenge.id) }
    }
    .onChange(of: flow.completedUID) { _, uid in
      guard uid != nil else { return }
      password = ""; code = ""
      Task { await accounts.refresh(); dismiss() }
    }
    .navigationDestination(item: $forgot) { SitePage(url: $0) }
    .navigationDestination(isPresented: $choosingRegion) { LoginRegionPicker(selected: $region) }
    .alert("扫码登录", isPresented: .init(get: { note != nil }, set: { if !$0 { note = nil } })) {
      Button("好") {}
    } message: { Text(note ?? "") }
  }

  @ViewBuilder private var issue: some View {
    if let issue = flow.issue {
      Text(issue).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
    }
  }

  // MARK: Password

  private var passwordPane: some View {
    LoginPane(headline: "使用账号密码登录", footnote: LoginCopy.password) {
      VStack(spacing: 6) {
        LoginField(symbol: "person.crop.square", title: "账号（邮箱/手机号）", text: $username,
          keyboard: .emailAddress, content: .username)
        LoginField(symbol: "key", title: "密码", text: $password, secure: !reveal, content: .password)
          .privacySensitive()
      }
      .disabled(flow.busy)
      HStack {
        Toggle(isOn: $reveal) { Text("显示密码") }.toggleStyle(LoginCheckbox())
        Spacer()
        Menu("忘记密码") {
          Text("试试扫码、手机号登录，或选择")
          Button("找回密码（手机版）", systemImage: "iphone") {
            forgot = URL(string: "https://passport.bilibili.com/h5-app/passport/login/findPassword")
          }
          Button("找回密码（电脑版）", systemImage: "desktopcomputer") {
            forgot = URL(string: "https://passport.bilibili.com/pc/passport/findPassword")
          }
        }
      }
      .font(.subheadline)
      issue
      LoginSubmit(busy: flow.busy) {
        flow.password(username.trimmingCharacters(in: .whitespacesAndNewlines), password)
      }
      .disabled(flow.busy || username.isEmpty || password.isEmpty)
    }
  }

  // MARK: SMS

  private var smsPane: some View {
    LoginPane(headline: "使用手机短信验证码登录", footnote: LoginCopy.sms) {
      VStack(spacing: 6) {
        HStack(spacing: 10) {
          Button { choosingRegion = true } label: {
            HStack(spacing: 10) {
              Image(systemName: "phone").font(.body.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 24)
              Text("+\(region.code)").monospacedDigit().foregroundStyle(.primary)
              Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("国际冠码，当前为\(region.name)，+\(region.code)")
          Rectangle().fill(.separator).frame(width: 1, height: 22)
          TextField("手机号", text: $phone).keyboardType(.numberPad).textContentType(.telephoneNumber)
            .onChange(of: phone) { _, value in
              let digits = value.filter(\.isNumber)
              if digits != value { phone = digits }
              code = ""; flow.changedPhone()
            }
          if !phone.isEmpty {
            Button { phone = "" } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }.buttonStyle(.plain).accessibilityLabel("清除")
          }
        }
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
        LoginField(symbol: "ellipsis.message", title: "验证码", text: $code, keyboard: .numberPad,
          content: .oneTimeCode) {
          sendButton { flow.sendSMS(phone, region.code) }
        }
        .privacySensitive()
      }
      .onChange(of: region) { _, _ in code = ""; flow.changedPhone() }
      issue
      LoginSubmit(busy: flow.busy) { flow.sms(phone, region.code, code) }
        .disabled(flow.busy || phone.isEmpty || code.isEmpty)
    }
  }

  // MARK: Risk check

  private var risk: some View {
    LoginPane(headline: "验证已绑定的手机号", note: "本次登录需要短信验证", footnote: LoginCopy.trusted) {
      Text(flow.maskedPhone).font(.title3.monospacedDigit().weight(.medium))
      LoginField(symbol: "ellipsis.message", title: "验证码", text: $code, keyboard: .numberPad,
        content: .oneTimeCode) {
        sendButton { flow.sendRiskSMS() }
      }
      .privacySensitive()
      issue
      LoginSubmit(title: "验证并登录", busy: flow.busy) { flow.verifyRisk(code) }
        .disabled(flow.busy || code.isEmpty)
      Button("返回登录") { code = ""; flow.leaveRisk() }.disabled(flow.busy)
    }
  }

  private func sendButton(_ action: @escaping () -> Void) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { clock in
      let left = max(0, Int(ceil((flow.cooldown ?? .distantPast).timeIntervalSince(clock.date))))
      Button(action: action) {
        Label(left > 0 ? "等待\(left)秒" : "获取验证码", systemImage: "paperplane")
          .font(.subheadline.weight(.medium)).monospacedDigit()
      }
      .buttonStyle(.borderless)
      .disabled(flow.busy || left > 0)
    }
  }

  // MARK: QR

  private var qr: some View {
    LoginPane(headline: "使用哔哩哔哩官方 App 扫码登录", footnote: LoginCopy.trusted) {
      let ticket = flow.ticket
      let image = ticket.flatMap { qrImage($0.url) }
      if let expiry = flow.expiry, ticket != nil {
        TimelineView(.periodic(from: .now, by: 1)) { time in
          Text("剩余有效时间：\(max(0, Int(ceil(expiry.timeIntervalSince(time.date))))) 秒")
            .font(.subheadline.monospacedDigit()).foregroundStyle(.tint)
        }
      }
      HStack(spacing: 18) {
        Button("刷新二维码", systemImage: "arrow.clockwise") { flow.startQR() }.disabled(flow.busy)
        if let ticket, let image, let expiry = flow.expiry {
          Button("保存至相册", systemImage: "square.and.arrow.down") {
            Task { await saveQR(image, ticket: ticket.url, expiry: expiry) }
          }
          Button("其他应用打开", systemImage: "arrow.up.forward.app") {
            guard Date() < expiry else { return }
            OfficialAppHandoff.shared.open(ticket.url) { note = "未能打开哔哩哔哩，可保存二维码后在哔哩哔哩中扫一扫" }
          }
        }
      }
      .font(.subheadline).labelStyle(.titleAndIcon).buttonStyle(.borderless)
      LoginQRCode(image: image, loading: ticket == nil && flow.issue == nil)
      Text(flow.status).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
      issue
      if let ticket, let expiry = flow.expiry {
        Button {
          guard Date() < expiry else { return }
          UIPasteboard.general.setItems([["public.utf8-plain-text": ticket.url.absoluteString]],
            options: [.localOnly: true, .expirationDate: expiry])
          note = "已复制到剪贴板，可粘贴至已登录的哔哩哔哩私信处发送，然后点击已发送的链接打开"
        } label: {
          Text(ticket.url.absoluteString).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            .multilineTextAlignment(.center).lineLimit(3)
        }
        .buttonStyle(.plain)
      }
    }
  }
  private func qrImage(_ url: URL) -> UIImage? { LoginQRCode.render(url.absoluteString) }
  @MainActor private func saveQR(_ image: UIImage, ticket: URL, expiry: Date) async {
    guard Date() < expiry else { return }
    let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard permission == .authorized || permission == .limited else { note = "未获准保存到照片"; return }
    guard flow.ticket?.url == ticket, Date() < expiry else { return }
    do { try await LoginQRCode.save(image); note = "二维码已保存" }
    catch { note = error.localizedDescription }
  }
}

/// 200pt white QR tile with a loading placeholder.
struct LoginQRCode: View {
  let image: UIImage?
  var loading = false
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white)
      if let image {
        Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding(12)
      } else if loading {
        ProgressView().tint(.gray)
      } else {
        Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(.gray.opacity(0.35))
      }
    }
    .frame(width: 220, height: 220)
    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    .accessibilityLabel("登录二维码")
  }
  static func render(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: .init(scaleX: 6, y: 6)),
      let cg = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return UIImage(cgImage: cg)
  }
  static func save(_ image: UIImage) async throws {
    let out = UIGraphicsImageRenderer(size: .init(width: 660, height: 660)).image { context in
      UIColor.white.setFill()
      context.fill(.init(x: 0, y: 0, width: 660, height: 660))
      context.cgContext.interpolationQuality = .none
      image.draw(in: .init(x: 46, y: 46, width: 568, height: 568))
    }
    try await PHPhotoLibrary.shared().performChanges {
      PHAssetChangeRequest.creationRequestForAsset(from: out)
    }
  }
}

/// Square checkbox toggle ("显示密码").
struct LoginCheckbox: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    Button { configuration.isOn.toggle() } label: {
      HStack(spacing: 8) {
        Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
          .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
          .contentTransition(.symbolEffect(.replace))
        configuration.label.foregroundStyle(.primary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
  }
}

private struct LoginRegionPicker: View {
  @Binding var selected: LoginRegion
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  private var filtered: [LoginRegion] {
    let term = search.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "+", with: "")
    return term.isEmpty ? LoginRegion.all : LoginRegion.all.filter { $0.name.localizedCaseInsensitiveContains(term) || String($0.code).contains(term) }
  }
  var body: some View {
    List(filtered) { region in
      Button { selected = region; dismiss() } label: {
        HStack {
          Text(region.name)
          Spacer()
          Text("+\(region.code)").monospacedDigit().foregroundStyle(.secondary)
          if selected == region { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
      }.tint(.primary)
    }.navigationTitle("国际冠码").searchable(text: $search, prompt: "名称或区号")
  }
}
