import Foundation
import Security

@MainActor enum AboutReset {
  enum Scope { case preferences, all }
  static func apply(_ scope: Scope, accounts: AccountContext) async throws {
    let finished = try SleepExitFence.shared.enter(); defer { finished() }
    guard let appID = Bundle.main.bundleIdentifier else { throw ServiceError("无法识别应用配置") }
    let d = UserDefaults.standard
    let stage = try StagedPreferences.prepare(NativePrefs.current(d))
    let retained = RecommendationRules.current(d).blockedCreators
    let preferKeys = Set(stage.values.keys).union(stage.removals).union([
      SettingsRestore.carryKey, PackServerProfile.pendingKey, "backup.dav.url", "backup.dav.user",
      "backup.dav.directory",
    ])
    if scope == .all { try await PackAuthorization.verify("重置本机数据与登录账号") }
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let staged = scope == .all ? try LocalResetPolicy.removeManagedData(in: root) : nil
    do {
      if scope == .all {
        let ids = accounts.state.accounts.map(\.id)
        try await AccountJar.shared.clearForLocalReset()
        ids.forEach { AccountBulletRules.shared.forget($0) }
        ListenQueue.shared.stop()
        ListenQueue.shared.clearList()
        PlaybackSleepTimer.shared.cancel()
        PlaybackMemory.forgetStoredPoints()
        LastArchivePart.forgetStoredParts()
        await accounts.refresh()
      }
      for service in [
        "PiliNative.WebDAV", "PiliNative.PendingDAV", "PiliNative.Sponsor", "PiliNative.PrivateTLS",
      ] {
        let code = SecItemDelete(
          [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            as CFDictionary)
        guard code == errSecSuccess || code == errSecItemNotFound else {
          throw ServiceError("无法清除本机服务授权，请解锁后重试")
        }
      }
      try await FolderGrants.shared.reset(.pictures)
      try await FolderGrants.shared.reset(.cache)
      if scope == .all {
        for k in d.persistentDomain(forName: appID)?.keys.map({ $0 }) ?? [] {
          d.removeObject(forKey: k)
        }
        await ArtworkStore.shared.clear()
        URLCache.shared.removeAllCachedResponses()
        try await DiagnosticJournal.shared.clear()
      } else {
        for k in preferKeys { d.removeObject(forKey: k) }
        if !retained.isEmpty {
          var rules = RecommendationRules()
          rules.blockedCreators = retained
          try rules.save(d)
        }
      }
    } catch {
      if let staged { try LocalResetPolicy.finish(staged, in: root, restore: true) }
      throw error
    }
    if let staged { try LocalResetPolicy.finish(staged, in: root, restore: false) }
    if scope == .all { NotificationCenter.default.post(name: AppLinkPage.returnHome, object: nil) }
  }
}
