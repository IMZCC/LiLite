import Foundation

@main enum MomentDomainCheck {
  typealias M = [String: Any]
  static func main() throws {
    let lottery = RichNode.parse(
      ["type": "RICH_TEXT_NODE_TYPE_LOTTERY", "orig_text": "结果", "rid": "10"], dynamicID: "123456")
    guard case .url(let result) = lottery?.target, result.query == "business_id=123456" else {
      preconditionFailure("lottery must use hosting dynamic identity")
    }
    let resource = RichNode.parse([
      "type": "RICH_TEXT_NODE_TYPE_VIEW_PICTURE", "rid": "9223372036854775809", "text": "图片",
    ])
    guard case .pictureResource("9223372036854775809") = resource?.target else {
      preconditionFailure("Picture resource was mistaken for a dynamic ID")
    }
    let supplied = RichNode.parse([
      "type": "RICH_TEXT_NODE_TYPE_VIEW_PICTURE", "rid": "10",
      "pics": [["src": "https://i0.hdslb.com/a.png"]],
    ])
    guard case .gallery(let local) = supplied?.target, local.count == 1 else {
      preconditionFailure("Embedded picture list has priority")
    }
    let pictures = try MomentPictureReply.photos(
      Data(
        #"{"code":0,"data":[{"src":"//i0.hdslb.com/a.png"},{"src":"https://i0.hdslb.com/a.png"},{"src":"file:///private/test"}]}"#
          .utf8))
    let empty = try MomentPictureReply.photos(Data(#"{"code":0,"data":null}"#.utf8))
    precondition(pictures.count == 1 && empty.isEmpty)
    do {
      _ = try MomentPictureReply.photos(Data(#"{"code":-403,"message":"不可访问","data":{}}"#.utf8))
      preconditionFailure("accepted denial")
    } catch {}
    let fields = MomentFilterFields(
      current: [
        "desc": ["text": "ALPHA"],
        "major": [
          "type": "MAJOR_TYPE_PGC", "pgc": ["title": "Plot"], "archive": ["title": "Ignored"],
        ],
      ], original: ["desc": ["text": "OMEGA"], "additional": ["type": "ADDITIONAL_TYPE_GOODS"]])
    let plain = try MomentListFilter(goods: false, pattern: "(?s)alpha.*omega|ignored")
    let block = try MomentListFilter(goods: false, pattern: "omega")
    let goods = try MomentListFilter(goods: true, pattern: "")
    precondition(
      plain.accepts(texts: fields.texts, goods: fields.goods)
        && !block.accepts(texts: fields.texts, goods: fields.goods)
        && !goods.accepts(texts: fields.texts, goods: fields.goods))

    precondition(
      DynamicPublishWire.receiptID(["dyn_id_str": "0", "dyn_id": 92]) == "92"
        && DynamicPublishWire.receiptID(["dyn_id_str": "not-a-number"]) == nil
        && DynamicPublishWire.receiptID([:]) == nil)
    let reserve: M = [
      "rid": "71", "title": "直播预约", "reserve_total": 10,
      "desc1": ["text": "明天"], "desc2": ["text": "10 人预约"],
      "button": [
        "status": 0, "type": 1,
        "check": ["text": "已预约"], "uncheck": ["text": "预约", "disable": 0],
      ],
    ]
    guard let r = MomentReservation(reserve), let form = r.intent(dynamic: "9301") else {
      fatalError()
    }
    precondition(
      r.buttonLabel == "预约" && r.status == 0 && form["dynamic_id_str"] as? String == "9301"
        && form["reserve_id"] as? Int64 == 71 && form["cur_btn_status"] as? Int == 0
        && form["reserve_total"] as? Int == 10)
    let receipt = r.received(["reserve_update": 11, "desc_update": "11 人预约", "final_btn_status": 1]
    )!
    precondition(
      receipt.buttonLabel == "已预约" && receipt.count == 11 && receipt.sub2 == "11 人预约"
        && receipt.intent(dynamic: "9301")?["cur_btn_status"] as? Int == 1)
    precondition(
      r.status == 0 && r.received(["desc_update": "not a receipt"]) == nil
        && r.intent(dynamic: "bogus") == nil)
    var locked = reserve
    locked["button"] = ["status": 0, "type": 1, "uncheck": ["disable": 1]]
    precondition(MomentReservation(locked)?.intent(dynamic: "9301") == nil)
    locked["button"] = [
      "status": 0, "type": 1, "jump_url": "https://live.bilibili.com/123",
      "jump_style": ["text": "去直播间"],
    ]
    let link = MomentReservation(locked)!
    precondition(
      link.intent(dynamic: "9301") == nil && link.jump == .native(.room(123))
        && link.buttonLabel == "去直播间")
    let modules: M = [
      "major": [
        "subscription_new": [
          "live_rcmd": [
            "content":
              "{\"live_play_info\":{\"room_id\":123,\"title\":\"今天的直播\",\"area_name\":\"音乐\"}}"
          ]
        ], "music": ["id": 12, "title": "声音"], "pgc": ["epid": 13, "title": "剧集"],
        "opus": [
          "title": "图文",
          "pics": [
            ["url": "https://i0.hdslb.com/x.jpg", "live_url": "https://i0.hdslb.com/x.mov"]
          ],
        ],
      ],
      "additional": [
        "reserve": reserve, "vote": ["vote_id": 140, "desc": "投票"],
        "goods": [
          "items": [
            [
              "name": "书", "price": "20", "jump_desc": "详情",
              "jump_url": "https://www.bilibili.com/read/cv88",
            ]
          ]
        ],
      ], "topic": ["id": 15, "name": "阅读"],
    ]
    let original = MomentResources(modules, quotedID: "9301")
    let ids = Set(original.cards.compactMap(\.target))
    precondition(
      Set<MomentDestination>([
        .native(.room(123)), .native(.song(12)), .native(.episode(13)), .native(.vote(140)),
        .native(.topic(15)), .native(.opus("9301")), .native(.article(88)),
      ]).isSubset(of: ids) && original.pictures.first?.motion != nil && original.reserve?.id == 71)
    let blocked = MomentResources(
      [
        "major": [
          "blocked": ["title": "仅供订阅者", "hint_message": "无访问权限"],
          "music": ["id": 12, "title": "隐藏"],
        ], "additional": ["reserve": reserve],
      ], quotedID: "9301")
    precondition(
      blocked.cards.count == 1 && blocked.cards[0].title == "仅供订阅者"
        && blocked.cards[0].target == nil && blocked.pictures.isEmpty && blocked.reserve == nil)
    precondition(
      MomentResources(["major": ["type": "MAJOR_TYPE_NONE", "none": ["tips": "已删除"]]]).cards[0]
        .title == "已删除")
    precondition(
      MomentResources.likeStatus(["modules": ["module_stat": ["like": ["status": "STATE_LIKE"]]]])
        == true
        && MomentResources.likeStatus(["modules": ["module_stat": ["like": ["status": false]]]])
          == false
        && MomentResources.likeStatus([:]) == nil)
    precondition(
      DynamicRevision.ownerPrivate(["icon_badge": ["text": "仅自己可见"]])
        && !DynamicRevision.ownerPrivate(["icon_badge": ["text": ""]]))
    let archiveRow: M = [
      "id_str": "912", "type": "DYNAMIC_TYPE_AV",
      "modules": [
        "module_author": ["mid": "75"],
        "module_dynamic": [
          "desc": ["text": "旧说明"], "major": ["archive": ["bvid": "BV1xx411c7mD", "title": "稿件标题"]],
        ],
      ],
    ]
    let captain = try DynamicRevision(row: archiveRow, expected: "75", id: "912")
    precondition(
      captain.resourceID?.contains("BV1xx411c7mD") == true && captain.title.isEmpty
        && captain.editor().text == "旧说明")
    let edit = captain.payload(
      contents: [.init(raw: "新说明", kind: 1, business: "")], title: "", pictures: [], topicID: nil,
      topicName: nil, isPrivate: false, replyMode: -1, uploadID: "fixture")
    let req = edit["dyn_req"] as? M
    precondition(
      edit["dyn_id_str"] as? String == "912" && req?["scene"] as? Int == 1 && req?["pics"] == nil
        && req?["archive"] == nil)
    precondition((try? DynamicRevision(row: archiveRow, expected: "76", id: "912")) == nil)
    let groups = try JSONDecoder().decode(
      [MomentMentionGroup].self,
      from: Data(
        #"[{"group_name":"关注","items":[{"uid":"33","name":"小明"},{"uid":34,"name":"小李","fans":"200"}]}]"#
          .utf8))
    precondition(groups[0].items?.map(\.id) == ["33", "34"] && groups[0].items?.last?.fans == 200)
    var draft = ReplyDraft()
    draft.change(to: "甲🙂尾")
    let slot = NSRange(location: ("甲🙂" as NSString).length, length: 0)
    _ = draft.replace(slot, with: "@小明", url: "@小明", kind: 2, business: "33")
    var active = try draft.mentionIDs()
    precondition(active == ["小明": 33])
    let at = (draft.text as NSString).range(of: "明")
    draft.replace(at, with: "红")
    active = try draft.mentionIDs()
    precondition(active.isEmpty && draft.raw == "甲🙂@小红 尾")
    var extend = ReplyDraft()
    extend.replace(nil, with: "@小明", url: "@小明", kind: 2, business: "33")
    extend.replace(.init(location: 3, length: 0), with: "哥")
    active = try extend.mentionIDs()
    precondition(active.isEmpty)
    var collision = ReplyDraft()
    collision.replace(nil, with: "@同名", url: "@同名", kind: 2, business: "1")
    collision.replace(nil, with: "@同名", url: "@同名", kind: 2, business: "2")
    precondition((try? collision.mentionIDs()) == nil)
    print(
      "Dynamic domain fixtures passed: actor status, reservation intent and receipt, quoted resources, private badge and mention identity"
    )
  }
}
