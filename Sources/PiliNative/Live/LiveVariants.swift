import Foundation

struct LiveFormat: Hashable, Identifiable {
  let proto: String, format: String, codec: String
  var id: Self { self }
  var triple: [String] { [proto, format, codec] }
  var remux: Bool { proto == "http_stream" && format == "flv" }
  var label: String {
    let codecName = ["avc": "H.264", "hevc": "HEVC", "av1": "AV1"][codec] ?? codec.uppercased()
    return (remux ? "FLV" : "HLS · " + format.uppercased()) + " · " + codecName
  }
  init(_ p: String, _ f: String, _ c: String) {
    proto = p
    format = f
    codec = c
  }
  init?(_ triple: [String]?) {
    guard let t = triple, t.count == 3,
      t.allSatisfy({
        !$0.isEmpty && $0.utf8.count <= 32 && $0.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 })
      })
    else { return nil }
    self.init(t[0], t[1], t[2])
  }
}
struct LiveVariant: Identifiable {
  struct Endpoint { let url: URL, quality: Int, resource: String }
  let id: LiveFormat, endpoints: [Endpoint], choices: [Int]
  var sources: [URL] { endpoints.map(\.url) }
}
extension LiveSource {
  static func variants(in streams: [Stream]) -> [LiveVariant] {
    var rows = [LiveVariant]()
    for s in streams {
      for f in s.format {
        guard
          s.protocol_name == "http_hls"
            || (s.protocol_name == "http_stream" && f.format_name == "flv")
        else { continue }
        for c in f.codec {
          let key = LiveFormat(s.protocol_name, f.format_name, c.codec_name)
          let candidates = c.url_info.compactMap { h -> LiveVariant.Endpoint? in
            guard let base = httpsURL(h.host), base.user == nil, base.password == nil,
              let u = httpsURL(h.host + c.base_url + (h.extra ?? "")),
              u.host?.lowercased() == base.host?.lowercased(), u.user == nil, u.password == nil
            else { return nil }
            return .init(url: u, quality: c.current_qn, resource: c.base_url + (h.extra ?? ""))
          }
          if candidates.isEmpty { continue }
          let old = rows.firstIndex { $0.id == key }
          let merged = (old.map { rows[$0].endpoints } ?? []) + candidates
          var seen = Set<URL>()
          let urls = merged.filter { seen.insert($0.url).inserted }
          let row = LiveVariant(
            id: key, endpoints: urls,
            choices: Array(
              Set((old.map { rows[$0].choices } ?? []) + (c.accept_qn ?? []) + [c.current_qn])
            ).sorted(by: >))
          if let old { rows[old] = row } else { rows.append(row) }
        }
      }
    }
    return rows
  }
}
