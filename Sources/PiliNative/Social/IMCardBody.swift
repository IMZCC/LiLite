import Foundation

struct IMCardBody {
  struct Row {
    let title: String, detail: String, image: URL?, target: RichNode.Target?
  }
  let rows: [Row]
  init(type: Int?, data: [String: Any], fallback: String) {
    typealias Map = [String: Any]
    func value(_ value: Any?) -> String {
      (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
    }
    func image(_ raw: Any?) -> URL? { GalleryPicture.source(value(raw)) }
    func jump(_ v: Any?) -> RichNode.Target? {
      let raw = value(v)
      if let r = SharedLink.parse(raw) { return .route(r) }
      return GalleryPicture.source(raw).map(RichNode.Target.url)
    }
    func array(_ any: Any?) -> [Map] {
      if let a = any as? [Map] { return a }
      if let s = any as? String {
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [Map] ?? []
      }
      return []
    }
    var list = [Row]()
    func add(
      _ title: String, _ details: String = "", _ pic: URL? = nil, _ dest: RichNode.Target? = nil
    ) {
      if !title.isEmpty || !details.isEmpty || pic != nil || dest != nil {
        list.append(.init(title: title, detail: details, image: pic, target: dest))
      }
    }
    switch type {
    case 10:
      add(value(data["title"]), value(data["text"]))
      for m in array(data["modules"]) { add(value(m["title"]), value(m["detail"])) }
      for suffix in ["", "_2", "_3"] {
        if let dest = jump(data["jump_uri" + suffix]) {
          let label = value(data["jump_text" + suffix])
          add(label.isEmpty ? "查看详情" : label, "", nil, dest)
        }
      }
    case 11:
      if value(data["times"]) == "0" {
        add("内容已失效")
      } else {
        add(value(data["title"]), value(data["times"]), image(data["cover"]), jump(data["bvid"]))
      }
      add(value((data["attach_msg"] as? Map)?["content"]))
    case 12:
      let rid = Int64(value(data["rid"]))
      let pics = (data["image_urls"] as? [String] ?? []).compactMap(GalleryPicture.source)
      let target = rid.flatMap { $0 > 0 ? RichNode.Target.route(.article($0)) : nil }
      add(value(data["title"]), value(data["summary"]), pics.first, target)
      for pic in pics.dropFirst() { add("", "", pic, target) }
    case 13:
      let pic = image(data["pic_url"])
      add(
        value(data["title"]), "", pic, jump(data["jump_url"]) ?? pic.map { .gallery([.init($0)]) })
    case 14:
      add(
        value(data["title"]),
        [value(data["source"]), value(data["author"])].filter { !$0.isEmpty }.joined(
          separator: " · "), image(data["cover"]), jump(data["jump_url"]))
    case 16:
      add(value(data["main_title"]))
      for item in array(data["sub_cards"]) {
        add(
          value(item["field1"]),
          [value(item["field2"]), value(item["field3"])].filter { !$0.isEmpty }.joined(
            separator: "\n"), image(item["cover_url"]), jump(item["jump_url"]))
      }
    case 18:
      let body = array(data["content"]).map { value($0["text"]) }.filter { !$0.isEmpty }.joined(
        separator: "\n")
      add(body.isEmpty ? value(data["content"]) : body)
    case 7:
      add(
        value(data["title"]).isEmpty ? value(data["headline"]) : value(data["title"]),
        value(data["author"]), image(data["thumb"]), jump(data["bvid"]) ?? jump(data["jump_url"]))
    default: break
    }
    if list.isEmpty { add(fallback) }
    rows = list
  }
}
