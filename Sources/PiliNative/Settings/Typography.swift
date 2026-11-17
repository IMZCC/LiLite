import CoreText
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

extension TypefaceChoice {
  private static let resolvedNames: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>(); cache.countLimit = 64; return cache
  }()
  static let weights: [Font.Weight] = [
    .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
  ]
  func font(_ style: Font.TextStyle, weight explicit: Font.Weight? = nil) -> Font {
    let weight =
      explicit
      ?? (self.weight == 4 && style == .headline ? .semibold : Self.weights[self.weight - 1])
    if self.name.isEmpty && self.scale == 1 { return .system(style).weight(weight) }
    let ui: UIFont.TextStyle
    switch style {
    case .largeTitle: ui = .largeTitle
    case .title: ui = .title1
    case .title2: ui = .title2
    case .title3: ui = .title3
    case .headline: ui = .headline
    case .subheadline: ui = .subheadline
    case .callout: ui = .callout
    case .caption: ui = .caption1
    case .caption2: ui = .caption2
    case .footnote: ui = .footnote
    default: ui = .body
    }
    var selectedName: String?
    if !name.isEmpty {
      if let cached = Self.resolvedNames.object(forKey: name as NSString) { selectedName = cached as String }
      else if UIFont(name: name, size: 16) != nil { selectedName = name }
      else {
        let family = UIFont.fontNames(forFamilyName: name)
        selectedName = family.first(where: { $0.hasSuffix("-Regular") }) ?? family.first
      }
      if let selectedName { Self.resolvedNames.setObject(selectedName as NSString, forKey: name as NSString) }
    }
    if let selectedName {
      let size = UIFont.preferredFont(
        forTextStyle: ui, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
      ).pointSize
      return .custom(selectedName, size: size * self.scale, relativeTo: style).weight(weight)
    }
    return .system(
      size: UIFont.preferredFont(forTextStyle: ui).pointSize * self.scale, weight: weight)
  }
}
private struct TypefaceKey: EnvironmentKey { static let defaultValue = TypefaceChoice.standard }
extension EnvironmentValues {
  var piliTypeface: TypefaceChoice {
    get { self[TypefaceKey.self] }
    set { self[TypefaceKey.self] = newValue }
  }
}
private struct SemanticTypeface: ViewModifier {
  @Environment(\.piliTypeface) var face
  @Environment(\.dynamicTypeSize) var size
  let style: Font.TextStyle, weight: Font.Weight?
  func body(content: Content) -> some View {
    let _ = size
    return content.font(face.font(style, weight: weight))
  }
}
extension View {
  func piliFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
    modifier(SemanticTypeface(style: style, weight: weight))
  }
}

