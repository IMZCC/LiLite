import Foundation
import SwiftProtobuf

/// The service supplies opaque page offsets. Fold cards can also carry a page size and refresh flag.
public struct ReplyGateway: Sendable {
  public typealias Row = PiliBilibiliMainCommunityReplyV1_ReplyInfo
  public static func archived(_ data: Data) throws -> Row {
    var options = JSONDecodingOptions()
    options.ignoreUnknownFields = true
    return try Row(jsonUTF8Data: data, options: options)
  }
  public typealias Content = PiliBilibiliMainCommunityReplyV1_Content
  public typealias Subject = PiliBilibiliMainCommunityReplyV1_SubjectControl
  public typealias Pagination = PiliBilibiliPagination_FeedPagination
  public enum Method: String, Sendable {
    case main = "MainList"
    case detail = "DetailList"
    case dialogue = "DialogList"
    case folded = "FoldList"
    case
      translate = "TranslateReply"
    case search = "SearchItem"
    public var path: String { "/bilibili.main.community.reply.v1.Reply/" + rawValue }
  }
  public enum Thread: Sendable {
    case main(anchor: Int64?)
    case detail(root: Int64, anchor: Int64?)
    case dialogue(root: Int64, id: Int64)
    case
      folded(Pagination)
  }
  public struct Fold: Sendable { public let text: String, pagination: Pagination }
  public struct Ballot: Sendable { public let id: Int64, title: String, count: Int64 }
  public struct Page: Sendable {
    public let vote: Ballot?
    public let rows: [Row], subject: Subject?, fold: Fold?, next: String?, title: String
  }
  public struct Reference: Identifiable, Sendable {
    public let id: String, title: String, cover: String, subtitle: String
    public var duration: Int64? = nil
  }
  public struct Matches: Sendable { public let items: [Reference], next: Int64? }
  private let exchange: @Sendable (Method, Data) async throws -> GatewayReply
  public init(exchange: @escaping @Sendable (Method, Data) async throws -> GatewayReply) {
    self.exchange = exchange
  }
  private func call<Q: Message, R: Message>(_ method: Method, _ query: Q, _ type: R.Type)
    async throws -> R
  {
    try R(
      serializedBytes: WireFrame.decode(
        try await exchange(method, WireFrame.encode(query.serializedData()))))
  }
  public func list(oid: Int64, type: Int64, thread: Thread, newest: Bool, offset: String? = nil)
    async throws -> Page
  {
    guard oid > 0, type > 0 else { throw WireError.invalid("评论主题无效") }
    let mode: PiliBilibiliMainCommunityReplyV1_Mode = newest ? .mainListTime : .mainListHot
    let page = offset.map { text in
      var p = Pagination()
      p.offset = text
      return p
    }
    func result(
      _ list: [Row], _ subject: Subject?, _ cards: [PiliBilibiliMainCommunityReplyV1_MixedCard],
      _ next: String, _ end: Bool, _ title: String = "", vote: Ballot? = nil
    ) -> Page {
      var seen = Set<Int64>()
      let fold: Fold? = cards.lazy.compactMap { card in
        guard case .fold(let f)? = card.item, f.hasFoldPagination else { return nil }
        return Fold(text: f.bottomText, pagination: f.foldPagination)
      }.first
      return .init(
        vote: vote, rows: list.filter { $0.id > 0 && seen.insert($0.id).inserted },
        subject: subject,
        fold: fold,
        next: end || next.isEmpty || next == offset ? nil : next, title: title)
    }
    switch thread {
    case .main(let anchor):
      var q = PiliBilibiliMainCommunityReplyV1_MainListReq()
      q.oid = oid
      q.type = type
      q.mode = mode
      if let page { q.pagination = page } else { q.rpid = anchor ?? 0 }
      let r = try await call(.main, q, PiliBilibiliMainCommunityReplyV1_MainListReply.self)
      // Like the original, only the uploader's pinned reply goes on top of the first page.
      let pinned = offset == nil && r.hasUpTop ? [r.upTop] : []
      return result(
        pinned + r.replies, r.hasSubjectControl ? r.subjectControl : nil, r.mixedCards,
        r.paginationReply.nextOffset, r.cursor.isEnd,
        vote: offset == nil && r.hasVoteCard && r.voteCard.voteID > 0
          ? Ballot(id: r.voteCard.voteID, title: r.voteCard.title, count: r.voteCard.count) : nil)
    case .detail(let root, let anchor):
      guard root > 0 else { throw WireError.invalid("根评论无效") }
      var q = PiliBilibiliMainCommunityReplyV1_DetailListReq()
      q.oid = oid
      q.type = type
      q.root = root
      q.scene = .reply
      q.mode = mode
      if let page { q.pagination = page } else { q.rpid = anchor ?? 0 }
      let r = try await call(.detail, q, PiliBilibiliMainCommunityReplyV1_DetailListReply.self)
      return result(
        (offset == nil ? [r.root] : []) + r.root.replies,
        r.hasSubjectControl ? r.subjectControl : nil, r.mixedCards, r.paginationReply.nextOffset,
        r.cursor.isEnd)
    case .dialogue(let root, let id):
      guard root > 0, id > 0 else { throw WireError.invalid("对话编号无效") }
      var q = PiliBilibiliMainCommunityReplyV1_DialogListReq()
      q.oid = oid
      q.type = type
      q.root = root
      q.dialog = id
      if let page { q.pagination = page }
      let r = try await call(.dialogue, q, PiliBilibiliMainCommunityReplyV1_DialogListReply.self)
      return result(
        r.replies, r.hasSubjectControl ? r.subjectControl : nil, [], r.paginationReply.nextOffset,
        r.cursor.isEnd)
    case .folded(var original):
      var q = PiliBilibiliMainCommunityReplyV1_FoldListReq()
      q.oid = oid
      q.type = type
      if let offset { original.offset = offset }
      q.pagination = original
      let r = try await call(.folded, q, PiliBilibiliMainCommunityReplyV1_FoldListResp.self)
      return result(
        r.replies, r.hasSubjectControl ? r.subjectControl : nil, [], r.paginationReply.nextOffset,
        r.paginationReply.nextOffset == original.offset, r.title)
    }
  }
  public func translation(oid: Int64, type: Int64, id: Int64) async throws -> Content {
    var q = PiliBilibiliMainCommunityReplyV1_TranslateReplyReq()
    q.oid = oid
    q.type = type
    q.rpids = [id]
    let r = try await call(.translate, q, PiliBilibiliMainCommunityReplyV1_TranslateReplyResp.self)
    guard let row = r.translatedReplies[id], row.hasTranslatedContent,
      !row.translatedContent.message.isEmpty
    else { throw WireError.invalid("暂无译文") }
    return row.translatedContent
  }
  public func references(oid: Int64, type: Int64, article: Bool, keyword: String, page: Int64 = 1)
    async throws -> Matches
  {
    guard page > 0 else { throw WireError.invalid("页码无效") }
    var q = PiliBilibiliMainCommunityReplyV1_SearchItemReq()
    q.oid = oid
    q.type = type
    q.keyword = keyword
    q.cursor.next = page
    q.cursor.itemType = article ? .article : .video
    let r = try await call(.search, q, PiliBilibiliMainCommunityReplyV1_SearchItemReply.self)
    let items = r.items.compactMap { item -> Reference? in
      guard !item.url.isEmpty else { return nil }
      switch item.item {
      case .article(let a):
        return .init(
          id: item.url, title: a.title, cover: a.covers.first ?? "", subtitle: a.upNickname)
      case .video(let v):
        switch v.videoItem {
        case .ugc(let x):
          return .init(
            id: item.url, title: x.title, cover: x.cover, subtitle: x.upNickname,
            duration: x.duration > 0 ? x.duration : nil)
        case .pgc(let x):
          return .init(id: item.url, title: x.title, cover: x.cover, subtitle: x.category)
        case nil: return nil
        }
      default: return nil
      }
    }
    return .init(
      items: items,
      next: r.cursor.hasNext_p && page < Int64.max
        ? (r.cursor.next > page ? r.cursor.next : page + 1) : nil)
  }
}
