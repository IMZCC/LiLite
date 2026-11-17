import Foundation

extension StagedPreferences {
  static func prepare(_ settings: NativePrefs) throws -> Self {
    // Defaults written with nil disappear from the staging suite; explicitly clear those
    // optional values. Only preference keys which settings.apply actually targets can change.
    var removed = Set(["live.cdn", "live.stream", DecoderPreference.listKey, VODLine.key])
    if settings.controls != nil {
      removed.formUnion(PlayerPreferenceValues.flags)
      removed.formUnion(PlayerPreferenceValues.limits.keys)
      removed.insert("detail.quickFolder")
    }
    return try collect(removing: removed) { try settings.apply($0) }
  }
}
struct SettingsRestore {
  static let carryKey = "backup.upstreamPreferences.v1"
  let settings: NativePrefs, skipped: Int, carry: Data, hasPrivateParts: Bool
  var summary: String {
    var detail = "恢复后将使用备份中的设置"
    if skipped > 0 { detail += "\n部分原版专用选项不会在此设备启用" }
    if hasPrivateParts { detail += "\n如需导入凭据，请在“本地数据包”中选择此文件" }
    if let proxy = settings.apiProxy, proxy.enabled { detail += "\n将使用接口代理：" + proxy.endpoint }
    return detail
  }
  init(_ data: Data, current: NativePrefs = .current()) throws {
    let archive = try BackupFormat.read(data)
    let box = archive["setting"] as? BackupFormat.Map ?? [:]
    hasPrivateParts = ["webdavUri","webdavUsername","webdavPassword","blockUserID"].contains {
      !(box[$0] as? String ?? "").isEmpty
    }
    var base = try current.backupMap()
    if archive["piliNative"] == nil, archive["setting"] != nil, archive["video"] != nil {
      let name = "PiliNative.factory-backup." + UUID().uuidString
      guard let empty = UserDefaults(suiteName: name) else { throw ServiceError("无法准备默认设置") }
      defer { empty.removePersistentDomain(forName: name) }
      base = try BackupFormat.restorationBase(
        archive, current: base, defaults: NativePrefs.current(empty).backupMap())
    }
    let (map, ignored) = try BackupFormat.native(archive, current: base)
    settings = try JSONDecoder().decode(NativePrefs.self, from: BackupFormat.serialize(map))
    try settings.validate()
    carry = try BackupFormat.serialize(BackupFormat.remainder(archive))
    skipped = ignored
  }
  func apply(_ defaults: UserDefaults = .standard) throws {
    var stage = try StagedPreferences.prepare(settings)
    stage.values[Self.carryKey] = carry
    stage.commit(defaults)
  }
}
extension NativePrefs {
  func backupMap() throws -> BackupFormat.Map { try BackupFormat.read(JSONEncoder().encode(self)) }
  func archive(over previous: Data? = nil, defaults: UserDefaults = .standard) throws -> Data {
    if let previous { _ = try SettingsRestore(previous, current: self) }
    let saved = try defaults.data(forKey: SettingsRestore.carryKey).map(BackupFormat.read)
    return try BackupFormat.export(
      native: backupMap(),
      over: BackupFormat.mergedCarry(
        BackupFormat.remainder(saved ?? [:]), try previous.map(BackupFormat.read)))
  }
}
