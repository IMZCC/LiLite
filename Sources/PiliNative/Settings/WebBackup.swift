import CryptoKit
import Foundation
import Security
import SwiftUI

enum DAVSecrets {
  static func query(_ location: DAVLocation, user: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PiliNative.WebDAV",
      kSecAttrAccount as String: location.base.absoluteString + "\n" + user,
    ]
  }
  static func password(_ location: DAVLocation, user: String) -> String {
    (try? readPassword(location, user: user)) ?? ""
  }
  static func readPassword(_ location: DAVLocation, user: String) throws -> String {
    var q = query(location, user: user)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    if status == errSecItemNotFound { return "" }
    guard status == errSecSuccess, let d = item as? Data else {
      throw ServiceError("无法读取 WebDAV 密码")
    }
    return String(decoding: d, as: UTF8.self)
  }
  static func save(_ password: String, location: DAVLocation, user: String) throws {
    let q = query(location, user: user)
    let result: OSStatus
    if password.isEmpty {
      result = SecItemDelete(q as CFDictionary)
      if result == errSecItemNotFound { return }
    } else {
      let data = Data(password.utf8)
      let r = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      if r == errSecItemNotFound {
        var a = q
        a[kSecValueData as String] = data
        a[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        result = SecItemAdd(a as CFDictionary, nil)
      } else {
        result = r
      }
    }
    guard result == errSecSuccess else { throw ServiceError("未能保存 WebDAV 密码") }
  }
}
struct WebBackup: View {
  private static let decodedDraft = DecodedSettingCache<PackServerProfile.Pending?>()
  @AppStorage("backup.dav.url") private var savedAddress = ""
  @AppStorage("backup.dav.user") private var savedUser = ""
  @AppStorage("backup.dav.directory") private var savedDir = "/"
  @AppStorage(PackServerProfile.pendingKey) private var draftBytes = Data()
  @State private var activeDraft: PackServerProfile.Pending?
  @State private var address = ""
  @State private var loaded = false
  @State private var user = ""
  @State private var directory = "/"
  @State private var password = ""
  @State private var busy = false
  @State private var confirm = false
  @State private var privateOverwrite: Overwrite?
  @State private var message: String?
  @State private var pending: SettingsRestore?
  private var tablet: Bool { UIDevice.current.userInterfaceIdiom == .pad }
  private var profileKey: String { address + "\n" + user + "\n" + directory }
  private var location: DAVLocation? {
    try? DAVLocation(address: address, directory: directory, tablet: tablet)
  }
  var body: some View {
    Form {
      if let draft = Self.decodedDraft.value(for: draftBytes, decode: { try? JSONDecoder().decode(PackServerProfile.Pending.self, from: $0) }) {
        Section("从备份导入的配置") {
          LabeledContent("服务器", value: draft.address)
          if !draft.user.isEmpty { LabeledContent("用户", value: draft.user) }
          Button("填入服务器设置") {
            do {
              let secret = try PackServerProfile.pendingPassword(draft)
              activeDraft = draft
              address = draft.address
              user = draft.user
              directory = draft.directory
              password = secret
            } catch { message = error.localizedDescription }
          }
          Button("丢弃导入的配置", role: .destructive) {
            do {
              try PackServerProfile.discard(draft)
              draftBytes = Data()
              activeDraft = nil
              loadPassword()
            } catch { message = error.localizedDescription }
          }
        }
      }
      Section("服务器") {
        TextField("服务器地址", text: $address).keyboardType(.URL).textContentType(.URL)
        TextField("用户名", text: $user).textContentType(.username)
        SecureField("密码或应用专用密码", text: $password).textContentType(.password)
        if location?.folders.isEmpty != true { TextField("备份目录", text: $directory) }
        if let url = location?.base, let origin = PrivateServiceOrigin(.dav, url) {
          NavigationLink("服务器证书") { DeferredPage { PrivateTrustPanel(origin: origin).id(origin) } }
        }
        Button("验证并保存") { Task { await run(.verify) } }
      }.textInputAutocapitalization(.never).autocorrectionDisabled()
      Section {
        Button("备份到 WebDAV") { confirm = true }
        Button("从 WebDAV 恢复") { Task { await run(.restore) } }
        if let target = location {
          NavigationLink("管理远程备份") {
            DAVLibrary(connection: .init(target: target, user: user, password: password)).id(
              profileKey)
          }
        }
      } footer: {
        if activeDraft != nil {
          Text("请先验证并保存导入的配置")
        } else if let location {
          Text(location.file.path(percentEncoded: false)).textSelection(.enabled)
        }
      }
      .disabled(activeDraft != nil)
      if busy { ProgressView() }
      if let message { Text(message) }
    }.navigationTitle("WebDAV").disabled(busy)
      .onAppear {
        guard !loaded else { return }
        loaded = true
        address = savedAddress
        user = savedUser
        directory = savedDir
        loadPassword()
      }
      .onChange(of: address) { _, _ in loadPassword() }.onChange(of: user) { _, _ in loadPassword()
      }
      .confirmationDialog("将当前设置写入远程文件？", isPresented: $confirm) {
        Button("备份") { Task { await run(.backup) } }
      }
      .confirmationDialog(
        "覆盖含私人凭据的旧备份？",
        isPresented: Binding(
          get: { privateOverwrite != nil }, set: { if !$0 { privateOverwrite = nil } }),
        presenting: privateOverwrite
      ) { item in
        Button("覆盖为普通设置备份", role: .destructive) { Task { await run(.backup, approved: item) } }
        if location?.folders.isEmpty == false {
          Button("保留旧备份并另存") { Task { await run(.snapshot) } }
        }
      } message: { _ in
        Text("覆盖将移除旧文件里的密码和贡献身份")
      }
      .confirmationDialog(
        "用远程备份恢复设置？",
        isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        presenting: pending
      ) { item in
        Button("恢复") {
          Task {
            do {
              try await Task.detached(priority: .userInitiated) { try item.apply() }.value
              message = "已恢复设置"
            } catch { message = error.localizedDescription }
          }
        }
      } message: { item in
        Text(item.summary)
      }
  }
  private func loadPassword() {
    if let d = activeDraft, d.address == address, d.user == user { return }
    activeDraft = nil
    let location = location, user = user, key = profileKey, previous = password
    Task {
      let secret = await Task.detached(priority: .utility) {
        location.map { DAVSecrets.password($0, user: user) } ?? ""
      }.value
      if profileKey == key, password == previous, activeDraft == nil { password = secret }
    }
  }
  private struct Overwrite: Error, Equatable { let url: URL, user: String, digest: Data }
  private enum Action { case verify, backup, snapshot, restore }
  @MainActor private func run(_ action: Action, approved: Overwrite? = nil) async {
    guard !busy else { return }
    busy = true
    message = nil
    defer { busy = false }
    do {
      let target = try DAVLocation(address: address, directory: directory, tablet: tablet)
      let restored = try await Self.perform(action, target: target, user: user, password: password, approved: approved)
      switch action {
      case .verify:
          savedAddress = address
          savedUser = user
          savedDir = directory
          if let d = activeDraft, d.address == address, d.user == user {
            try await Task.detached(priority: .utility) { try PackServerProfile.discard(d) }.value
            draftBytes = Data()
            activeDraft = nil
          }
          message = "已验证并保存"
      case .backup: message = "设置已备份"
      case .snapshot: message = "已另存设置备份"
      case .restore: pending = restored
      }
    } catch let request as Overwrite { privateOverwrite = request } catch {
      message = error.localizedDescription
    }
  }
  nonisolated private static func perform(_ action: Action, target: DAVLocation, user: String,
    password: String, approved: Overwrite?) async throws -> SettingsRestore? {
    try await DAVConnection(target: target, user: user, password: password).withStore { store in
      switch action {
      case .verify:
        try await store.prepare()
        try DAVSecrets.save(password, location: target, user: user)
      case .backup:
          let prefs = NativePrefs.current()
          try await store.write { old in
            if let old, try SettingsRestore(old, current: prefs).hasPrivateParts {
              let challenge = Overwrite(
                url: target.file, user: user, digest: Data(SHA256.hash(data: old)))
              guard approved == challenge else { throw challenge }
            }
            return try prefs.archive(over: old)
          }
        case .snapshot:
          try await store.snapshot(NativePrefs.current().archive(), encrypted: false)
        case .restore: return try await SettingsRestore(store.read())
        }
      return nil
    }
  }
}

