import Foundation

struct SavedReply: Codable, Identifiable {
  let id: Int64, oid: Int64, type: Int, root: Int64?, date: Double, body: String, pictures: [String]
  var archivedProto: Data? = nil
  static func parse(_ v: [String: Any], oid: Int64? = nil, type: Int? = nil, root: Int64? = nil)
    -> Self?
  {
    func number(_ v: Any?) -> Int64? {
      (v as? String).flatMap(Int64.init) ?? (v as? NSNumber)?.int64Value
    }
    guard oid.map({ expected in number(v["oid"]).map{$0==expected} ?? true}) != false,type.map({ expected in number(v["type"]).map{$0==Int64(expected)} ?? true}) != false,let id = number(v["rpid_str"] ?? v["rpid"] ?? v["id"]), id > 0, let oid = oid ?? number(v["oid"]), oid > 0,
      let type = type ?? number(v["type"]).flatMap(Int.init(exactly:)), type > 0,
      let c = v["content"] as? [String: Any], let body = c["message"] as? String
    else { return nil }
    let refs = c["pictures"] as? [[String: Any]] ?? []
    let urls = refs.compactMap { ($0["img_src"] ?? $0["imgSrc"]) as? String }
    var wire:Data?
    if v["rpid"]==nil,v["id"] != nil{wire=try? JSONSerialization.data(withJSONObject:v)}
    else{
      typealias M=[String:Any]
      var w:M=["id":String(id),"oid":String(oid),"type":String(type)]
      for key in ["root","parent","mid","ctime","like","dialog"]{if let n=number(v[key]){w[key]=String(n)}}
      if let n=number(v["rcount"]){w["count"]=String(n)}
      var content:M=["message":body]
      if let names=c["at_name_to_mid"] as? M{content["atNameToMid"]=names.compactMapValues{number($0).map(String.init)}}
      if let emotes=c["emote"] as? [String:M]{content["emotes"]=emotes.mapValues{e in
        var out:M=[:];for k in ["text","url","gif_url","webp_url","jump_url","jump_title"]{out[k]=e[k] as? String};out["size"]=number((e["meta"] as? M)?["size"]).map(String.init);return out}}
      if !refs.isEmpty{content["pictures"]=refs.map{p in var m:M=[:];m["imgSrc"]=p["img_src"] as? String;for (a,b) in [("img_width","imgWidth"),("img_height","imgHeight")]{if let n=number(p[a]){m[b]=String(n)}};return m}}
      if let topics=c["topics"] as? [String:M]{content["topics"]=topics.mapValues{t in var m:M=[:];m["link"]=t["link"] as? String;m["id"]=number(t["id"]).map(String.init);return m}}
      if let vote=c["vote"] as? M{var m:M=[:];m["id"]=number(vote["id"]).map(String.init);m["title"]=vote["title"] as? String;content["vote"]=m}
      if let jumps=c["jump_url"] as? [String:M]{content["urls"]=jumps.mapValues{j in var m:M=[:];for (a,b) in [("title","title"),("app_url_schema","appUrlSchema"),("prefix_icon","prefixIcon")]{m[b]=j[a] as? String};return m}}
      w["content"]=content
      if let member=v["member"] as? M{var m:M=[:];m["mid"]=number(member["mid"] ?? v["mid"]).map(String.init);m["name"]=member["uname"] as? String;m["face"]=member["avatar"] as? String
        m["level"]=number((member["level_info"] as? M)?["current_level"]).map(String.init)
        m["officialVerifyType"]=number((member["official_verify"] as? M)?["type"]) ?? -1
        if let vip=member["vip"] as? M{m["vipStatus"]=number(vip["vipStatus"] ?? vip["vip_status"]);m["vipType"]=number(vip["vipType"] ?? vip["vip_type"])};w["member"]=m}
      if let n=number(v["action"]){w["replyControl"]=["action":String(n)]}
      wire=try? JSONSerialization.data(withJSONObject:w)
    }
    return .init(id:id,oid:oid,type:type,root:root ?? number(v["root"]),date:Double(min(253_402_300_799,max(0,number(v["ctime"]) ?? 0))),body:body,pictures:urls,archivedProto:wire)
  }
  var proto: [String: Any] {
    if let bytes = archivedProto, let result = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] { return result }
    var result: [String: Any] = [
      "id": String(id), "oid": String(oid), "type": String(type), "ctime": String(Int64(date)),
      "content": ["message": body, "pictures": pictures.map { ["imgSrc": $0] }],
    ]
    if let root, root > 0 { result["root"] = String(root) }
    return result
  }
}
actor ReplyArchive {
  static let shared = ReplyArchive()
  private let overrideDirectory: URL?
  init(directory: URL? = nil) { overrideDirectory = directory }
  private func file(_ uid: String) throws -> URL {
    guard let mid = Int64(uid), mid > 0, String(mid) == uid else { throw ServiceError("账号无效") }
    let dir = overrideDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ReplyArchive", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(uid + ".json")
  }
  func items(_ uid: String) throws -> [SavedReply] {
    let url = try file(uid)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([SavedReply].self, from: Data(contentsOf: url)).sorted {
      $0.date > $1.date
    }
  }
  func merge(_ rows: [SavedReply], uid: String) throws {
    var byID: [Int64: SavedReply] = [:]
    for r in try items(uid) { byID[r.id] = r }
    for r in rows { byID[r.id] = r }
    try write(Array(byID.values), uid)
  }
  /// The caller can undo this merge only if nobody else edited the same account's file.
  func mergeForPack(_ rows: [SavedReply], uid: String) throws -> (Data?, Data) {
    let url = try file(uid)
    let old = try FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil
    var byID: [Int64: SavedReply] = [:]
    for r in try items(uid) { byID[r.id] = r }
    for r in rows { byID[r.id] = r }
    let new = try JSONEncoder().encode(byID.values.sorted { $0.id > $1.id })
    try new.write(to: url, options: .atomic)
    return (old, new)
  }
  func rollbackPack(_ receipt: (Data?, Data), uid: String) throws {
    let url = try file(uid)
    guard try Data(contentsOf: url) == receipt.1 else { throw ServiceError("评论已被修改，请检查恢复结果") }
    if let old = receipt.0 { try old.write(to: url, options: .atomic) } else { try FileManager.default.removeItem(at: url) }
  }
  func clear(_ uid: String) throws { try write([], uid) }
  func remove(_ id: Int64, uid: String) throws { try write(items(uid).filter { $0.id != id }, uid) }
  private func write(_ input: [SavedReply], _ uid: String) throws {
    try JSONEncoder().encode(input.sorted { $0.id > $1.id }).write(to: file(uid), options: .atomic)
  }
  func capture(_ data: Data, oid: Int64, type: Int, root: Int64?, uid: String) throws {
    guard UserDefaults.standard.object(forKey: "reply.save") as? Bool ?? true else { return }
    let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard (raw?["code"] as? Int)==0,let info = (raw?["data"] as? [String: Any])?["reply"] as? [String: Any],
      (info["mid"].map{String(describing:$0)}).map({$0==uid}) != false,
      let row = SavedReply.parse(info, oid: oid, type: type, root: root)
    else { throw ServiceError("服务端没有返回可保存的评论") }
    try merge([row], uid: uid)
  }
  func importData(_ data: Data, uid: String) throws {
    guard data.count <= 32 * 1024 * 1024,
      let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { throw ServiceError("不是有效的评论备份") }
    let rows = list.compactMap { SavedReply.parse($0) }
    guard rows.count == list.count else { throw ServiceError("备份里有无法读取的评论") }
    try merge(rows, uid: uid)
  }
  func export(_ uid: String) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: items(uid).map(\.proto), options: [.prettyPrinted, .sortedKeys])
  }
}
