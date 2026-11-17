import CoreImage.CIFilterBuiltins
import Photos
import SwiftUI

struct MobileClientLoginView: View {
  var expectedUID: String? = nil
  @State private var method = NativeLoginMethod.qr
  var body: some View {
    VStack(spacing: 0) {
      Picker("登录方式", selection: $method) {
        ForEach(NativeLoginMethod.allCases) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 8)
      NativeLoginForm(method: method, expectedUID: expectedUID).id(method)
    }.navigationTitle(expectedUID == nil ? "登录" : "移动端授权").navigationBarTitleDisplayMode(.inline)
  }
}
struct NativeLoginForm: View {
  let method: NativeLoginMethod
  @StateObject private var flow: NativeLoginFlow
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var username = ""
  @State private var password = ""
  @State private var phone = ""
  @State private var code = ""
  @State private var region = LoginRegion.all[0]
  @State private var note: String?
  init(method: NativeLoginMethod, expectedUID: String?) {
    self.method = method
    _flow = StateObject(wrappedValue: NativeLoginFlow(expectedUID: expectedUID))
  }
  var body: some View {
    Form {
      if flow.risk != nil {
        Section("验证已绑定的手机号") {
          Text(flow.maskedPhone)
          smsCode
          sendButton { flow.sendRiskSMS() }
          Button("验证并登录") { flow.verifyRisk(code) }.disabled(flow.busy || code.isEmpty)
          Button("返回登录") { code = ""; flow.leaveRisk() }.disabled(flow.busy)
        }
      } else {
        switch method {
        case .qr: qr
        case .password:
          Section {
            TextField("手机号或邮箱", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(flow.busy)
            SecureField("密码", text: $password).textContentType(.password).privacySensitive().disabled(flow.busy)
            Button("登录") { flow.password(username.trimmingCharacters(in: .whitespacesAndNewlines), password) }
              .disabled(flow.busy || username.isEmpty || password.isEmpty)
          }
        case .sms:
          Section {
            NavigationLink { LoginRegionPicker(selected: $region) } label: {
              LabeledContent("国家或地区", value: region.name + " +" + String(region.code))
            }
            TextField("手机号", text: $phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
              .onChange(of: phone) { _, _ in code = ""; flow.changedPhone() }
            smsCode
            sendButton { flow.sendSMS(phone, region.code) }
            Button("登录") { flow.sms(phone, region.code, code) }.disabled(flow.busy || phone.isEmpty || code.isEmpty)
          }.onChange(of: region) { _, _ in code = ""; flow.changedPhone() }
        }
      }
      if flow.busy { ProgressView() }
      if let issue = flow.issue { Text(issue).foregroundStyle(.secondary) }
    }.onAppear { flow.activate(); if method == .qr { flow.startQR() } }
      .onDisappear { flow.cancel(); password = ""; code = "" }
      .piliSheet(item: $flow.captcha, onDismiss: { flow.closedCaptcha() }) { challenge in
        GeetestView(challenge: challenge) { flow.solved($0, challengeID: challenge.id) }
      }
      .onChange(of: flow.completedUID) { _, uid in
        guard uid != nil else { return }
        password = ""; code = ""
        Task { await accounts.refresh(); dismiss() }
      }
      .alert("扫码登录", isPresented: .init(get: { note != nil }, set: { if !$0 { note = nil } })) {
        Button("好") {}
      } message: { Text(note ?? "") }
  }
  private var smsCode: some View {
    TextField("短信验证码", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).privacySensitive()
  }
  private func sendButton(_ action: @escaping () -> Void) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { clock in
      let left = max(0, Int(ceil((flow.cooldown ?? .distantPast).timeIntervalSince(clock.date))))
      Button(left > 0 ? "\(left) 秒后重发" : "获取验证码", action: action).disabled(flow.busy || left > 0)
    }
  }
  @ViewBuilder private var qr: some View {
    Section {
      VStack(spacing: 16) {
        if let ticket = flow.ticket, let image = qrImage(ticket.url) {
          Image(uiImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 220, height: 220)
            .padding(14).background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
          if let expiry = flow.expiry {
            TimelineView(.periodic(from: .now, by: 1)) { time in
              Text("剩余 \(max(0, Int(ceil(expiry.timeIntervalSince(time.date))))) 秒").font(.caption.monospacedDigit())
            }
            Menu("二维码") {
              Button("保存到照片") { Task { await saveQR(image, ticket: ticket.url, expiry: expiry) } }
              Button("复制登录链接") {
                guard Date() < expiry else { return }
                UIPasteboard.general.setItems([["public.utf8-plain-text": ticket.url.absoluteString]], options: [.localOnly: true, .expirationDate: expiry])
                note = "已复制登录链接"
              }
              Button("使用哔哩哔哩打开") {
                guard Date() < expiry else { return }
                OfficialAppHandoff.shared.open(ticket.url) { note = "未能打开哔哩哔哩，可保存二维码后在哔哩哔哩中扫一扫" }
              }
            }
          }
        }
        Text(flow.status).multilineTextAlignment(.center)
        Button("刷新二维码") { flow.startQR() }.disabled(flow.busy)
      }.frame(maxWidth: .infinity).padding(.vertical)
    }
  }
  private func qrImage(_ url: URL) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator(); filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: .init(scaleX: 6, y: 6)), let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cg)
  }
  @MainActor private func saveQR(_ image: UIImage, ticket: URL, expiry: Date) async {
    guard Date() < expiry else { return }
    let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard permission == .authorized || permission == .limited else { note = "未获准保存到照片"; return }
    guard flow.ticket?.url == ticket, Date() < expiry else { return }
    let out = UIGraphicsImageRenderer(size: .init(width: 660, height: 660)).image { context in
      UIColor.white.setFill(); context.fill(.init(x: 0, y: 0, width: 660, height: 660)); context.cgContext.interpolationQuality = .none
      image.draw(in: .init(x: 46, y: 46, width: 568, height: 568))
    }
    do { try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: out) }; note = "二维码已保存" }
    catch { note = error.localizedDescription }
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
        HStack { Text(region.name); Spacer(); Text("+\(region.code)").foregroundStyle(.secondary); if selected == region { Image(systemName: "checkmark") } }
      }.tint(.primary)
    }.navigationTitle("国家或地区").searchable(text: $search, prompt: "名称或区号")
  }
}
