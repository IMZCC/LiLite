import Foundation
import PiliArchive
import UIKit

enum PackPart: String, CaseIterable, Identifiable {
  case settings = "setting.json"
  case search = "search.json"
  case blocked = "blacklist.json"
  case replies = "reply.json"
  case font = "customFont.otf"
  case accounts = "account.json"
  case server = "piliNativeServerProfile"
  case contributor = "piliNativeContributor"
  var sensitive: Bool { self == .accounts || self == .server || self == .contributor }
  var id: Self { self }
  var title: String {
    switch self {
    case .settings: return "设置"
    case .search: return "搜索记录"
    case .blocked: return "屏蔽的用户"
    case .replies: return "已保存的评论"
    case .font: return "自定义字体"
    case .accounts: return "登录账号"
    case .server: return "WebDAV 配置与密码"
    case .contributor: return "空降助手贡献身份"
    }
  }
}
struct PackPreview: Identifiable {
  let id = UUID()
  let zip: PortableArchive
  let settingsRoot: BackupFormat.Map?
  var choices: [PackPart] {
    PackPart.allCases.filter {
      if $0 == .settings, settingsRoot?["piliNativePrivateSettingsOnly"] as? Bool == true {
        return false
      }
      if $0 == .server { return !(settingsBox?["webdavUri"] as? String ?? "").isEmpty }
      if $0 == .contributor { return !(settingsBox?["blockUserID"] as? String ?? "").isEmpty }
      return zip.parts[$0.rawValue] != nil
    }
  }
  var settingsBox: BackupFormat.Map? {
    settingsRoot?["setting"] as? BackupFormat.Map
  }
  var importedIDs: Set<String> {
    guard let bytes = zip.parts[PackPart.accounts.rawValue],
      let entries = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    else { return [] }
    return Set(entries.keys.filter { s in Int64(s).map { $0 > 0 && String($0) == s } ?? false })
  }
  var warning: String? {
    var warnings: [String] = []
    if zip.version & 65535 > 0 { warnings.append("数据包使用较新的格式") }
    if zip.sourceApp != "PiliPlus" { warnings.append("数据包的来源应用不同") }
    if let build = zip.sourceBuild, build > DataPack.versionCode { warnings.append("数据包来自较新的版本") }
    return warnings.isEmpty ? nil : warnings.joined(separator: "；")
  }
  init(_ bytes: Data) throws {
    if bytes.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 {
      let root = try BackupFormat.read(bytes)
      guard
        root["version"] != nil
          || (root["setting"] is BackupFormat.Map && root["video"] is BackupFormat.Map)
      else { throw ServiceError("不是设置备份") }
      zip = try PortableArchive(
        read: PortableArchive.make(
          [PackPart.settings.rawValue: bytes], platform: "设置文件", versionName: "JSON"))
    } else {
      zip = try PortableArchive(read: bytes)
    }
    settingsRoot = zip.parts[PackPart.settings.rawValue].flatMap { try? BackupFormat.read($0) }
  }
}

