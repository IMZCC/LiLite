import SwiftUI

extension BiliAPI {
  func creatorCardName(_ mid: String, owner: String?) async throws -> String? {
    struct Result: Decodable {
      struct Card: Decodable { let name: String? }
      let card: Card?
    }
    return try await read("/x/web-interface/card", ["mid": mid, "photo": "false"],
      expectedAccount: owner ?? "", as: Result.self).card?.name
  }
}
struct CreatorPanelIdentity: View {
  struct Profile: Decodable {
    struct VIP { let status: Int, type: Int }
    let mid: Int64, name: String?, face: String?, level: Int?, is_senior_member: Int?, is_followed: Bool?, vip: VIP?
    private enum CodingKeys: String, CodingKey { case card, following }
    private enum CardKeys: String, CodingKey { case mid, is_senior_member }
    init(from decoder: Decoder) throws {
      let data = try decoder.container(keyedBy: CodingKeys.self)
      let card = try data.nestedContainer(keyedBy: CardKeys.self, forKey: .card)
      let person = try data.decode(CreatorSpaceRecord.Person.self, forKey: .card)
      guard let id = try card.decode(ServiceID.self, forKey: .mid).number, id > 0 else {
        throw DecodingError.dataCorruptedError(forKey: .mid, in: card, debugDescription: "Invalid creator ID")
      }
      mid = id; name = person.name; face = person.face
      level = person.level.flatMap(Int.init(exactly:))
      is_senior_member = (try? card.decode(ServiceID.self, forKey: .is_senior_member))?.number.flatMap(Int.init(exactly:))
      is_followed = try data.decodeIfPresent(Bool.self, forKey: .following)
      vip = VIP(status: person.vipStatus, type: person.vipType)
    }
  }
  let mid: Int64, fallbackName: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var info: Profile?
  @State private var error: String?
  @State private var refresh = 0
  private struct LoadKey: Equatable { let mid: Int64, owner: String?, revision: Int }
  @State private var loadedKey: LoadKey?
  @State private var contentKey: LoadKey?
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        if let image = info?.face.flatMap(httpsURL) {
          GalleryLink([.init(image)], index: 0) {
            SiteThumbnail(url: image) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
              .frame(width: 54, height: 54).clipShape(Circle())
          }.accessibilityLabel("查看头像")
        }
        VStack(alignment: .leading) {
          Button(info?.name ?? fallbackName) { UIPasteboard.general.string = info?.name ?? fallbackName }
            .foregroundStyle(info?.vip?.status == 1 && info?.vip?.type == 2 ? Color.pink : Color.primary)
            .accessibilityHint("复制昵称")
          if let level = info?.level {
            UserLevelBadge(level: Int(level), height: 12, hardcore: info?.is_senior_member == 1)
          }
        }
      }
      HStack {
        NavigationLink("查看空间") { DeferredPage { CreatorSpace(mid: mid, name: info?.name ?? fallbackName) } }
        Spacer()
        if accounts.state.active == String(mid) {
          NavigationLink("编辑资料") { ProfileEditor(uid: String(mid)) { refresh &+= 1 } }
        } else if accounts.state.active != nil {
          CreatorQuickRelation(mid: mid, knownFollowing: info?.is_followed == true)
        } else { NavigationLink("登录后关注") { DeferredPage { QRLoginView() } } }
      }
      if let error {
        HStack { Text(error).piliFont(.caption); Button("重试") { refresh &+= 1 } }
      }
    }.buttonStyle(.borderless)
      .task(id: LoadKey(mid: mid, owner: accounts.state.active, revision: refresh)) {
        let uid = accounts.state.active
        let key = LoadKey(mid: mid, owner: uid, revision: refresh)
        guard loadedKey != key else { return }
        if contentKey?.mid != mid || contentKey?.owner != uid { info = nil; loadedKey = nil }
        contentKey = key
        error = nil
        do {
          let user = try await BiliAPI.shared.read("/x/web-interface/card", ["mid": String(mid), "photo": "false"],
            expectedAccount: uid ?? "", as: Profile.self)
          try Task.checkCancellation()
          guard accounts.state.active == uid, user.mid == mid else { return }
          info = user
          loadedKey = key
        } catch {
          if !Task.isCancelled, accounts.state.active == uid { self.error = error.localizedDescription }
        }
      }
  }
}
