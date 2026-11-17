import Foundation

/// mpv's MAIN hooks run in preset order, followed by PREKERNEL, immediately before the final scale.
struct UpscaleGraph: Decodable {
  struct Hook: Decodable {
    let kernel: String, hook: String, bind: [String], save: String, width: String, height: String,
      when: String, channels: Int
  }
  let presets: [String: [String]], programs: [String: [Hook]]
  struct Shape: Hashable {
    let w: Int, h: Int, channels: Int
    var bytes: Int { w * h * channels * 2 }
  }
  struct Pass { let kernel: String, inputs: [Int], dst: Int }
  struct Plan {
    let shapes: [Shape], passes: [Pass], final: Int
  }
  enum Failure: Error { case invalid, limit }
  func plan(_ preset: String, width: Int, height: Int, outputW: Int, outputH: Int, budget: Int)
    throws -> Plan
  {
    guard let files = presets[preset], !files.isEmpty,
      [width, height, outputW, outputH].allSatisfy({ (1...16384).contains($0) })
    else { throw Failure.invalid }
    var hooks: [Hook] = []
    for f in files {
      guard let list = programs[f] else { throw Failure.invalid }
      hooks += list
    }
    hooks = hooks.filter { $0.hook == "MAIN" } + hooks.filter { $0.hook == "PREKERNEL" }
    let input = Shape(w: width, h: height, channels: 4)
    let out = Shape(w: outputW, h: outputH, channels: 4)
    var values = [input]
    var ids = ["MAIN": 0, "NATIVE": 0]
    var ops: [Pass] = []
    func id(_ s: String) throws -> Int {
      guard let v = ids[s == "HOOKED" ? "MAIN" : s] else { throw Failure.invalid }
      return v
    }
    func eval(_ exp: String) throws -> Double {
      var stack: [Double] = []
      for raw in exp.split(separator: " ") {
        let tok = String(raw)
        if let x = Double(tok) {
          stack.append(x)
          continue
        }
        if tok.hasSuffix(".w") || tok.hasSuffix(".h") {
          let name = String(tok.dropLast(2))
          let shape = name == "OUTPUT" ? out : values[try id(name)]
          stack.append(Double(tok.hasSuffix(".w") ? shape.w : shape.h))
          continue
        }
        guard let b = stack.popLast(), let a = stack.popLast() else { throw Failure.invalid }
        switch tok {
        case "/":
          guard b != 0 else { throw Failure.invalid }
          stack.append(a / b)
        case "*": stack.append(a * b)
        case "<": stack.append(a < b ? 1 : 0)
        case ">": stack.append(a > b ? 1 : 0)
        default: throw Failure.invalid
        }
      }
      guard stack.count == 1, let v = stack.first, v.isFinite else { throw Failure.invalid }
      return v
    }
    for h in hooks {
      if !h.when.isEmpty, try eval(h.when) == 0 { continue }
      let w = try eval(h.width).rounded()
      let hh = try eval(h.height).rounded()
      guard w >= 1, hh >= 1, w <= 16384, hh <= 16384, [1, 4].contains(h.channels) else {
        throw Failure.limit
      }
      let inputs = try h.bind.map(id)
      let dst = values.count
      values.append(.init(w: Int(w), h: Int(hh), channels: h.channels))
      ops.append(.init(kernel: h.kernel, inputs: inputs, dst: dst))
      ids[h.save == "HOOKED" ? "MAIN" : h.save] = dst
    }
    let final = try id("MAIN")
    var last = Array(repeating: -1, count: values.count)
    for (i, o) in ops.enumerated() { for v in o.inputs { last[v] = i } }
    last[final] = ops.count
    // Never alias a read and write in the same pass. Reuse a private half-float texture only
    // after its final consumer; this also preserves the long skips in the VL restore network.
    var slots = [input]
    var use = [Int.max]
    var slotsFor = [0: 0]
    var scheduled: [Pass] = []
    var bytes = 0
    for (i, o) in ops.enumerated() {
      let shape = values[o.dst]
      let existing = slots.indices.first { $0 > 0 && use[$0] < i && slots[$0] == shape }
      let slot: Int
      if let existing {
        slot = existing
      } else {
        guard shape.bytes <= budget - bytes else { throw Failure.limit }
        slot = slots.count
        slots.append(shape)
        use.append(0)
        bytes += shape.bytes
      }
      use[slot] = max(i, last[o.dst])
      slotsFor[o.dst] = slot
      let sources = try o.inputs.map { value -> Int in
        guard let q = slotsFor[value] else { throw Failure.invalid }
        return q
      }
      guard !sources.contains(slot) else { throw Failure.invalid }
      scheduled.append(.init(kernel: o.kernel, inputs: sources, dst: slot))
    }
    guard let result = slotsFor[final] else { throw Failure.invalid }
    return .init(shapes: slots, passes: scheduled, final: result)
  }
}
