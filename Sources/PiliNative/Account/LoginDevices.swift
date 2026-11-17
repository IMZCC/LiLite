import SwiftUI

struct LoginDeviceRecord: Decodable {
  let device_name: String?, is_current_device: Bool?, latest_login_at: String?, source: String?
}
extension BiliAPI {
  func loginDevices(_ user: String) async throws -> [LoginDeviceRecord] {
    guard let account = try await AccountJar.shared.current(credentials:.both), account.id == user,
      let csrf = account.csrf
    else { throw ServiceError("请重新登录") }
    guard let token = account.mobileToken, !token.isEmpty else { throw ServiceError("请先完成移动端授权") }
    let device = MobileDeviceID.use(account.archiveDevice)
    let q = try MobilePassport.deviceListRequest(csrf: csrf, token: token, buvid: device, cookie: account.header)
    let data: Data
    let response: URLResponse
    do { (data, response) = try await webResponse(q, identity: account) } catch {
      throw ServiceError("无法连接账号安全中心")
    }
    struct Envelope: Decodable {
      let code: Int, message: String?, data: Body?
      struct Body: Decodable { let devices: [LoginDeviceRecord]? }
    }
    let result = try JSONDecoder().decode(Envelope.self, from: data)
    guard (response as? HTTPURLResponse)?.statusCode == 200, result.code == 0,
      let body = result.data
    else { throw ServiceError(result.message ?? "无法读取登录设备") }
    try Task.checkCancellation()
    let fresh = try await AccountJar.shared.current(credentials: .both)
    guard fresh?.id == user, fresh?.mobileToken == token, fresh?.header == account.header,
      MobileDeviceID.use(fresh?.archiveDevice) == device else { throw ServiceError("账号授权已变更") }
    return body.devices ?? []
  }
}
struct LoginDevices: View {
  let uid: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var appMissing=false
  @State private var rows: [LoginDeviceRecord]?
  @State private var issue: String?
  @State private var request = 0
  var body: some View {
    List {
      if let rows {
        Section {
          ForEach(Array(rows.enumerated()), id: \.offset) { _, d in
            HStack(spacing: 14) {
              Image(systemName: Self.symbol(d.device_name ?? ""))
                .font(.title3).foregroundStyle(.white).frame(width: 40, height: 40)
                .background(d.is_current_device == true ? Color.accentColor : Color.gray,
                  in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                  Text(d.device_name ?? "设备").font(.body.weight(.medium)).lineLimit(1)
                  if d.is_current_device == true {
                    Text("本机").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                      .padding(.horizontal, 6).padding(.vertical, 1.5)
                      .background(Color.accentColor.opacity(0.12), in: Capsule())
                  }
                }
                Text([d.latest_login_at, d.source].compactMap { $0 }.joined(separator: " · "))
                  .font(.caption).foregroundStyle(.secondary)
              }
            }.padding(.vertical, 2)
          }
          if rows.isEmpty { Text("没有登录设备记录").foregroundStyle(.secondary) }
        } footer: {
          if !rows.isEmpty { Text("这些设备最近登录过你的账号。") }
        }
      } else if issue == nil {
        PageLoading()
      }
      if let issue {
        PageFailure(message: issue) { request += 1 }
        if let owner = accounts.state.accounts.first(where: { $0.id == uid }),
          owner.mobileToken == nil
        {
          NavigationLink("移动端授权") { MobileAuthorization(uid: uid) }
        }
      }
      if accounts.state.active == uid {
        Section {
          Button("在哔哩哔哩查看登录设备") {
            OfficialAppHandoff.shared.open(URL(string:"https://account.bilibili.com/h5/account-h5/device")!){appMissing=true}
          }
        }
      }
    }.alert("未能打开哔哩哔哩",isPresented:$appMissing){Button("好"){}}
    .navigationTitle("登录设备").piliRefreshable { await load() }.task(
      id: "\(uid):\(accounts.state.active ?? ""):\(request):\(accounts.state.accounts.first{$0.id==uid}?.mobileToken != nil)"
    ) { await load() }
  }
  private static func symbol(_ name: String) -> String {
    let n = name.lowercased()
    if n.contains("ipad") || n.contains("pad") { return "ipad" }
    if n.contains("iphone") || n.contains("phone") || n.contains("android") || n.contains("手机") { return "iphone" }
    if n.contains("mac") || n.contains("windows") || n.contains("pc") || n.contains("web") || n.contains("浏览器") { return "desktopcomputer" }
    if n.contains("tv") || n.contains("电视") { return "tv" }
    return "iphone"
  }
  @MainActor private func load() async {
    guard accounts.state.active == uid else { rows = nil; issue = "账号已切换"; return }
    do {
      let items = try await BiliAPI.shared.loginDevices(uid)
      try Task.checkCancellation()
      rows = items
      issue = nil
    } catch {
      if !Task.isCancelled {
        rows = nil
        issue = error.localizedDescription
      }
    }
  }
}