enum CustomTypefaces {
  static func directory() throws -> URL {
    let path = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Fonts", isDirectory: true)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return path
  }
  static func register(_ url: URL) throws -> [String] {
    let descriptors =
      CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
    guard !descriptors.isEmpty else { throw ServiceError("文件不包含可用字体") }
    let names = descriptors.compactMap {
      CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
    }
    if let n = names.first, UIFont(name: n, size: 16) == nil {
      var e: Unmanaged<CFError>?
      guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &e) else {
        if let e { throw e.takeRetainedValue() as Error }
        throw ServiceError("字体注册失败")
      }
    }
    let usable = names.filter { UIFont(name: $0, size: 16) != nil }
    guard !usable.isEmpty else { throw ServiceError("字体不可用") }
    return usable
  }
  static func restore(_ c: TypefaceChoice) {
    guard !c.file.isEmpty, (try? c.validate()) != nil, let d = try? directory() else { return }
    _ = try? register(d.appendingPathComponent(c.file))
  }
  static func inventory() throws -> [String:String] {
    let local = try directory()
    var result: [String:String] = [:]
    for u in try FileManager.default.contentsOfDirectory(at:local,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey], options:[.skipsHiddenFiles]) {
      guard u.lastPathComponent.range(of:"^[0-9a-f]{64}\\.(ttc|otf|ttf)$",options:.regularExpression) != nil,
        let v = try? u.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),v.isRegularFile == true,v.isSymbolicLink != true,
        let names=try? register(u) else {continue}
      for n in names {result[n]=u.lastPathComponent}
    }
    return result
  }
  static func importFile(_ url: URL) throws -> (file: String, names: [String]) {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let ext = url.pathExtension.lowercased()
    guard ["ttf", "ttc", "otf"].contains(ext),
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
      size <= 64 * 1024 * 1024
    else { throw ServiceError("请选择不超过 64 MB 的 TTF、TTC 或 OTF 字体") }
    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
    return try importBytes(bytes, ext: ext)
  }
  static func packURL(_ bytes: Data, ext: String) throws -> URL {
    guard ["ttf","ttc","otf"].contains(ext) else { throw ServiceError("字体格式无效") }
    let name = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + "." + ext
    return try directory().appendingPathComponent(name)
  }
  static func removePackFont(_ url: URL) throws {
    CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
    try FileManager.default.removeItem(at: url)
  }
  static func importBytes(_ bytes: Data, ext: String) throws -> (file: String, names: [String]) {
    guard !bytes.isEmpty, bytes.count <= 64 * 1024 * 1024, ["ttf", "ttc", "otf"].contains(ext)
    else { throw ServiceError("字体文件无效") }
    let filename = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + "." + ext
    let saved = try directory().appendingPathComponent(filename)
    let existed = FileManager.default.fileExists(atPath: saved.path)
    if !existed { try bytes.write(to: saved, options: .atomic) }
    do { return (filename, try register(saved)) } catch {
      if !existed { try? FileManager.default.removeItem(at: saved) }
      throw error
    }
  }
}
struct TypographyPanel: View {
  @AppStorage(TypefaceChoice.key) private var stored = Data()
  @State private var draft = TypefaceChoice.standard
  @State private var fontFiles: [String: String] = [:]
  @State private var removeOnApply: Set<String> = []
  @State private var search = ""
  @State private var importing = false
  @State private var issue: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("清风徐来，水波不兴").font(draft.font(.title2))
          Text("轻哩，让每一帧都更清晰。0123456789").font(draft.font(.body))
          Text("评论 · 弹幕 · 动态").font(draft.font(.footnote)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .animation(.snappy(duration: 0.2), value: draft)
      } header: {
        Text("预览")
      }
      Section {
        Picker("字重", selection: $draft.weight) {
          ForEach(1...9, id: \.self) { Text("W\($0*100)").tag($0) }
        }.settingAnchor("TypographyPanel/字重")
        SettingSlider(title: "字号", value: $draft.scale, range: 0.85...1.6, step: 0.05)
          .settingAnchor("TypographyPanel/字号")
        Button("恢复默认", role: .destructive) { withAnimation { draft = .standard } }
      }
      Section("字体") {
        Button {
          draft.name = ""
          draft.file = ""
        } label: {
          HStack {
            Text("系统默认").foregroundStyle(.primary)
            Spacer()
            if draft.name.isEmpty { Image(systemName: "checkmark").foregroundStyle(.tint) }
          }
        }.settingAnchor("TypographyPanel/系统默认")
        if !draft.name.isEmpty { LabeledContent("当前", value: draft.name) }
        Button { importing = true } label: {
          Label("从文件导入", systemImage: "square.and.arrow.down")
        }.settingAnchor("TypographyPanel/从文件导入")
        if !fontFiles.isEmpty {
          ForEach(fontFiles.keys.sorted(), id: \.self) { n in
            HStack {
              Button(n) { draft.name = n; draft.file = fontFiles[n] ?? "" }
              Spacer()
              Button(role:.destructive) {
                guard let f=fontFiles[n] else{return}
                removeOnApply.insert(f);fontFiles=fontFiles.filter{$0.value != f}
                if draft.file == f {draft.name="";draft.file=""}
              } label: {Image(systemName:"minus.circle").accessibilityLabel("移除"+n)}
            }.buttonStyle(.borderless)
          }
        }
        NavigationLink("选择已安装字体") {
          List {
            ForEach(
              UIFont.familyNames.sorted().filter {
                search.isEmpty || $0.localizedCaseInsensitiveContains(search)
              }, id: \.self
            ) { family in
              Button {
                let faces = UIFont.fontNames(forFamilyName: family)
                let n =
                  faces.first(where: { $0.hasSuffix("-Regular") || $0 == family }) ?? faces.first
                  ?? family
                draft.name = n
                draft.file = fontFiles[n] ?? ""
                search = ""
              } label: {
                HStack {
                  Text(family).font(.custom(family, size: 17))
                  Spacer()
                  if UIFont(name: draft.name, size: 16)?.familyName == family {
                    Image(systemName: "checkmark")
                  }
                }
              }
            }
          }.searchable(text: $search, prompt: "搜索字体").navigationTitle("已安装字体")
        }.settingAnchor("TypographyPanel/选择已安装字体")
        if let issue { Text(issue).foregroundStyle(.secondary) }
      }.settingAnchor("TypographyPanel/字体")
    }.navigationTitle("字体").toolbar {
      Button("应用") {
        do {
          let encoded = try draft.encoded()
          if !removeOnApply.isEmpty {
            let dir = try CustomTypefaces.directory()
            for f in removeOnApply where f != draft.file {
              let u = dir.appendingPathComponent(f)
              if FileManager.default.fileExists(atPath:u.path) { try CustomTypefaces.removePackFont(u) }
            }
          }
          stored = encoded; dismiss()
        } catch { issue = error.localizedDescription }
      }
    }
    .task {
      draft = .decode(stored)
      fontFiles = (try? CustomTypefaces.inventory()) ?? [:]
      if !draft.file.isEmpty { fontFiles[draft.name] = draft.file }
    }
    .fileImporter(
      isPresented: $importing,
      allowedContentTypes: ["ttf", "ttc", "otf"].compactMap { UTType(filenameExtension: $0) }
    ) { r in
      do {
        let item = try CustomTypefaces.importFile(r.get())
        removeOnApply.remove(item.file)
        for n in item.names { fontFiles[n] = item.file }
        draft.name = item.names[0]
        draft.file = item.file
        issue = nil
      } catch { issue = error.localizedDescription }
    }
  }
}
struct DisplayPanel: View {
  @AppStorage(HighRefreshRate.key) private var force = false
  @Environment(\.scenePhase) private var phase
  @State private var maxRate = 60
  var body: some View {
    Form {
      Section {
        LabeledContent("屏幕最高刷新率", value: "\(maxRate) Hz").settingAnchor("DisplayPanel/屏幕最高刷新率")
        Toggle(isOn: $force) {
          Label("强制 120Hz", systemImage: "gauge.with.dots.needle.100percent")
            .labelStyle(SettingsIconLabelStyle(color: .orange))
        }
        .disabled(maxRate <= 60)
        .settingAnchor("DisplayPanel/强制 120Hz")
      } footer: {
        if maxRate <= 60 {
          Text("这台设备的屏幕最高 \(maxRate)Hz，不支持高刷新率。")
        } else {
          Text("开启后应用在前台时始终请求 \(maxRate)Hz，滑动和动画更顺滑，但更耗电。低电量模式或机身过热时系统仍会降低刷新率。")
        }
      }
    }
    .navigationTitle("刷新率")
    .onAppear { update() }
    .onChange(of: phase) { _, v in if v == .active { update() } }
  }
  private func update() { maxRate = HighRefreshRate.maximum }
}
