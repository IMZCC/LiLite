import Foundation

extension BiliAPI {
  func feedFeedback(_ video: Video, group: String, reason: Int64, undo: Bool, uid: String)
    async throws
  {
    guard let item = video.recommendResource, item > 0, let goto = video.recommendGoto,
      video.recommendMenu?.contains(where: {
        $0.type == group && $0.reasons?.contains(where: { $0.id == reason }) == true
      }) == true
    else { throw ServiceError("推荐卡片已变更") }
    try await sendPreference(
      .feed(kind: goto, id: item, group: group, reason: reason, undo: undo), owner: uid)
  }
  func archiveDislike(_ aid: Int64, undo: Bool, owner: String) async throws {
    try await sendPreference(.archive(id: aid, undo: undo), owner: owner)
  }
  private func sendPreference(_ change: CardPreferenceMutation, owner: String) async throws {
    let use = AccountUse.role(change.role)
    let bound = try await AccountJar.shared.mobileRESTSession(use)
    try await change.sendOnce(expected: owner, actor: bound.owner, token: bound.token) { r in
      try await MobileREST.transfer(r, session: bound, current: {
        try await AccountJar.shared.mobileRESTSession(use)
      }, via: { try await self.session.data(for: $0) })
    }
  }
}