enum DataPack {
  static let versionCode =
    Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") ?? 1
  static func make(
    _ chosen: Set<PackPart>, prefs: NativePrefs, platform: String, compatible: Bool = false
  ) async throws
    -> Data
  {
    if compatible, !chosen.isDisjoint(with: [.server, .contributor, .font]),
      !chosen.contains(.settings)
    {
      throw ServiceError("原版 ZIP 会整体恢复设置，请同时勾选设置或使用加密格式")
    }
    if chosen.contains(where: \.sensitive) { try await PackAuthorization.verify("导出数据包中的登录凭据") }
    let accountRelated = !chosen.isDisjoint(with: [.accounts, .replies])
    let before = accountRelated ? try await AccountJar.shared.packStamp() : nil
    var replyOwner: String?
    var routes: [String: String]?
    var parts: [String: Data] = [:]
    var snapshot = prefs
    // Account data, blacklists and custom fonts are separately selectable parts.
    // Do not reintroduce the blacklist through the native settings extension.
    snapshot.recommendation?.blockedCreators = []
    let d = UserDefaults.standard
    if chosen.contains(.settings) || chosen.contains(.server) || chosen.contains(.contributor) {
      var object: BackupFormat.Map =
        chosen.contains(.settings)
        ? try BackupFormat.read(snapshot.archive())
        : ["setting": BackupFormat.Map(), "video": BackupFormat.Map()]
      if !chosen.contains(.settings) { object["piliNativePrivateSettingsOnly"] = true }
      if chosen.contains(.server) {
        var box = object["setting"] as? BackupFormat.Map ?? [:]
        box.merge(try PackServerProfile.current().upstream) { _, v in v }
        object["setting"] = box
      }
      if chosen.contains(.contributor) {
        let identity = try PackContributor.current()
        var box = object["setting"] as? BackupFormat.Map ?? [:]
        box["blockUserID"] = identity.id
        box["blockServer"] = identity.base.absoluteString
        object["setting"] = box
      }
      if chosen.contains(.font), let face = prefs.typeface, !face.file.isEmpty {
        var settings = object["setting"] as? BackupFormat.Map ?? [:]
        settings["appFont"] = "/" + face.name
        object["setting"] = settings
      }
      parts[PackPart.settings.rawValue] = try BackupFormat.serialize(object)
    }
    if chosen.contains(.search) {
      parts[PackPart.search.rawValue] =
        d.data(forKey: "search.history").flatMap {
          (try? JSONDecoder().decode([String].self, from: $0)) == nil ? nil : $0
        } ?? Data("[]".utf8)
    }
    if chosen.contains(.blocked) {
      parts[PackPart.blocked.rawValue] = try JSONEncoder().encode(
        (prefs.recommendation?.blockedCreators ?? []).sorted())
    }
    if chosen.contains(.replies), let uid = before?.active {
      replyOwner = uid
      parts[PackPart.replies.rawValue] = try await ReplyArchive.shared.export(uid)
    }
    if chosen.contains(.accounts) {
      parts[PackPart.accounts.rawValue] = try await AccountJar.shared.archiveData()
      routes = try await AccountJar.shared.packRoleChoices()
    }
    if chosen.contains(.font), let choice = prefs.typeface, !choice.file.isEmpty {
      try choice.validate()
      let u = try CustomTypefaces.directory().appendingPathComponent(choice.file)
      parts[PackPart.font.rawValue] = try Data(contentsOf: u, options: .mappedIfSafe)
    }
    guard !parts.isEmpty else { throw ServiceError("没有可导出的数据") }
    if let before, try await AccountJar.shared.packStamp().generation != before.generation {
      throw ServiceError("导出期间账号已变更，请重试")
    }
    return try PortableArchive.make(
      parts, platform: platform, versionName: "2.2.0.2", versionCode: versionCode,
      replyOwner: replyOwner, routes: routes)
  }

