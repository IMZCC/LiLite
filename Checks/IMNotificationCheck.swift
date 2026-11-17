import Foundation

@main struct IMNotificationCheck {
  static func main() throws {
    let text = #"新通知 #{查看专栏}{"bilibili://article/52"}、【BV17x411w7KC】、（823） www.example.test/link"#
    let nodes = NoticeMarkup.nodes(text)
    precondition(nodes.compactMap(\.target).count == 4)
    precondition(nodes.contains { $0.target == .route(.article(52)) })
    precondition(nodes.contains { $0.target == .route(.dynamic("823")) })
    precondition(NoticeMarkup.nodes("#{查看}{javascript:thing}").allSatisfy { $0.target == nil })
    let link = "bilibili://following/detail/99?comment_root_id=432&comment_secondary_id=433"
    precondition(NoticeMarkup.reply(link, oid: 107, business: 17) == .commentOn(.dynamic("99"), 432, 433))
    precondition(
      NoticeMarkup.reply(link, oid: 0, business: 17) == nil
        && NoticeMarkup.reply(link, oid: 107, business: 0) == nil)
    let base: [String: Any] = [
      "width": 500, "height": 300, "url": "https://i0.hdslb.com/bfs/im/p.png", "imageType": "png",
      "size": 13.5, "sender_uid": "private-other",
    ]
    guard case .photo(let image) = IMForwardContent.read(type: 2, fields: base) else {
      preconditionFailure()
    }
    precondition(image.fields["sender_uid"] == nil && image.fields["imageType"] as? String == "png")
    for key in [
      "http://i0.hdslb.com/bfs/im/p.png", "https://i0.hdslb.com.other.example/p.png",
      "https://who:pw@i0.hdslb.com/p.png", "https://i0.hdslb.com:9443/p.png",
    ] {
      var m = base
      m["url"] = key
      precondition(IMForwardContent.read(type: 2, fields: m) == nil)
    }
    precondition(
      IMForwardContent.read(type: 18, fields: ["content": "notice"]) == nil
        && IMForwardContent.read(type: 5, fields: ["content": "withdrawn"]) == nil
        && IMForwardContent.read(type: 1, fields: ["content": " "]) == nil)
    let counts = try JSONDecoder().decode(
      IMUnreadFields.self, from: Data(#"{"reply":"2","at":3,"extra":{"server":"new"}}"#.utf8))
    precondition(counts.values == ["reply": 2, "at": 3])
    print(
      "notice actions: structured links, anchored replies, unread fields, confirmed share types and photo boundary passed"
    )
  }
}
