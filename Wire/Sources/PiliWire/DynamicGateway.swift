import Foundation
import SwiftProtobuf

public struct DynamicGateway: Sendable {
  public enum Method: Sendable {
    case likes, reposts, space, unread
    public var path: String {
      switch self {
      case .unread: "/bilibili.app.dynamic.v1.Dynamic/DynRed"
      case .likes: "/bilibili.app.dynamic.v2.Dynamic/LikeList"
      case .reposts: "/bilibili.app.dynamic.v2.Dynamic/RepostList"
      case .space: "/bilibili.app.dynamic.v2.Opus/OpusSpaceFlow"
      }
    }
  }
  public struct Person: Sendable, Identifiable {
    public let id: Int64, name: String, face: String, when: String
    public var pendant = "", verify: Int?, vipStatus = 0, vipType = 0
    public var cardURL = "", fanNumber = "", fanPrefix = "", fanColor = ""
    public var sign = "", level = 0, senior = false
  }
  public enum Inline: Sendable, Equatable {
    case word(String), link(String, String), emote(String, String, Int)
    case vote(String, Int64), pictures([Picture])
  }
  public struct Picture: Sendable, Equatable {
    public let url: String, movie: String
  }
  public struct Repost: Sendable, Identifiable {
    public let id: String, person: Person, text: String, body: [Inline]
  }
  public struct Opus: Sendable, Identifiable {
    public let id: String, text: String, cover: String, like: String
  }
  public struct Collection: Sendable, Identifiable {
    public let id: Int64, title: String, cover: String, subtitle: String
  }
  public struct Flow: Sendable { public let rows: [Opus], collections: [Collection], next: String? }
  public struct Page<Value: Sendable>: Sendable {
    public let rows: [Value], total: Int64, next: String?
  }
  private let exchange: @Sendable (Method, Data) async throws -> GatewayReply
  public init(exchange: @escaping @Sendable (Method, Data) async throws -> GatewayReply) {
    self.exchange = exchange
  }
  private func call<Q: Message, R: Message>(_ method: Method, _ q: Q, _ t: R.Type) async throws -> R
  {
    let frame = try WireFrame.encode(q.serializedData())
    return try R(serializedBytes: WireFrame.decode(try await exchange(method, frame)))
  }
  public func unseenCount() async throws -> Int64 {
    var q = PiliBilibiliAppDynamicV1_DynRedReq()
    var tab = PiliBilibiliAppDynamicV1_TabOffset()
    tab.tab = 1
    q.tabOffset = [tab]
    let r = try await call(.unread, q, PiliBilibiliAppDynamicV1_DynRedReply.self)
    return max(0, r.dynRedItem.count)
  }
  private static func person(_ a: PiliBilibiliAppDynamicV2_ModuleAuthor) -> Person {
    .init(
      id: a.mid > 0 ? a.mid : a.author.mid, name: a.author.name, face: a.author.face,
      when: a.ptimeLabelText, pendant: a.author.pendant.image,
      verify: a.author.hasOfficial ? Int(a.author.official.type) : nil,
      vipStatus: Int(a.author.vip.status), vipType: Int(a.author.vip.type),
      cardURL: a.decorateCard.cardURL, fanNumber: a.decorateCard.fan.numberStr,
      fanPrefix: a.decorateCard.fan.numPrefix, fanColor: a.decorateCard.fan.color,
      sign: a.author.sign, level: Int(a.author.level), senior: a.author.isSeniorMember == 1)
  }
  private static func text(_ p: PiliBilibiliAppDynamicV2_TextParagraph) -> String {
    p.nodes.map { node in
      if !node.rawText.isEmpty { return node.rawText }
      switch node.text {
      case .word(let n): return n.words
      case .link(let n): return n.showText.words
      case .emote(let n): return n.rawText.words
      case .formula(let n): return n.latexContent.words
      case nil: return ""
      }
    }.joined()
  }
  private static func inline(_ p: PiliBilibiliAppDynamicV2_TextParagraph) -> [Inline] {
    p.nodes.compactMap { n in
      switch n.text {
      case .emote(let e):
        let label = e.rawText.words.isEmpty ? n.rawText : e.rawText.words
        return e.emoteURL.isEmpty ? .word(label) : .emote(label, e.emoteURL, Int(e.emoteWidth.emojiSize))
      case .link(let link):
        let label = link.showText.words.isEmpty ? n.rawText : link.showText.words
        if [.repostPicDynURL, .repostPicURL].contains(link.linkTypeEnum) {
          let pics = link.linkPics.items.filter { !$0.src.isEmpty }.map { Picture(url: $0.src, movie: $0.isLivePhoto ? $0.liveVideoURL : "") }
          if !pics.isEmpty { return .pictures(pics) }
        }
        if link.linkTypeEnum == .vote, let id = Int64(link.bizID), id > 0 { return .vote(label, id) }
        return link.link.isEmpty ? .word(label) : .link(label, link.link)
      case .word(let w): return .word(w.words.isEmpty ? n.rawText : w.words)
      case .formula(let f): return .word(n.rawText.isEmpty ? f.latexContent.words : n.rawText)
      case nil: return n.rawText.isEmpty ? nil : .word(n.rawText)
      }
    }
  }
  private static func inline(_ rows: [PiliBilibiliAppDynamicV2_Description]) -> [Inline] {
    rows.map { d in
      let label = d.text.isEmpty ? d.origText : d.text
      if d.type == .emoji && !d.uri.isEmpty { return .emote(label, d.uri, Int(d.emojiSize)) }
      return d.uri.isEmpty ? .word(label) : .link(label, d.uri)
    }
  }
  public func likes(_ id: String, cursor: String? = nil) async throws -> Page<Person> {
    guard !id.isEmpty else { throw WireError.invalid("动态编号为空") }
    var page: Int32 = 1
    var last: Int64 = 0
    if let cursor {
      let parts = cursor.split(separator: ":")
      guard parts.count == 2, let p = Int32(parts[0]), p > 0 && p < Int32.max,
        let m = Int64(parts[1]), m > 0
      else { throw WireError.invalid("点赞分页位置无效") }
      page = p
      last = m
    }
    var q = PiliBilibiliAppDynamicV2_LikeListReq()
    q.dynamicID = id
    q.page = page
    q.uidOffset = last
    let r = try await call(.likes, q, PiliBilibiliAppDynamicV2_LikeListReply.self)
    let people = r.list.map(Self.person).filter { $0.id > 0 }
    let tail = people.last?.id
    return .init(
      rows: people, total: r.totalCount,
      next: r.hasMore_p ? tail.flatMap { $0 != last && $0 > 0 ? "\(page+1):\($0)" : nil } : nil)
  }
  public func reposts(_ id: String, cursor: String? = nil) async throws -> Page<Repost> {
    var q = PiliBilibiliAppDynamicV2_RepostListReq()
    q.dynamicID = id
    q.repostType = .repostGeneral
    q.offset = cursor ?? ""
    let r = try await call(.reposts, q, PiliBilibiliAppDynamicV2_RepostListRsp.self)
    let items = r.list.compactMap { d -> Repost? in
      let id = d.extend.dynIDStr
      guard !id.isEmpty else { return nil }
      var author = Person(id: d.extend.uid, name: d.extend.upName, face: d.extend.upFace, when: "")
      var desc: PiliBilibiliAppDynamicV2_ModuleDesc?
      var opus: PiliBilibiliAppDynamicV2_ModuleOpusSummary? =
        d.extend.hasOpusSummary ? d.extend.opusSummary : nil
      for module in d.modules {
        switch module.moduleItem {
        case .moduleAuthor(let a): author = Self.person(a)
        case .moduleDesc(let md): desc = md
        case .moduleOpusSummary(let o): if opus == nil { opus = o }
        default: continue
        }
      }
      let candidates: [String?] = [
        desc?.text, desc?.desc.map(\.text).joined(), opus.map { Self.text($0.summary.text) },
        Self.text(d.extend.descTextOpus), d.extend.desc.map(\.text).joined(),
      ]
      let paragraphs = [
        opus.map { Self.inline($0.summary.text) } ?? [], desc.map { Self.inline($0.desc) } ?? [],
        Self.inline(d.extend.descTextOpus), Self.inline(d.extend.desc)
      ]
      let body = paragraphs.first { !$0.isEmpty } ?? []
      return .init(id: id, person: author,
        text: candidates.compactMap { $0 }.first(where: { !$0.isEmpty }) ?? "", body: body)
    }
    return .init(
      rows: items, total: r.totalCount,
      next: r.hasMore_p && !r.offset.isEmpty && r.offset != cursor ? r.offset : nil)
  }
  public func space(_ mid: Int64, filter: String = "all", cursor: String? = nil) async throws
    -> Flow
  {
    var q = PiliBilibiliAppDynamicV2_OpusSpaceFlowReq()
    q.hostMid = mid
    q.filterType = filter
    q.pagination.pageSize = 20
    q.pagination.next = cursor ?? ""
    let r = try await call(.space, q, PiliBilibiliAppDynamicV2_OpusSpaceFlowResp.self)
    let rows = r.itemList.compactMap { item -> Opus? in
      guard case .flowItemOpus(let op) = item.data else { return nil }
      let id = item.oid > 0 ? String(item.oid) : item.extend.dynIDStr
      guard !id.isEmpty else { return nil }
      return .init(
        id: id, text: Self.text(op.textParagraph.text), cover: op.coverPic.src,
        like: [op.bottomLeftText1.text, op.bottomLeftText2.text].filter { !$0.isEmpty }.joined(
          separator: " · "))
    }
    return .init(
      rows: rows,
      collections: r.hostUpOpusCollection.allCollections.filter {
        $0.collectionInfo.collectionID > 0
      }.map {
        .init(
          id: $0.collectionInfo.collectionID,
          title: $0.collectionInfo.title.texts.map(\.text).joined(), cover: $0.coverPic,
          subtitle: $0.subTitleText)
      }, next: r.nextPage.next.isEmpty || r.nextPage.next == cursor ? nil : r.nextPage.next)
  }
}
