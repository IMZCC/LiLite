import Foundation

@main enum LiveInteractionCheck {
  static func main() throws {
    let packs=try JSONDecoder().decode(LiveEmoteChoices.self,from:Data(#"{"data":[{"pkg_type":3,"emoticons":[{"emoji":"[花]"},{"emoji":"[花]"}]},{"pkg_type":1,"emoticons":[{"emoticon_unique":"official:X","emoji":"A","perm":0},{"emoji":"bad"}]}]}"#.utf8))
    precondition(packs.groups.count==2 && packs.groups[0].insertsText && packs.groups[0].rows.count==1 && !packs.groups[1].insertsText && packs.groups[1].rows.count==1 && !packs.groups[1].rows[0].available)
    let text="甲🙂乙";let (composed,caret)=LiveEmoteChoices.insert("[花]",in:text,selection:NSRange(location:1,length:2))
    precondition(composed=="甲[花]乙" && caret==NSRange(location:4,length:0))
    precondition(LiveEmoteChoices.insert("[花]",in:text,selection:NSRange(location:2,length:1)).0=="甲🙂乙[花]")
    let follows = try JSONDecoder().decode(LiveFollowPage.self, from: Data(#"{"list":[{"roomid":1,"live_status":0},{"roomid":2,"live_status":1,"area_name":"音乐","text_small":"热度"},{"roomid":2,"live_status":1}],"totalPage":2,"live_count":1}"#.utf8))
    precondition(follows.onAir.map(\.id) == [2] && follows.onAir[0].area_name == "音乐" && follows.next(after:1,uniqueSeen:0) == "2" && follows.next(after:1,uniqueSeen:1) == nil && follows.next(after:2,uniqueSeen:0) == nil)
    let normal = LiveSource.request(room:6,quality:400,audioOnly:false)
    let audio = LiveSource.request(room:6,quality:400,audioOnly:true)
    precondition(normal["qn"] == "400" && normal["room_id"] == "6" && normal["only_audio"] == nil && normal["dolby"] == "5")
    precondition(audio["only_audio"] == "1" && audio.filter { $0.key != "only_audio" } == normal)
    precondition(LiveRoomUpdate.read(["cmd":"ROOM_CHANGE","data":["title":"新标题"]]) == .title("新标题"))
    precondition(LiveRoomUpdate.read(["cmd":"ONLINE_RANK_COUNT","data":["count":0]]) == .online(0))
    precondition(LiveRoomUpdate.read(["cmd":"WATCHED_CHANGE","data":["text_large":"1 万人看过"]]) == .watched("1 万人看过"))
    precondition(LiveRoomUpdate.read(["cmd":"ONLINE_RANK_COUNT","data":["count":-3]]) == nil)
    typealias Map = [String: Any]
    let user: Map = [
      "uid": 37, "base": ["name": "发送者"], "medal": ["is_light": 1, "name": "星星", "level": 8],
    ]
    let origin = "000918337203685477580714"
    let proof = ["ct": "test-receipt/+", "ts": "1730000001"]
    let rich: Map = [
      "id_str": origin, "dm_type": 3, "reply_mid": 208, "reply_uname": "被回复者",
      "mode": 5, "color": 16_711_935,
      "emots": ["[你好]": ["url": "https://i0.hdslb.com/example.png"]],
    ]
    var row = rich
    row["user"] = user
    row["check_info"] = proof
    row["text"] = "原文 原样[你好]"
    row["reply"] = rich
    let raw = try JSONSerialization.data(withJSONObject: [
      "code": 0,
      "data": [
        "room": [
          row,
          [
            "nickname": "旧用户", "uid": 45, "text": "旧弹幕", "id_str": "unbound", "check_info": proof,
            "dm_type": 0,
          ],
        ]
      ],
    ])
    let history = try LiveMessageSource.history(raw, room: 201)
    precondition(history.count == 2)
    let h = history[0]
    let legacy = history[1]
    precondition(
      h.name == "发送者" && h.medal == "星星 8" && h.repliedUID == 208 && h.inlineEmotes.count == 1)
    let expected = [
      "id": "0", "roomid": "201", "tuid": "37", "msg": "原文 原样[你好]", "reason": "垃圾广告",
      "reason_id": "3", "ts": "1730000001",
      "sign": "test-receipt/+", "token": "", "dm_type": "3", "id_str": origin, "visit_id": "",
    ]
    precondition(h.reportFields(room: 201, reason: .advertising) == expected)
    precondition(h.reportFields(room: 102, reason: .advertising) == nil)
    let reply = h.reply(room: 201, account: "91")!
    precondition(
      reply.fields(room: 201, account: "91") == ["replay_dmid": origin, "reply_mid": "37"])
    precondition(
      reply.fields(room: 201, account: "92") == nil && reply.fields(room: 202, account: "91") == nil
    )
    precondition(
      legacy.uid == 45 && legacy.reportFields(room: 201, reason: .other) == nil
        && legacy.reply(room: 201, account: "91") == nil)
    let tokenJSON = String(
      decoding: try JSONSerialization.data(withJSONObject: rich), as: UTF8.self)
    func frame(user: [String: Any], status: Map, uid: Any = 37) -> LiveLine {
      var a = [Any](repeating: 0, count: 16)
      var b = [Any](repeating: 0, count: 10)
      a[13] = ["url": "https://i0.hdslb.com/hi.png"]
      a[15] = ["user": user, "extra": tokenJSON]
      b[0] = a
      b[1] = h.text
      b[2] = [uid, "旧名称"]
      b[9] = status
      // Round-trip to service JSON types (not Swift's manually created integer boxes).
      let decoded =
        try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: b)) as! [Any]
      return LiveMessageSource.socket(decoded, room: 201)!
    }
    let live = frame(user: user, status: proof)
    precondition(live.reportFields(room: 201, reason: .advertising) == expected)
    precondition(
      live.arrived != nil && h.arrived == nil && live.mode == 5 && live.rgb == 16_711_935)
    precondition(
      live.emote != nil && live.repliedName == "被回复者" && live.sourceID == origin
        && live.copyInfo().contains(origin))
    precondition(frame(user: user, status: [:]).reportFields(room: 201, reason: .other) == nil)
    precondition(
      frame(user: user, status: proof, uid: 91).reportFields(room: 201, reason: .other) == nil)
    precondition(
      frame(user: ["uid": true], status: proof).reportFields(room: 201, reason: .other) == nil)
    precondition(LiveReportReason.allCases.map(\.rawValue) == [1, 2, 3, 4, 5, 6, 0])
    let fixture =
      #"{"has_more":1,"card_list":[{"card_type":"banner_v2"},{"card_type":"area_entrance_v3","card_data":{"area_entrance_v3":{"list":[{"title":"区","area_v2_parent_id":6,"area_v2_id":204}]}}},{"card_type":"my_idol_v1","card_data":{"my_idol_v1":{"list":[{"roomid":81,"title":"关注"}]}}},{"card_type":"small_card_v1","card_data":{"small_card_v1":{"id":201,"title":"直播","feedback":[{"title":"不感兴趣","reasons":[{"id":37,"name":"不喜欢主播","id_type":"uid","reason_id":888}]}]}}}]}"#
    let data = try JSONDecoder().decode(LiveFeedCards.self, from: Data(fixture.utf8))
    var card = data.card_list.compactMap(\.room).first!
    card.page = 3
    card.viewer = "29"
    let option = card.feedback!.first!.reasons!.first!
    precondition(
      data.card_list.flatMap(\.areas).first?.area_v2_id == 204
        && data.card_list.flatMap(\.followed).first?.id == 81)
    precondition(
      card.feedbackFields(option, owner: "29") == [
        "type": "dislike", "room_id": "201", "page": "3", "id_type": "uid", "id": "37",
      ])
    precondition(card.feedbackFields(option, owner: "31") == nil)
    precondition(
      card.feedbackFields(.init(id: 888, name: option.name, id_type: option.id_type), owner: "29")
        == nil)
    let paid: Map = [
      "id": 89, "uid": "37", "price": 30, "message": "付费留言", "user_info": ["uname": "观众"],
      "start_time": 100, "end_time": 150,
      "ts": "101", "token": "original-sc-token",
    ]
    func superChat(_ object: Map) throws -> SuperChatMessage {
      try JSONDecoder().decode(
        SuperChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let sc = try superChat(paid)
    let report = sc.reportFields(room: 201, label: "其他")
    precondition(
      report?["reason_id"] == "其他" && report?["uid"] == "37" && report?["ts"] == "101"
        && report?["token"] == "original-sc-token")
    var unsigned = paid
    unsigned.removeValue(forKey: "ts")
    let missingTime = try superChat(unsigned)
    precondition(!missingTime.reportable && missingTime.reportFields(room: 201, label: "其他") == nil)
    let r = LiveRoomIdentity(room_id: 201, uid: 104)
    var counter = LiveLikeCounter()
    precondition(counter.take() == 0)
    counter.tap()
    counter.tap()
    counter.tap()
    precondition(
      r.likeFields(taps: counter.take(), owner: "29", csrf: "mock") == [
        "room_id": "201", "click_time": "3", "anchor_id": "104", "uid": "29", "csrf": "mock",
        "web_location": "444.8",
      ])
    precondition(r.likeFields(taps: counter.take(), owner: "29", csrf: "mock") == nil)
    print(
      "PASS: history/socket receipts, unsendable legacy lines, frozen mentions, exact normal/paid reports, service card provenance and physical like batches"
    )
  }
}
