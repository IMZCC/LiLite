import Foundation

enum VipExperience {
  static let autoKey = "vip.autoExperience"
  static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: autoKey) as? Bool ?? true
  }
  static func day(_ date: Date = Date(), calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
    return "\(parts.era ?? 0):\(parts.year ?? 0):\(parts.month ?? 0):\(parts.day ?? 0)"
  }
  static func attemptKey(_ uid: String) -> String { "vip.experience.attempt." + uid }
  static func doneKey(_ uid: String) -> String { "vip.experience.done." + uid }
  static func shouldClaim(_ uid: String, day: String, defaults: UserDefaults = .standard) -> Bool {
    enabled(defaults) && defaults.string(forKey: attemptKey(uid)) != day
      && defaults.string(forKey: doneKey(uid)) != day
  }
  enum Result {
    case claimed(amount: Int?), alreadyClaimed
  }
}

extension Notification.Name {
  static let piliToast = Self("PiliNative.Toast")
}

extension BiliAPI {
  /// Matches lib/http/user.dart: POST with the active account's mid and csrf.
  func claimVipExperience(expectedAccount uid: String) async throws -> VipExperience.Result {
    guard let user = try await AccountJar.shared.current(), user.id == uid,
      let csrf = user.csrf, !csrf.isEmpty else { throw ServiceError("请重新登录当前账号") }
    var route = URLComponents()
    route.path = "/x/vip/experience/add"
    route.queryItems = [.init(name: "mid", value: uid), .init(name: "csrf", value: csrf)]
    guard let path = route.string else { throw URLError(.badURL) }
    let bytes: Data
    do {
      bytes = try await submitResponse(path, [:], expectedAccount: uid)
    } catch let error as ServiceError where error.code == 69198 {
      return .alreadyClaimed
    }
    // The usual payload contains only type/is_grant; never invent an experience amount.
    let envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    let data = envelope?["data"] as? [String: Any]
    if data?["is_grant"] as? Bool == false { throw ServiceError("大会员经验未发放") }
    let amount = ["exp", "experience", "amount", "add_exp"].compactMap { key -> Int? in
      if let value = data?[key] as? Int { return value > 0 ? value : nil }
      if let text = data?[key] as? String, let value = Int(text), value > 0 { return value }
      return nil
    }.first
    return .claimed(amount: amount)
  }
}

actor VipExperienceCoordinator {
  static let shared = VipExperienceCoordinator()
  private var running: [String: Task<Void, Never>] = [:]

  func run(account uid: String?) async {
    guard let uid, !uid.isEmpty, VipExperience.shouldClaim(uid, day: VipExperience.day()),
      running[uid] == nil else { return }
    // A scene disappearing must not cancel a POST that may already have reached the server.
    let task = Task { await self.claimIfNeeded(uid) }
    running[uid] = task
    await task.value
    running[uid] = nil
  }

  private func claimIfNeeded(_ uid: String) async {
    do {
      guard try await AccountJar.shared.presentedState().active == uid else { return }
      let profile = try await BiliAPI.shared.profile(expectedAccount: uid)
      guard String(profile.mid) == uid, profile.vipStatus == 1 else { return }
      let day = VipExperience.day()
      guard VipExperience.shouldClaim(uid, day: day),
        try await AccountJar.shared.presentedState().active == uid else { return }
      // Persist before submitting: even an ambiguous timeout cannot cause a second daily POST.
      UserDefaults.standard.set(day, forKey: VipExperience.attemptKey(uid))
      let result = try await BiliAPI.shared.claimVipExperience(expectedAccount: uid)
      UserDefaults.standard.set(day, forKey: VipExperience.doneKey(uid))
      if case .claimed(let amount) = result,
        try await AccountJar.shared.presentedState().active == uid {
        let message = "大会员经验领取成功" + (amount.map { "（+\($0)）" } ?? "")
        await MainActor.run { NotificationCenter.default.post(name: .piliToast, object: message) }
      }
    } catch {
      await DiagnosticJournal.shared.add("大会员经验", error.localizedDescription)
    }
  }
}
