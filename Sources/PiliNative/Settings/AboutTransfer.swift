import PiliArchive
import SwiftUI
import UniformTypeIdentifiers

enum AboutPayload: String, Identifiable {
  case settings = "设置"
  case accounts = "登录信息"
  var id: Self { self }
}
private struct RawTransferFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  let bytes: Data
  init(_ bytes: Data) { self.bytes = bytes }
  init(configuration: ReadConfiguration) throws {
    guard let d = configuration.file.regularFileContents, d.count <= PortableArchive.limit else {
      throw ServiceError("文件过大")
    }
    bytes = d
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    .init(regularFileWithContents: bytes)
  }
}
struct AboutTransfer: View {
  let kind: AboutPayload
  @EnvironmentObject private var accounts: AccountContext
  @State private var pending: Data?
  @State private var preview = ""
  @State private var manual = false
  @State private var text = ""
  @State private var output: RawTransferFile?
  @State private var saveFile = false
  @State private var readFile = false
  @State private var destination: ExportAction?
  @State private var busy = false
  @State private var message: String?
  @State private var generation: UInt64?
  private enum ExportAction: Identifiable {
    case file, clipboard
    var id: Self { self }
  }
  private var limit: Int { kind == .accounts ? PortableArchive.limit : BackupFormat.limit }
  var body: some View {
    Form {
      Section {
        Button { startExport(.file) } label: {
          SettingsRowLabel(title: "保存 JSON 文件", symbol: "square.and.arrow.down", color: .blue)
        }
        Button { startExport(.clipboard) } label: {
          SettingsRowLabel(title: "复制到剪贴板", symbol: "doc.on.clipboard", color: .blue)
        }
      } header: {
        Text("导出")
      } footer: {
        if kind == .accounts { Text("导出的登录信息未加密，请妥善保管") }
      }
      Section("导入") {
        Button { readFile = true } label: {
          SettingsRowLabel(title: "选择文件", symbol: "folder", color: .green)
        }
        Button { Task { await captureClipboard() } } label: {
          SettingsRowLabel(title: "从剪贴板导入", symbol: "list.clipboard", color: .green)
        }
        Button {
          text = ""
          manual = true
        } label: {
          SettingsRowLabel(title: "手动输入", symbol: "keyboard", color: .green)
        }
      }
      if busy || message != nil {
        Section {
          if busy { ProgressView().frame(maxWidth: .infinity) }
          if let message { Text(message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
        }
      }
    }.disabled(busy).navigationTitle(kind.rawValue + "导入与导出").navigationBarTitleDisplayMode(.inline)
      .confirmationDialog(
        "导出未加密的登录信息？",
        isPresented: Binding(get: { destination != nil }, set: { if !$0 { destination = nil } }),
        presenting: destination
      ) { d in
        Button(d == .file ? "保存文件" : "复制到此设备", role: .destructive) { Task { await export(d) } }
      } message: { _ in
        Text("持有内容的人可能使用这些账号")
      }
      .fileExporter(
        isPresented: $saveFile, document: output, contentType: .json,
        defaultFilename: "lilite_" + (kind == .accounts ? "account" : "setting_phone")
      ) { result in
        output = nil
        if case .failure(let e) = result { message = e.localizedDescription }
      }
      .fileImporter(isPresented: $readFile, allowedContentTypes: [.json, .plainText]) { result in
        do {
          let u = try result.get()
          Task {
            await stage {
              let access = u.startAccessingSecurityScopedResource()
              defer { if access { u.stopAccessingSecurityScopedResource() } }
              guard let size = try u.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit
              else { throw ServiceError("文件过大") }
              return try Data(contentsOf: u)
            }
          }
        } catch { message = error.localizedDescription }
      }
      .piliSheet(isPresented: $manual) {
        PiliNavigationStack {
          Form {
            Section("输入 JSON") {
              TextEditor(text: $text).font(.body.monospaced()).textInputAutocapitalization(.never)
                .autocorrectionDisabled().frame(minHeight: 160)
            }
          }
          .navigationTitle("输入" + kind.rawValue)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("取消") {
                text = ""
                manual = false
              }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("预览") {
                let value = text
                text = ""
                manual = false
                Task { await stage { Data(value.utf8) } }
              }.disabled(text.isEmpty)
            }
          }
        }
      }
      .confirmationDialog(
        "导入" + kind.rawValue + "？",
        isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        presenting: pending
      ) { data in
        Button("确定导入") { Task { await restore(data) } }
      } message: { _ in
        Text(preview)
      }
  }
  private func startExport(_ action: ExportAction) {
    if kind == .accounts { destination = action } else { Task { await export(action) } }
  }
  @MainActor private func export(_ action: ExportAction) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    message = nil
    do {
      let bytes: Data
      if kind == .accounts {
        try await PackAuthorization.verify("导出登录账号")
        bytes = try await AccountJar.shared.archiveData()
      } else {
        bytes = try NativePrefs.current().archive()
      }
      if action == .file {
        output = .init(bytes)
        saveFile = true
      } else if let value = String(data: bytes, encoding: .utf8) {
        if kind == .accounts {
          UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        } else {
          UIPasteboard.general.string = value
        }
        message = "已复制"
      }
    } catch { message = error.localizedDescription }
  }
  @MainActor private func captureClipboard() async {
    await stage {
      guard let s = UIPasteboard.general.string, !s.isEmpty else { throw ServiceError("剪贴板没有文本") }
      return Data(s.utf8)
    }
  }
  @MainActor private func stage(_ load: () throws -> Data) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    message = nil
    do {
      let bytes = try load()
      guard bytes.count <= limit else { throw ServiceError("文件过大") }
      if kind == .accounts {
        let items = try ArchiveAccount.decode(bytes)
        guard !items.isEmpty else { throw ServiceError("文件中没有账号") }
        preview = "将合并账号：" + items.keys.sorted().joined(separator: "、")
        generation = try await AccountJar.shared.packStamp().generation
      } else {
        preview = try SettingsRestore(bytes).summary
      }
      pending = bytes
    } catch { message = error.localizedDescription }
  }
  @MainActor private func restore(_ bytes: Data) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    message = nil
    do {
      if kind == .accounts {
        try await PackAuthorization.verify("导入登录账号")
        guard let generation else { throw ServiceError("请重新预览账号") }
        try await AccountJar.shared.mergeArchive(
          ArchiveAccount.decode(bytes), expectedGeneration: generation)
        await accounts.refresh()
      } else {
        try SettingsRestore(bytes).apply()
      }
      message = "已恢复" + kind.rawValue
    } catch { message = error.localizedDescription }
  }
}
