import Foundation

struct LiveAreaTag: Decodable, Identifiable {
  let area: Int, parent: Int, name: String, parentName: String, picture: String?
  var id: String { "\(parent):\(area)" }
  enum CodingKeys: String, CodingKey { case id, name, pic, parent_id, parent_name }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    guard let sub = try c.decode(ServiceID.self, forKey: .id).number.flatMap(Int.init(exactly:)), sub >= 0,
      let root = try c.decode(ServiceID.self, forKey: .parent_id).number.flatMap(Int.init(exactly:)), root >= 0
    else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid live area") }
    area = sub; parent = root
    name = try c.decode(String.self, forKey: .name)
    parentName = try c.decodeIfPresent(String.self, forKey: .parent_name) ?? ""
    picture = try c.decodeIfPresent(String.self, forKey: .pic)
  }
}

struct LiveAreaSection: Decodable, Identifiable {
  let name: String, area_list: [LiveAreaTag]?
  var id: String { name }
}
