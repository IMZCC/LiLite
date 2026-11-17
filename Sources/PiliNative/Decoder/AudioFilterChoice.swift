import Foundation

struct AudioMeasurements: Codable, Hashable {
  let measured_i, measured_lra, measured_tp, measured_threshold, target_offset, target_i,
    target_tp: Double?
  enum CodingKeys: String, CodingKey {
    case measured_i, measured_lra, measured_tp, measured_threshold, target_offset, target_i,
      target_tp
  }
  init(from decoder: Decoder) throws {
    let box = try? decoder.container(keyedBy: CodingKeys.self)
    func n(_ k: CodingKeys) -> Double? {
      guard let box else { return nil }
      let number =
        (try? box.decode(Double.self, forKey: k))
        ?? (try? box.decode(String.self, forKey: k)).flatMap(Double.init)
      return number.flatMap { $0.isFinite ? $0 : nil }
    }
    measured_i = n(.measured_i)
    measured_lra = n(.measured_lra)
    measured_tp = n(.measured_tp)
    measured_threshold = n(.measured_threshold)
    target_offset = n(.target_offset)
    target_i = n(.target_i)
    target_tp = n(.target_tp)
  }
  var usable: Bool {
    [measured_i, measured_lra, measured_tp, measured_threshold].compactMap { $0 }.contains {
      $0.isFinite && $0 != 0
    }
      && [
        measured_i, measured_lra, measured_tp, measured_threshold, target_offset, target_i,
        target_tp,
      ].compactMap { $0 }.allSatisfy(\.isFinite)
  }
}
enum AudioFilterChoice {
  static let mainKey = "audio.normalization", fallbackKey = "audio.fallbackNormalization",
    gainKey = "audio.gainPercent"
  struct Node {
    let name: String
    var values: [String: Double]
    var text: String {
      if name == "volume" { return "volume=volume=" + String(values["volume"] ?? 1) }
      return name + "="
        + values.keys.sorted().map { k in
          let v = values[k]!
          return k + "=" + (v.rounded() == v ? String(Int(v)) : String(v))
        }.joined(separator: ":")
    }
  }
  static var wantsMeasurements: Bool {
    (nodes(UserDefaults.standard.string(forKey: mainKey) ?? "0") ?? []).contains(where: {
      $0.name == "loudnorm"
    })
  }
  static var requestsProcessing: Bool {
    let d = UserDefaults.standard
    return (d.object(forKey: gainKey) as? Double ?? 100) > 100
      || (d.string(forKey: mainKey) ?? "0") != "0"
  }
  private static func nodes(_ value: String) -> [Node]? {
    if value == "0" { return [] }
    let text =
      value == "1"
      ? "dynaudnorm=g=5:f=250:r=0.9:p=0.5" : value == "2" ? "loudnorm=I=-16:LRA=11:TP=-1.5" : value
    guard !text.isEmpty, text.utf8.count <= 384 else { return nil }
    let raw = text.split(separator: ",", omittingEmptySubsequences: false)
    guard raw.count <= 3 else { return nil }
    var result: [Node] = []
    for filter in raw {
      let f = filter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard f.count == 2 else { return nil }
      let name = f[0].lowercased()
      var props: [String: Double] = [:]
      let opts = f[1].split(separator: ":", omittingEmptySubsequences: false)
      guard !opts.isEmpty, opts.count <= 12 else { return nil }
      for opt in opts {
        let pair = opt.split(separator: "=", omittingEmptySubsequences: false)
        let rawKey: String
        let number: Substring
        if name == "volume", pair.count == 1 {
          rawKey = "volume"
          number = pair[0]
        } else {
          guard pair.count == 2 else { return nil }
          rawKey = pair[0].lowercased()
          number = pair[1]
        }
        guard number.utf8.count <= 20, !number.isEmpty,
          number.utf8.allSatisfy({ (48...57).contains($0) || [43, 45, 46, 69, 101].contains($0) }),
          let v = Double(number), v.isFinite
        else { return nil }
        var key = rawKey
        let limits: ClosedRange<Double>
        switch name {
        case "loudnorm":
          switch key {
          case "i":
            key = "I"
            limits = -70 ... -5
          case "tp":
            key = "TP"
            limits = -9...0
          case "lra":
            key = "LRA"
            limits = 1...50
          case "offset": limits = -99...99
          case "dual_mono", "linear":
            guard [0.0, 1.0].contains(v) else { return nil }
            limits = 0...1
          default: return nil
          }
        case "dynaudnorm":
          key =
            [
              "framelen": "f", "gausssize": "g", "peak": "p", "maxgain": "m", "targetrms": "r",
              "coupling": "n", "correctdc": "c", "altboundary": "b", "compress": "s",
              "threshold": "t",
            ].first(where: { $0.key == key })?.value ?? key
          switch key {
          case "f":
            guard v.rounded() == v else { return nil }
            limits = 10...1000
          case "g":
            guard v >= 3, v <= 31, v.rounded() == v, Int(v) % 2 == 1 else { return nil }
            limits = 3...31
          case "p", "r", "t": limits = 0...1
          case "m": limits = 1...100
          case "s": limits = 0...30
          case "n", "c", "b":
            guard [0.0, 1.0].contains(v) else { return nil }
            limits = 0...1
          default: return nil
          }
        case "volume":
          guard key == "volume" else { return nil }
          limits = 0...3
        default: return nil
        }
        guard limits.contains(v), props[key] == nil else { return nil }
        props[key] = v
      }
      if name == "dynaudnorm", (props["f"] ?? 500) * (props["g"] ?? 31) > 12000 { return nil }
      result.append(.init(name: name, values: props))
    }
    return result
  }
  static func valid(_ value: String) -> Bool { nodes(value) != nil }
  static func chain(main: String, fallback: String, gain: Double, volume: AudioMeasurements?)
    -> String
  {
    guard var effects = nodes(main) else { return "" }
    if let n = effects.firstIndex(where: { $0.name == "loudnorm" }) {
      if let v = volume, v.usable {
        let given = effects[n].values
        let mI = v.measured_i ?? 0
        let peak = v.measured_tp ?? 0
        func between(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
        effects[n].values = [
          "LRA": between(max(given["LRA"] ?? 11, v.measured_lra ?? 0), 1, 50),
          "I": between((given["I"] ?? v.target_i ?? -16) - max(0, mI), -70, -5),
          "TP": between(min(given["TP"] ?? v.target_tp ?? -1.5, peak), -9, 0),
          "offset": between(given["offset"] ?? v.target_offset ?? 0, -99, 99), "linear": 1,
          "measured_I": between(mI, -99, 0), "measured_LRA": between(v.measured_lra ?? 0, 0, 99),
          "measured_TP": between(peak, -99, 99),
          "measured_thresh": between(v.measured_threshold ?? 0, -99, 0),
        ]
        if let d = given["dual_mono"] { effects[n].values["dual_mono"] = d }
      } else {
        effects.replaceSubrange(n...n, with: nodes(fallback) ?? [])
      }
    }
    if gain.isFinite, gain > 100 {
      effects.append(.init(name: "volume", values: ["volume": min(300, gain) / 100]))
    }
    return effects.map(\.text).joined(separator: ",")
  }
  static var snapshot: [String] {
    let d = UserDefaults.standard
    return [
      d.string(forKey: mainKey) ?? "0", d.string(forKey: fallbackKey) ?? "0",
      String(d.object(forKey: gainKey) as? Double ?? 100),
    ]
  }
  static func current(_ volume: AudioMeasurements?) -> String {
    let d = UserDefaults.standard
    return chain(
      main: d.string(forKey: mainKey) ?? "0", fallback: d.string(forKey: fallbackKey) ?? "0",
      gain: d.object(forKey: gainKey) as? Double ?? 100, volume: volume)
  }
}