  @MainActor static func restore(
    _ preview: PackPreview, selected: Set<PackPart>, replyOwner: String?, expectedMain: String?
  ) async throws -> String {
    let finished = try SleepExitFence.shared.enter(); defer { finished() }
    let parts = preview.zip.parts
    guard !selected.isEmpty, selected.isSubset(of: Set(preview.choices)) else {
      throw ServiceError("请选择要恢复的内容")
    }
    func get(_ p: PackPart) -> Data? { selected.contains(p) ? parts[p.rawValue] : nil }
    if selected.contains(where: \.sensitive) { try await PackAuthorization.verify("导入数据包中的登录凭据") }
    let related = !selected.isDisjoint(with: [.replies, .accounts])
    let stamp = related ? try await AccountJar.shared.packStamp() : nil
    if let stamp, stamp.active != expectedMain { throw ServiceError("主账号已切换，请重新预览") }
    var server: PackServerProfile?
    if selected.contains(.server), let bytes = parts[PackPart.settings.rawValue],
      let box = try BackupFormat.read(bytes)["setting"] as? BackupFormat.Map
    {
      server = try .read(box)
    }
    let contributor =
      try selected.contains(.contributor) ? PackContributor.read(preview.settingsBox ?? [:]) : nil
    let oldPending = UserDefaults.standard.data(forKey: PackServerProfile.pendingKey).flatMap {
      try? JSONDecoder().decode(PackServerProfile.Pending.self, from: $0)
    }
    let base = NativePrefs.current()
    let restore = try get(.settings).map { try SettingsRestore($0, current: base) }
    var settings = restore?.settings
    let ids = try get(.blocked).map { try JSONDecoder().decode([Int64].self, from: $0) }
    var rules = settings?.recommendation ?? base.recommendation ?? .init()
    rules.blockedCreators = ids.map(Set.init) ?? base.recommendation?.blockedCreators ?? []
    try rules.validate()
    settings?.recommendation = rules
    if get(.font) == nil, settings?.typeface?.file.isEmpty == false {
      settings?.typeface = base.typeface
    }
    var stage = StagedPreferences()
    if let carry = restore?.carry { stage.values[SettingsRestore.carryKey] = carry }
    if ids != nil { stage.values[RecommendationRules.key] = try JSONEncoder().encode(rules) }
    if let search = get(.search) {
      let values = try JSONDecoder().decode([String].self, from: search)
      guard values.count <= 100_000, values.allSatisfy({ $0.utf8.count <= 16384 }) else {
        throw ServiceError("搜索记录超出限制")
      }
      stage.values["search.history"] = try JSONEncoder().encode(values)
    }
    let accounts = try get(.accounts).map(ArchiveAccount.decode)
    if let accounts {
      try ArchiveAccount.validateRoles(preview.zip.accountRoutes, accounts: accounts)
    }
    let rows = try get(.replies).map { bytes -> [SavedReply] in
      guard bytes.count <= 32 * 1024 * 1024,
        let raw = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]]
      else { throw ServiceError("评论数据格式无效") }
      return try raw.map {
        guard let row = SavedReply.parse($0) else { throw ServiceError("评论数据格式无效") }
        return row
      }
    }
    let owner = preview.zip.replyOwner ?? replyOwner
    if rows?.isEmpty == false {
      guard let owner, owner == replyOwner,
        stamp?.ids.contains(owner) == true || accounts?[owner] != nil
      else { throw ServiceError("请选择评论所属账号，或同时导入该账号") }
    }
    try settings?.validate()
    var journal = DataPackRestoreJournal()
    do {
      if let bytes = get(.font) {
        var font = settings?.typeface ?? base.typeface ?? .standard
        let ext = font.file.split(separator: ".").last.map(String.init) ?? "otf"
        let path = try CustomTypefaces.packURL(bytes, ext: ext)
        let existed = FileManager.default.fileExists(atPath: path.path)
        let imported = try CustomTypefaces.importBytes(bytes, ext: ext)
        if !existed { journal.wrote { try CustomTypefaces.removePackFont(path) } }
        font.file = imported.file
        if !imported.names.contains(font.name) { font.name = imported.names[0] }
        stage.values[TypefaceChoice.key] = try font.encoded()
        settings?.typeface = font
      }
      if let settings {
        let prefs = try StagedPreferences.prepare(settings)
        stage.values.merge(prefs.values) { first, _ in first }
        stage.removals.formUnion(prefs.removals)
      }
      if let rows, !rows.isEmpty, let owner {
        let receipt = try await ReplyArchive.shared.mergeForPack(rows, uid: owner)
        journal.wrote { try await ReplyArchive.shared.rollbackPack(receipt, uid: owner) }
      }
      if let contributor, try contributor.install() { journal.wrote { try contributor.undo() } }
      if let server {
        let (entry, data) = try server.stage()
        stage.values[PackServerProfile.pendingKey] = data
        journal.wrote { try PackServerProfile.discard(entry) }
      }
      if let accounts, let stamp {
        try await AccountJar.shared.mergeArchive(
          accounts, choices: preview.zip.accountRoutes, expectedGeneration: stamp.generation)
      } else if let stamp, try await AccountJar.shared.packStamp().generation != stamp.generation {
        throw ServiceError("恢复期间账号已变更，请重新预览")
      }
      // Nonthrowing preferences publication is last; a locked Keychain cannot cause a half-restore.
      stage.commit(.standard)
      if server != nil, let oldPending { try? PackServerProfile.discard(oldPending) }
    } catch { throw await journal.rollback(error) }
    return "已恢复：" + preview.choices.filter(selected.contains).map(\.title).joined(separator: "、")
  }
}
