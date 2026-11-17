import PiliArchive
import SwiftUI
import UniformTypeIdentifiers

private struct PackFile: FileDocument {
  static var readableContentTypes: [UTType] { [.zip, .data] }
  let bytes: Data
  init(_ bytes: Data) { self.bytes = bytes }
  init(configuration: ReadConfiguration) throws {
    guard let bytes = configuration.file.regularFileContents,
      bytes.count <= PortableArchive.limit + DataPackCipher.overhead
    else { throw ServiceError("数据包过大") }
    self.bytes = bytes
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    .init(regularFileWithContents: bytes)
  }
}
struct DataPackPanel: View {
  var upload: ((Data) async throws -> Void)? = nil
  var remoteSource: (() async throws -> Data)? = nil
  @EnvironmentObject private var accounts: AccountContext
  @State private var selected = Set(PackPart.allCases.filter { !$0.sensitive })
  @State private var secure = true
  @State private var password = ""
  @State private var repeatPassword = ""
  @State private var pick = false
  @State private var share = false
  @State private var busy = false
  @State private var confirmPlain = false
  @State private var encrypted: Data?
  @State private var preview: PackPreview?
  @State private var file: PackFile?
  @State private var message: String?
  var body: some View {
    Form {
      if remoteSource == nil, encrypted == nil {
        Section("导出内容") {
          ForEach(PackPart.allCases) { p in
            Toggle(
              p.title,
              isOn: Binding(
                get: { selected.contains(p) },
                set: { if $0 { selected.insert(p) } else { selected.remove(p) } }))
          }
        }
        Section("文件格式") {
          if upload == nil {
            Picker("格式", selection: $secure) {
              Text("加密数据包").tag(true)
              Text("原版兼容 ZIP").tag(false)
            }
          }
          if secure || upload != nil {
            SecureField("备份密码（至少 10 个字符）", text: $password)
            SecureField("再次输入密码", text: $repeatPassword)
            Text("换设备恢复也需要此密码，请妥善保存").font(.footnote).foregroundStyle(.secondary)
          } else if selected.contains(where: \.sensitive) {
            Text("普通 ZIP 内的登录凭据可被持有文件的人读取").foregroundStyle(.secondary)
          }
          Button(upload == nil ? "导出数据包" : "上传加密数据包") {
            if !secure && upload == nil && selected.contains(where: \.sensitive) {
              confirmPlain = true
            } else {
              Task { await make() }
            }
          }.disabled(selected.isEmpty)
        }
      }
      if let bytes = encrypted {
        Section("解锁数据包") {
          SecureField("输入备份密码", text: $password)
          Button("解锁并预览") { Task { await unlock(bytes) } }.disabled(password.isEmpty)
          Button("取消") {
            encrypted = nil
            password = ""
          }
        }
      } else if let remoteSource {
        Button("读取并预览数据包") { Task { await read(remoteSource) } }
      } else if upload == nil {
        Button("从数据包恢复") { pick = true }
      }
      if busy { ProgressView() }
      if let message { Text(message).textSelection(.enabled) }
    }.disabled(busy).navigationTitle(upload != nil || remoteSource != nil ? "远程数据包" : "本地数据包")
      .confirmationDialog("将未加密的登录凭据写入 ZIP？", isPresented: $confirmPlain) {
        Button("导出普通 ZIP", role: .destructive) { Task { await make() } }
      }
      .fileExporter(
        isPresented: $share, document: file, contentType: secure ? .data : .zip,
        defaultFilename: "LiLite-"
          + Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
          + (secure ? ".pilipack" : ".zip")
      ) { result in
        if case .failure(let error) = result { message = error.localizedDescription }
        file = nil
      }
      .fileImporter(isPresented: $pick, allowedContentTypes: [.zip, .data]) { result in
        do {
          let url = try result.get()
          Task {
            await read {
              try await Task.detached(priority: .userInitiated) {
                let grant = url.startAccessingSecurityScopedResource()
                defer { if grant { url.stopAccessingSecurityScopedResource() } }
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= PortableArchive.limit + DataPackCipher.overhead
                else { throw ServiceError("请选择不超过 64 MB 的数据包") }
                return try Data(contentsOf: url, options: .mappedIfSafe)
              }.value
            }
          }
        } catch { message = error.localizedDescription }
      }
      .piliSheet(item: $preview) { item in
        PackRestorePanel(
          item: item, localIDs: accounts.state.accounts.map(\.id),
          expectedMain: accounts.state.active
        ) { chosen, owner, main in
          preview = nil
          busy = true
          defer { busy = false }
          do {
            message = try await DataPack.restore(
              item, selected: chosen, replyOwner: owner, expectedMain: main)
            await accounts.refresh()
          } catch { message = error.localizedDescription }
        }
      }
      .onDisappear {
        password = ""
        repeatPassword = ""
      }
  }
  @MainActor private func make() async {
    guard !busy else { return }
    busy = true
    message = nil
    defer { busy = false }
    do {
      let protect = secure || upload != nil
      let key = password
      if protect, key.count < 10 || key != repeatPassword {
        throw ServiceError("密码至少需要 10 个字符，且两次输入须相同")
      }
      let zip = try await DataPack.make(
        selected, prefs: .current(),
        platform: UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone",
        compatible: !protect)
      let bytes =
        protect
        ? try await Task.detached { try DataPackCipher.encrypt(zip, password: key) }.value : zip
      password = ""
      repeatPassword = ""
      if let upload {
        try await upload(bytes)
        message = "已上传加密数据包"
      } else {
        file = PackFile(bytes)
        share = true
      }
    } catch { message = error.localizedDescription }
  }
  @MainActor private func read(_ source: () async throws -> Data) async {
    guard !busy else { return }
    busy = true
    message = nil
    password = ""
    repeatPassword = ""
    defer { busy = false }
    do {
      let bytes = try await source()
      if DataPackCipher.sealed(bytes) {
        encrypted = bytes
      } else {
        preview = try await Task.detached { try PackPreview(bytes) }.value
      }
    } catch { message = error.localizedDescription }
  }
  @MainActor private func unlock(_ bytes: Data) async {
    guard !busy else { return }
    busy = true
    message = nil
    defer { busy = false }
    let key = password
    do {
      preview = try await Task.detached {
        try PackPreview(DataPackCipher.decrypt(bytes, password: key))
      }.value
      encrypted = nil
      password = ""
    } catch { message = error.localizedDescription }
  }
}
private struct PackRestorePanel: View {
  let item: PackPreview, localIDs: [String], expectedMain: String?,
    restore: (Set<PackPart>, String?, String?) async -> Void
  @State private var chosen: Set<PackPart>
  @State private var viewedMain: String?
  @State private var owner: String
  @Environment(\.dismiss) private var dismiss
  init(
    item: PackPreview, localIDs: [String], expectedMain: String?,
    restore: @escaping (Set<PackPart>, String?, String?) async -> Void
  ) {
    self.item = item
    self.localIDs = localIDs
    self.expectedMain = expectedMain
    self.restore = restore
    _chosen = State(initialValue: Set(item.choices.filter { !$0.sensitive }))
    _viewedMain = State(initialValue: expectedMain)
    _owner = State(initialValue: item.zip.replyOwner ?? "")
  }
  private var ids: [String] {
    Set(localIDs).union(chosen.contains(.accounts) ? item.importedIDs : []).sorted()
  }
  private var hasReplies: Bool {
    guard chosen.contains(.replies), let data = item.zip.parts[PackPart.replies.rawValue] else {
      return false
    }
    return !data.lazy.filter { ![9, 10, 13, 32].contains($0) }.elementsEqual([91, 93])
  }
  var body: some View {
    PiliNavigationStack {
      Form {
        Section("要恢复的内容") {
          ForEach(item.choices) { p in
            Toggle(
              p.title,
              isOn: Binding(
                get: { chosen.contains(p) },
                set: { if $0 { chosen.insert(p) } else { chosen.remove(p) } }))
          }
        }
        if hasReplies {
          Section("评论归属") {
            if let known = item.zip.replyOwner {
              LabeledContent("所属账号", value: "UID " + known)
              if !ids.contains(known) { Text("请同时导入所属账号，或取消恢复评论").foregroundStyle(.secondary) }
            } else {
              Picker("选择所属账号", selection: $owner) {
                Text("请选择").tag("")
                ForEach(ids, id: \.self) { Text("UID " + $0).tag($0) }
              }
            }
          }
        }
        if chosen.contains(where: \.sensitive) {
          Text("将导入登录凭据，请确认数据包来自可信来源").foregroundStyle(.secondary)
        }
        if chosen.contains(.contributor), let box = item.settingsBox,
          let id = try? PackContributor.read(box)
        {
          LabeledContent("贡献身份所属服务器", value: id.base.absoluteString)
        }
        if chosen.contains(.server) {
          Text("导入后，请在 WebDAV 设置中核对并验证服务器").foregroundStyle(.secondary)
        }
        if chosen.contains(.settings), let bytes = item.zip.parts[PackPart.settings.rawValue],
          let p = try? SettingsRestore(bytes), let proxy = p.settings.apiProxy, proxy.enabled
        {
          LabeledContent("将使用接口代理", value: proxy.endpoint)
        }
        Section("来源") {
          if let p = item.zip.platform {
            LabeledContent("设备", value: ["phone": "手机", "pad": "平板", "desktop": "电脑"][p] ?? p)
          }
          if let v = item.zip.sourceVersion { LabeledContent("版本", value: v) }
          if let date = item.zip.exportedAt { LabeledContent("导出时间", value: date) }
          if let warning = item.warning { Label(warning, systemImage: "exclamationmark.triangle") }
        }
        Button("恢复所选数据") { Task { await restore(chosen, owner.isEmpty ? nil : owner, viewedMain) } }
          .disabled(chosen.isEmpty || (hasReplies && !ids.contains(owner)))
      }.navigationTitle("恢复数据包").toolbar { Button("取消") { dismiss() } }
    }
  }
}
