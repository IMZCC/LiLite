import SwiftUI
import UniformTypeIdentifiers

struct SubtitlePicker: View {
  @ObservedObject var model: PlayerModel
  var body: some View {
    SubtitleButton(
      session: model.captions, title: model.timeline.source?.bvid ?? "视频",
      cid: model.timeline.source?.cid, refresh: model.reloadSubtitleCatalog)
  }
}
struct SubtitleButton: View {
  @ObservedObject var session: SubtitleSession
  var title: String, cid: Int64?
  var refresh: (() -> Void)? = nil
  @State private var show = false
  var body: some View {
    Button {
      show = true
    } label: {
      Label("字幕", systemImage: "captions.bubble")
    }
    .piliSheet(isPresented: $show) {
      PiliNavigationStack {
        SubtitlePanel(session: session, title: title, cid: cid, refresh: refresh)
      }
    }
  }
}
/// A subtitle file picked by the person, read and added to the session.
enum SubtitleImport {
  static var types: [UTType] {
    SubtitleFileFormat.allCases.compactMap { UTType(filenameExtension: $0.rawValue, conformingTo: .data) }
  }
  /// Leaves the session alone if it moved on to another video while the file was being read.
  @MainActor static func load(_ url: URL, into session: SubtitleSession) async throws {
    let key = session.epoch
    let (data, size) = try await Task.detached(priority: .userInitiated) {
      let opened = url.startAccessingSecurityScopedResource()
      defer { if opened { url.stopAccessingSecurityScopedResource() } }
      guard let f = SubtitleFileFormat(rawValue: url.pathExtension.lowercased()) else {
        throw ServiceError("不支持这个字幕格式")
      }
      let h = try FileHandle(forReadingFrom: url)
      defer { try? h.close() }
      let bytes = try h.read(upToCount: SubtitleDocument.maxBytes + 1) ?? Data()
      let doc = try SubtitleDocument(bytes, format: f)
      if let ass = doc.assPayload, !ASSImportCheck.valid(ass) {
        throw ServiceError("无效的 ASS 字幕")
      }
      return (doc, bytes.count)
    }.value
    guard key == session.epoch else { return }
    try await session.add(data, name: url.deletingPathExtension().lastPathComponent, bytes: size)
  }
}
private struct SubtitleOutput: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  let bytes: Data
  init(_ bytes: Data) { self.bytes = bytes }
  init(configuration: ReadConfiguration) throws {
    bytes = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: bytes)
  }
}
struct SubtitlePanel: View {
  @ObservedObject var session: SubtitleSession
  let title: String, cid: Int64?, refresh: (() -> Void)?
  /// A sheet ends with 完成; a pushed page goes back instead.
  var done = true
  @Environment(\.dismiss) private var dismiss
  @State private var importing = false
  @State private var saving = false
  @State private var working = false
  @State private var format = SubtitleFileFormat.vtt
  @State private var selected: String?
  @State private var message: String?
  @State private var output: SubtitleOutput?
  @State private var fileName = "字幕"
  private var allowed: [UTType] {
    SubtitleFileFormat.allCases.compactMap {
      UTType(filenameExtension: $0.rawValue, conformingTo: .data)
    }
  }
  private var exportType: UTType {
    UTType(filenameExtension: format.rawValue, conformingTo: .data) ?? .data
  }
  private func binding(_ secondary: Bool) -> Binding<String?> {
    .init(
      get: { secondary ? session.second : session.first },
      set: { v in Task { await session.select(v, secondary: secondary) } })
  }
  private func name(_ file: String) -> String {
    let cleaned = file.components(separatedBy: CharacterSet(charactersIn: "/\\:\r\n\0")).joined(
      separator: "_")
    return String(cleaned.prefix(96))
  }
  var body: some View {
    Form {
      Section {
        choice("关闭字幕", selected: session.first == nil) { binding(false).wrappedValue = nil }
        ForEach(session.tracks) { r in
          choice(r.name, selected: session.first == r.id) { binding(false).wrappedValue = r.id }
        }
      } header: {
        Text("字幕")
      } footer: {
        if session.tracks.isEmpty { Text("这个视频没有可用字幕，可以加载本地字幕文件") }
      }
      if session.first != nil, session.tracks.count > 1 {
        Section("第二字幕") {
          choice("不显示", selected: session.second == nil) { binding(true).wrappedValue = nil }
          ForEach(session.tracks.filter { $0.id != session.first }) { r in
            choice(r.name, selected: session.second == r.id) { binding(true).wrappedValue = r.id }
          }
        }
      }
      Section {
        Button { importing = true } label: {
          SettingsRowLabel(title: "加载字幕文件", symbol: "doc.badge.plus", color: .blue)
        }
        if let refresh {
          Button(action: refresh) {
            SettingsRowLabel(title: "刷新字幕列表", symbol: "arrow.clockwise", color: .gray)
          }
        }
      } footer: {
        Text("支持 " + SubtitleFileFormat.allCases.map { $0.rawValue.uppercased() }.joined(separator: "、"))
      }
      if !session.tracks.isEmpty {
        Section("保存字幕") {
          Picker("语言", selection: $selected) {
            Text("当前字幕").tag(nil as String?)
            ForEach(session.tracks) { r in Text(r.name).tag(Optional(r.id)) }
          }
          Picker("文件格式", selection: $format) {
            ForEach(SubtitleFileFormat.exports) { f in Text(f.label).tag(f) }
          }
          Button { save() } label: {
            HStack {
              Text("保存到文件")
              if working { Spacer(); ProgressView() }
            }
          }.disabled(working)
        }
      }
      if let issue = message ?? session.issue {
        Section { Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
      }
    }
    .navigationTitle("字幕").navigationBarTitleDisplayMode(.inline)
    .presentationDetents([.medium, .large])
    .toolbar { if done { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }
      .fileImporter(isPresented: $importing, allowedContentTypes: allowed) { answer in
        do {
          let url = try answer.get()
          Task {
            working = true
            defer { working = false }
            do {
              try await SubtitleImport.load(url, into: session)
              message = nil
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
          }
        } catch {
          if (error as NSError).code != NSUserCancelledError {
            message = error.localizedDescription
          }
        }
      }
      .fileExporter(
        isPresented: $saving, document: output, contentType: exportType, defaultFilename: fileName
      ) { r in
        if case .failure(let e) = r, (e as NSError).code != NSUserCancelledError {
          message = e.localizedDescription
        }
        output = nil
      }
  }
  private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Text(title).foregroundStyle(.primary)
        Spacer()
        if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint) }
      }
      .contentShape(Rectangle())
    }
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
  private func save() {
    let chosen = selected ?? session.first ?? session.tracks.first?.id
    guard !working, let row = session.tracks.first(where: { $0.id == chosen }) else { return }
    let key = session.epoch
    let f = format
    Task {
      working = true
      defer { working = false }
      do {
        let doc = try await session.document(row)
        let bytes = try doc.bytes(f)
        guard key == session.epoch else { return }
        output = SubtitleOutput(bytes)
        fileName =
          name(
            [title, cid.map(String.init) ?? "", row.name].filter { !$0.isEmpty }.joined(
              separator: "-")) + "." + f.rawValue
        message = nil
        saving = true
      } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
  }
}
