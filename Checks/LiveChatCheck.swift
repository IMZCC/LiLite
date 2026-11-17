import Foundation

@main enum LiveChatCheck {
  static func main() throws {
    func raw(_ id: String, start: Int = 100, end: Int = 200, _ text: String = "留言") -> [String: Any]
    {
      [
        "id": id, "uid": "9007199254740993", "price": 30, "start_time": start,
        "end_time": String(end), "message": text, "user_info": ["uname": "测试"],
        "uinfo": ["medal": ["name": "勋章", "level": 7]],
      ]
    }
    func bytes(_ o: Any) throws -> Data { try JSONSerialization.data(withJSONObject: o) }
    func event(_ item: [String: Any]) throws -> SuperChatEvent {
      guard let e = SuperChatEvent.parse(try bytes(["data": item]), command: "SUPER_CHAT_MESSAGE")
      else { throw ServiceError("失去实时留言") }
      return e
    }
    if let path = ProcessInfo.processInfo.environment["PILI_SC_SNAPSHOT"] {
      struct Response: Decodable { let code: Int, data: SuperChatSnapshot }
      let real = try JSONDecoder().decode(
        Response.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
      precondition(real.code == 0)
      print("Public room snapshot:", real.data.items.count, "paid messages")
    }
    let snap = try JSONDecoder().decode(
      SuperChatSnapshot.self,
      from: bytes(["list": [raw("3"), raw("1", start: 80, end: 120), ["id": 4]]]))
    precondition(
      snap.items.count == 2 && snap.items[0].uid == 9_007_199_254_740_993
        && snap.items[0].medal == "勋章")
    let msg3 = try event(raw("3", start: 100, end: 200, "实时更新"))
    let msg2 = try event(raw("2", start: 102, end: 105))
    let delete = SuperChatEvent.parse(
      try bytes(["data": ["ids": ["1"]]]), command: "SUPER_CHAT_MESSAGE_DELETE")!
    var store = SuperChatLedger()
    _ = store.accept(delete, now: 101, fullscreen: false)
    _ = store.accept(msg3, now: 101, fullscreen: true)
    precondition(
      store.overlay(at: 101)?.id == 3 && store.overlay(at: 110) != nil
        && store.overlay(at: 111) == nil)
    store.seed(snap.items)
    precondition(store.items.count == 1 && store.items[0].text == "实时更新")
    precondition(store.accept(msg3, now: 105, fullscreen: true) == nil)
    let added = store.accept(msg2, now: 103, fullscreen: true)
    precondition(added?.id == 2 && store.overlay(at: 105) == nil && store.overlay(at: 104)?.id == 2)
    precondition(
      store.visible(mode: .persistent, at: 150).map(\.id) == [2, 3]
        && store.visible(mode: .current, at: 150).map(\.id) == [3])
    precondition(store.visible(mode: .hidden, at: 103).isEmpty)
    store.trimExpired(at: 106)
    precondition(store.items.count == 1 && store.featured == nil)
    let data = try store.items[0].copyInfo(room: 8)
    let info = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    precondition(info["id"] as? Int == 3 && info["message"] as? String == "实时更新")
    print(
      "PASS live paid messages: mixed IDs, initial snapshot, live edits, deletion races, expiry, retained history and fullscreen timing"
    )
  }
}