struct DAVConnection {
  let target: DAVLocation, user: String, password: String
  func withStore<T>(_ work: (DAVStore) async throws -> T) async throws -> T {
    let config = URLSessionConfiguration.ephemeral
    config.urlCredentialStorage = nil
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let delegate = try PrivateServiceDelegate(service: .dav, url: target.base, denyRedirect: true, user: user, password: password)
    let s = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    defer { s.invalidateAndCancel() }
    let store = DAVStore(location: target, user: user, password: password) { req in
      let authentication = SelfHostedHTTPAuthentication(origin: target.base, user: user, password: password)
      var request = req
      var reply: (URLSession.AsyncBytes, URLResponse)?
      for _ in 0..<3 {
        let result = try await s.bytes(for: request)
        if let http = result.1 as? HTTPURLResponse, http.statusCode == 401,
          let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate"),
          let next = try authentication.retry(request, challenge: challenge) {
          var size = 0
          for try await _ in result.0 { size += 1; guard size <= 16384 else { throw ServiceError("服务器认证响应过大") } }
          request = next; continue
        }
        reply = result; break
      }
      guard let (stream, response) = reply else { throw ServiceError("服务器认证失败") }
      guard let http = response as? HTTPURLResponse else { throw ServiceError("WebDAV 响应无效") }
      var bytes = Data()
      if http.statusCode == 200 || http.statusCode == 207 {
        let limit =
          req.httpMethod == "PROPFIND"
          ? 1_048_576
          : (req.url?.pathExtension == "pilipack"
            ? DataPackCipher.bodyLimit + DataPackCipher.overhead : BackupFormat.limit)
        guard http.expectedContentLength <= limit else {
          throw ServiceError("远程文件过大")
        }
        for try await b in stream {
          guard bytes.count < limit else { throw ServiceError("远程文件过大") }
          bytes.append(b)
        }
      }
      return DAVReply(
        status: http.statusCode, data: bytes, etag: http.value(forHTTPHeaderField: "ETag"),
        modified: http.value(forHTTPHeaderField: "Last-Modified"), date: http.value(forHTTPHeaderField:"Date"))
    }
    return try await work(store)
  }
}
