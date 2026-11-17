import Foundation

@main enum UpscaleGraphCheck {
  static func main() throws {
    let graph = try JSONDecoder().decode(
      UpscaleGraph.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    var result: [String: Any] = [:]
    for preset in ["efficiency", "quality"] {
      for dims in [[8, 6], [12, 9], [16, 12], [24, 18], [32, 24], [16, 6]] {
        let w = dims[0]
        let h = dims[1]
        let plan = try graph.plan(
          preset, width: 8, height: 6, outputW: w, outputH: h, budget: 32 * 1024 * 1024)
        precondition(plan.shapes.dropFirst().reduce(0) { $0 + $1.bytes } < 32 * 1024 * 1024)
        precondition(!plan.passes.isEmpty && plan.shapes.count < plan.passes.count)
        for p in plan.passes { precondition(!p.inputs.contains(p.dst) && p.dst > 0) }
        let shape = plan.shapes[plan.final]
        if w == 16 && h == 6 { precondition(shape.w == 8 && shape.h == 6) }
        result["\(preset):\(w):\(h)"] = [
          "shapes": plan.shapes.map { [$0.w, $0.h, $0.channels] },
          "passes": plan.passes.map {
            ["kernel": $0.kernel, "inputs": $0.inputs, "dst": $0.dst] as [String: Any]
          },
          "final": plan.final,
        ]
      }
    }
    do {
      _ = try graph.plan(
        "quality", width: 1920, height: 1080, outputW: 3840, outputH: 2160, budget: 8)
      preconditionFailure("ignored texture budget")
    } catch UpscaleGraph.Failure.limit {}
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
  }
}
