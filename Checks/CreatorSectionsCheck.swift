import Foundation

@main enum CreatorSectionsCheck {
  static func main() throws {
    let record: [String: Any] = [
      "tab2": [
        ["param": "home"], ["param": "unsupported"], ["param": "shop"],
        [
          "param": "contribute",
          "items": [
            ["param": "video"], ["param": "series", "series_id": "44"],
            ["param": "series", "series_id": 45], ["param": "season_video", "season_id": "bad"],
            ["param": "charging_video"],
          ],
        ], ["param": "home"], ["param": "dynamic"],
      ],
      "default_tab": "video",
      "guard": ["desc":"120人", "item":[["face":"face"]]], "elec":["total":5, "list":[["avatar":"avatar"]]],
      "images":["imgUrl":"day","night_imgurl":"night","collection_top_simple":["top":["result":[[
        "cover":"full","item":["image":["default_image":"thumb","height":100,"location":"0-25-75"]],
        "title":["title":"主页", "sub_title":"预览"]
      ], ["item": ["image":[:]]]]]]],
      "card": [
        "name": "样例", "face": "//example.org/face", "vip": ["vipStatus": 1, "vipType": "2"],
        "official_verify": ["type": "0"], "relation": ["is_followed": 1], "silence": 1,
        "pr_info": ["content":"活动","url":"https://www.bilibili.com"],
        "space_tag": [["title":"创作","uri":"bilibili://space/33"], ["title":""]],
        "live_fans_wearing": ["detail_v2": ["medal_name": "测试", "level": "8"]],
      ],
      "setting": ["fav_video": 0], "live": ["roomStatus": 1, "liveStatus": 0, "roomid": "37"],
      "medal": 1, "series": ["item": [["title": "列表"]]],
      "archive": [
        "count": 80,
        "item": [
          ["goto": "av", "param": "44", "title": "普通"],
          ["goto": "bangumi", "param": "44", "title": "正片"],
          ["goto": "av", "param": "44", "title": "重复"],
        ],
      ],
      "favourite2": ["count": 2, "item": [["media_id": 55, "id": 99, "title": "文件夹"]]],
      "season": ["count": 1, "item": [["param": "77", "title": "季"]]],
      "article": [
        "item": [["uri": "bilibili://article/88", "origin_image_urls": ["//example.org/a"]]]
      ],
      "audios": ["item": [["id": 10]]], "comic": ["item": [["param": "11"]]],
    ]
    func decode(_ o: [String: Any]) throws -> CreatorSpaceRecord {
      try JSONDecoder().decode(
        CreatorSpaceRecord.self, from: JSONSerialization.data(withJSONObject: o))
    }
    let d = try decode(record)
    let detail = d.headerDetails
    precondition(d.person?.followsViewer == true && detail.muted && detail.medalLevel == 8 && detail.medal == "测试")
    precondition(detail.day == "day" && detail.night == "night" && detail.tags.count == 1 && detail.promo == "活动")
    precondition(detail.banners.first?.full == "full" && detail.banners.first?.preview == "thumb" && detail.banners.first?.alignment == 0)
    precondition(detail.guardCount == 120 && detail.chargeCount == 5 && detail.guards == ["face"] && detail.charges == ["avatar"])
    let tabs = d.sections(shop: false)
    precondition(tabs.map(\.param) == ["home", "contribute", "dynamic"])
    precondition(
      d.preferred(0, in: tabs) == "contribute" && d.preferred(7, in: tabs) == "contribute")
    precondition(
      d.preferred(7, in: d.sections(shop: true)) == "shop" && d.preferred(2, in: tabs) == "dynamic")
    precondition(
      d.contributions(tabs[1]).map(\.param) == [
        "video", "series", "series", "charging_video", "ugcSeason",
      ])
    precondition(
      d.groups[0].items.map(\.destination) == [.link(.archive(44, 1)), .link(.episode(44))]
        && d.groups[0].count == 80)
    precondition(
      d.groups[1].items.first?.destination == .folder(55) && d.groups[1].visible == false)
    precondition(
      d.groups.map(\.items).flatMap { $0 }.contains { $0.destination == .link(.article(88)) })
    precondition(d.groups.last?.items.first?.destination == .link(.season(77)))
    precondition(d.person?.vipType == 2 && d.person?.verifyType == 0 && !d.onAir && d.room == 37)
    let empty = try decode([
      "tab2": [["param": "home"], ["param": "shop"], ["param": "cheese"]], "default_tab": "home",
    ])
    precondition(empty.person == nil && !empty.headerDetails.muted && empty.headerDetails.banners.isEmpty && empty.headerDetails.chargeCount == nil)
    precondition(
      empty.sections(shop: false).map(\.param) == ["cheese"]
        && empty.preferred(1, in: empty.sections(shop: false)) == "cheese")
    print(
      "Creator sections: visibility, preferences, default alias, contributed lists, typed home destinations, profile fields passed"
    )
  }
}
