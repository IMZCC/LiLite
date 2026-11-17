import Foundation

import PiliWireZlib

import SwiftProtobuf

public struct GatewayReply: Sendable {
  public let status: Int
  public let contentType: String, headers: [String: String]
  public let data: Data
  public init(status: Int, contentType: String, headers: [String: String], data: Data) {
    self.status = status
    self.contentType = contentType
    self.headers = headers
    self.data = data
  }
}
public enum WireError: Error, LocalizedError {
  case invalid(String)
  case remote(Int, String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let s): return s
    case .remote(let code, let s): return s.isEmpty ? "消息服务返回错误（\(code)）" : s
    }
  }
}
public enum WireFrame {
  public static let limit = 8 * 1024 * 1024
  public static func encode(_ bytes: Data) throws -> Data {
    guard bytes.count <= limit else { throw WireError.invalid("消息数据过大") }
    var header = Data([0])
    var size = UInt32(bytes.count).bigEndian
    withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
    header.append(bytes)
    return header
  }
  public static func decode(_ response: GatewayReply) throws -> Data {
    guard response.status == 200,
      response.contentType.lowercased().split(separator: ";").first.map({
        $0 == "application/grpc" || $0 == "application/grpc+proto"
      }) == true
    else { throw ServiceReceiptError.json(response) ?? WireError.invalid("消息服务未返回有效响应（\(response.status)）") }
    let headers = response.headers.reduce(into: [String: String]()) {
      $0[$1.key.lowercased()] = $1.value
    }
    guard let raw = headers["grpc-status"], let status = Int(raw) else {
      throw WireError.invalid("未收到消息服务的处理结果")
    }
    guard status == 0 else {
      throw ServiceReceiptError.grpc(status: status, headers: headers)
    }
    let d = response.data
    guard d.count >= 5, d.count <= limit + 5 else { throw WireError.invalid("消息响应长度异常") }
    let n = d.dropFirst().prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    guard Int(n) == d.count - 5 else { throw WireError.invalid("消息响应不完整") }
    if d.first == 0 { return Data(d.dropFirst(5)) }
    guard d.first == 1, headers["grpc-encoding"]?.lowercased() == "gzip" else {
      throw WireError.invalid("未知消息压缩格式")
    }
    return try gunzip(Data(d.dropFirst(5)))
  }
  private static func gunzip(_ input: Data) throws -> Data {
    var z = z_stream()
    guard inflateInit2_(&z, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw WireError.invalid("无法解压消息")
    }
    defer { inflateEnd(&z) }
    return try input.withUnsafeBytes { source in
      z.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
      z.avail_in = uInt(input.count)
      var out = Data()
      var buffer = [UInt8](repeating: 0, count: 16384)
      while true {
        let (status, written) = buffer.withUnsafeMutableBufferPointer { dest -> (Int32, Int) in
          z.next_out = dest.baseAddress
          z.avail_out = uInt(dest.count)
          let status = inflate(&z, Z_NO_FLUSH)
          return (status, dest.count - Int(z.avail_out))
        }
        guard out.count <= limit - written else { throw WireError.invalid("解压后的消息数据过大") }
        out.append(contentsOf: buffer.prefix(written))
        if status == Z_STREAM_END && z.avail_in == 0 { return out }
        guard status == Z_OK, written > 0 || z.avail_in > 0 else {
          throw WireError.invalid("压缩消息不完整")
        }
      }
    }
  }
}
public struct IMGateway: Sendable {
  public enum Method: String, Sendable {
    case main = "SessionMain"
    case secondary = "SessionSecondary"
    case update = "SessionUpdate"
    case detail = "SessionDetail"
    case clear = "ClearUnread"
    case delete = "DeleteSessionList"
    case settings = "GetImSettings"
    case saveSettings = "SetImSettings"
    case keywords = "KeywordBlockingList"
    case addKeyword = "KeywordBlockingAdd"
    case deleteKeyword = "KeywordBlockingDelete"
    case pin = "PinSession"
    case unpin = "UnpinSession"
    case unread = "GetTotalUnread"
    case shareList = "ShareList"
    case send = "SendMsg"
    case history = "SyncFetchSessionMsgs"
    public var path: String {
      [.unread, .shareList, .send, .history, .detail].contains(self)
        ? "/bilibili.im.interface.v1.ImInterface/" + rawValue
        : "/bilibili.app.im.v1.im/" + rawValue
    }
  }
  private let exchange: @Sendable (Method, Data) async throws -> GatewayReply
  public init(exchange: @escaping @Sendable (Method, Data) async throws -> GatewayReply) {
    self.exchange = exchange
  }
  private func rpc<Q: Message, R: Message>(_ m: Method, _ q: Q, _ t: R.Type) async throws -> R {
    let data = try WireFrame.encode(q.serializedData())
    return try R(serializedBytes: WireFrame.decode(try await exchange(m, data)))
  }
  public func history(talker: Int64, before: Int64?) async throws
    -> PiliBilibiliImInterfacesV1_RspSessionMsg
  {
    guard talker > 0, before.map({ $0 > 0 }) ?? true else { throw WireError.invalid("会话或页码无效") }
    var q = PiliBilibiliImInterfacesV1_ReqSessionMsg()
    q.talkerID = talker
    q.sessionType = 1
    q.size = 20
    q.devID = "1"
    if let before {
      q.beginSeqno = 0
      q.endSeqno = before
    }
    return try await rpc(.history, q, PiliBilibiliImInterfacesV1_RspSessionMsg.self)
  }
  public func shareContacts() async throws -> [PiliBilibiliImInterfacesV1_ShareSessionInfo] {
    var q = PiliBilibiliImInterfacesV1_ReqShareList()
    q.size = 5
    return try await rpc(.shareList, q, PiliBilibiliImInterfacesV1_RspShareList.self).sessionList
  }
  public func session(_ id: PiliIM_SessionId) async throws -> PiliIM_Session {
    guard id.id != nil else { throw WireError.invalid("会话不存在") }
    var req = PiliIM_SessionUpdateReq()
    req.sessionID = id
    let result = try await rpc(.update, req, PiliIM_SessionUpdateReply.self)
    guard result.hasSession, result.session.id.id == nil || result.session.id == id else {
      throw WireError.invalid("会话已变更")
    }
    return result.session
  }
  public func readSequence(talker: Int64) async throws -> Int64 {
    guard talker > 0 else { throw WireError.invalid("会话不存在") }
    var req = PiliBilibiliImInterfacesV1_ReqSessionDetail()
    req.talkerID = talker
    req.sessionType = 1
    let session = try await rpc(.detail, req, PiliBilibiliImType_SessionInfo.self)
    guard session.talkerID == 0 || session.talkerID == talker,
      session.sessionType == 0 || session.sessionType == 1, session.ackSeqno > 0
    else { throw WireError.invalid("没有可标记的消息") }
    return session.ackSeqno
  }
  public func sendCardOrNote(sender: Int64, to target: Int64, kind: Int32, content: String)
    async throws
  {
    guard sender > 0, target > 0, sender != target, [1, 2, 5, 7, 14].contains(kind),
      !content.isEmpty, content.utf8.count <= 1024 * 1024
    else { throw WireError.invalid("无效的分享内容") }
    if kind == 5 {
      guard (UInt64(content).map { $0 != 0 } ?? false) || (Int64(content).map { $0 < 0 } ?? false)
      else { throw WireError.invalid("撤回消息编号无效") }
    }
    var q = PiliBilibiliImInterfacesV1_ReqSendMsg()
    q.devID = UUID().uuidString
    q.msg.senderUid = sender
    q.msg.receiverID = target
    q.msg.receiverType = 1
    q.msg.msgType = kind
    q.msg.content = content
    q.msg.timestamp = Int64(Date().timeIntervalSince1970)
    q.msg.msgStatus = 0
    q.msg.newFaceVersion = 1
    let r = try await rpc(.send, q, PiliBilibiliImInterfacesV1_RspSendMsg.self)
    guard r.msgKey != 0 || r.seqno > 0 else { throw WireError.invalid("未收到消息编号，请在会话中核对") }
  }
  public struct SessionPage: Sendable {
    public let rows: [PiliIM_Session], menu: [PiliIM_ThreeDotItem], outside: [PiliIM_ThreeDotItem],
      cursor: String?
  }
  public func sessions(_ type: PiliIM_SessionPageType, cursor: String? = nil) async throws
    -> SessionPage
  {
    let last: PiliIM_PaginationParams
    if let cursor {
      guard cursor.utf8.count <= 65536, let d = Data(base64Encoded: cursor) else {
        throw WireError.invalid("会话分页位置无效")
      }
      last = try .init(serializedBytes: d)
    } else {
      last = .init()
    }
    func page(
      _ rows: [PiliIM_Session], _ menu: [PiliIM_ThreeDotItem], _ outside: [PiliIM_ThreeDotItem],
      _ p: PiliIM_PaginationParams
    ) throws -> SessionPage {
      var next: String?
      if p.hasMore_p && !p.offsets.isEmpty && p.offsets != last.offsets {
        var values = PiliIM_PaginationParams()
        values.offsets = p.offsets
        next = try values.serializedData().base64EncodedString()
      }
      return .init(rows: rows, menu: menu, outside: outside, cursor: next)
    }
    var input = PiliIM_PaginationParams()
    input.offsets = last.offsets
    if type == .home {
      var q = PiliIM_SessionMainReq()
      q.paginationParams = input
      let r = try await rpc(.main, q, PiliIM_SessionMainReply.self)
      return try page(r.sessions, r.threeDotItems, r.outsideItem, r.paginationParams)
    }
    guard type != .unknown else { throw WireError.invalid("未知会话分类") }
    var q = PiliIM_SessionSecondaryReq()
    q.pageType = type
    q.paginationParams = input
    let r = try await rpc(.secondary, q, PiliIM_SessionSecondaryReply.self)
    return try page(r.sessions, r.threeDotItems, r.outsideItem, r.paginationParams)
  }
  public func clearUnread(_ type: PiliIM_SessionPageType) async throws {
    var q = PiliIM_ClearUnreadReq()
    q.pageType = type
    _ = try await rpc(.clear, q, PiliIM_ClearUnreadReply.self)
  }
  public func deleteSessions(_ type: PiliIM_SessionPageType) async throws {
    guard type != .unknown else { throw WireError.invalid("未知会话分类") }
    var q = PiliIM_DeleteSessionListReq()
    q.pageType = type
    _ = try await rpc(.delete, q, PiliIM_DeleteSessionListReply.self)
  }
  public func pin(_ id: PiliIM_SessionId, enabled: Bool) async throws {
    guard id.id != nil else { throw WireError.invalid("会话不存在") }
    if enabled {
      var q = PiliIM_PinSessionReq()
      q.sessionID = id
      _ = try await rpc(.pin, q, PiliIM_PinSessionReply.self)
    } else {
      var q = PiliIM_UnPinSessionReq()
      q.sessionID = id
      _ = try await rpc(.unpin, q, PiliIM_UnPinSessionReply.self)
    }
  }
  public func noticeCounts() async throws -> [String: Int64] {
    var q = PiliBilibiliImInterfacesV1_ReqTotalUnread()
    q.unreadType = 2
    q.showUnfollowList = 1
    return try await rpc(.unread, q, PiliBilibiliImInterfacesV1_RspTotalUnread.self).msgFeedUnread
      .unread
  }
  public func settings(_ type: PiliIM_IMSettingType) async throws -> PiliIM_GetImSettingsReply {
    var q = PiliIM_GetImSettingsReq()
    q.type = type
    return try await rpc(.settings, q, PiliIM_GetImSettingsReply.self)
  }
  public func set(_ type: Int32, _ value: PiliIM_Setting) async throws {
    var q = PiliIM_SetImSettingsReq()
    q.settings = [type: value]
    _ = try await rpc(.saveSettings, q, PiliIM_SetImSettingsReply.self)
  }
  public func keywords() async throws -> PiliIM_KeywordBlockingListReply {
    try await rpc(.keywords, PiliIM_KeywordBlockingListReq(), PiliIM_KeywordBlockingListReply.self)
  }
  public func keyword(_ text: String, add: Bool) async throws {
    guard !text.isEmpty else { throw WireError.invalid("请输入关键词") }
    if add {
      var q = PiliIM_KeywordBlockingAddReq()
      q.keyword = text
      _ = try await rpc(.addKeyword, q, PiliIM_KeywordBlockingAddReply.self)
    } else {
      var q = PiliIM_KeywordBlockingDeleteReq()
      q.keyword = text
      _ = try await rpc(.deleteKeyword, q, PiliIM_KeywordBlockingDeleteReply.self)
    }
  }
}
