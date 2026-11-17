import MetalKit

/// Compiled once per app, off the main thread. Intermediate features must remain signed.
final class UpscaleMetal: @unchecked Sendable {
  let device: MTLDevice, library: MTLLibrary, present: MTLRenderPipelineState, graph: UpscaleGraph
  let states: [String: MTLComputePipelineState]
  enum Problem: Error { case unavailable }
  private static let task = Task.detached(priority: .userInitiated) { try UpscaleMetal() }
  static func shared() async throws -> UpscaleMetal { try await task.value }
  private init() throws {
    guard let gpu = MTLCreateSystemDefaultDevice(),
      let shaders = Bundle.module.url(
        forResource: "Anime4K", withExtension: "msl", subdirectory: "UpscaleAssets"),
      let weights = Bundle.module.url(
        forResource: "Graph", withExtension: "json", subdirectory: "UpscaleAssets")
    else { throw Problem.unavailable }
    device = gpu
    graph = try JSONDecoder().decode(UpscaleGraph.self, from: Data(contentsOf: weights))
    let opt = MTLCompileOptions()
    if #available(iOS 18.0, *) { opt.mathMode = .safe } else { opt.fastMathEnabled = false }
    let lib = try gpu.makeLibrary(
      source: String(contentsOf: shaders, encoding: .utf8), options: opt)
    library = lib
    var pipelines: [String: MTLComputePipelineState] = [:]
    for stages in graph.programs.values {
      for stage in stages {
        guard let fn = lib.makeFunction(name: stage.kernel) else { throw Problem.unavailable }
        pipelines[stage.kernel] = try gpu.makeComputePipelineState(function: fn)
      }
    }
    states = pipelines
    let target = MTLRenderPipelineDescriptor()
    target.vertexFunction = lib.makeFunction(name: "animeVertex")
    target.fragmentFunction = lib.makeFunction(name: "animePresent")
    target.colorAttachments[0].pixelFormat = .bgra8Unorm
    present = try gpu.makeRenderPipelineState(descriptor: target)
  }
}

final class UpscaleTargets {
  let plan: UpscaleGraph.Plan, slots: [MTLTexture]
  init(_ gpu: UpscaleMetal, mode: UpscaleMode, w: Int, h: Int, outputW: Int, outputH: Int) throws {
    // Bound app-owned storage; leave room for decoded images, UIKit and the system compositor.
    let memory = min(384 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 16))
    plan = try gpu.graph.plan(
      mode.preset, width: w, height: h, outputW: outputW, outputH: outputH, budget: memory)
    var textures: [MTLTexture] = []
    for shape in plan.shapes.dropFirst() {
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: shape.channels == 1 ? .r16Float : .rgba16Float, width: shape.w,
        height: shape.h, mipmapped: false)
      desc.storageMode = .private
      desc.usage = [.shaderRead, .shaderWrite]
      guard let texture = gpu.device.makeTexture(descriptor: desc) else {
        throw UpscaleGraph.Failure.limit
      }
      textures.append(texture)
    }
    slots = textures
  }
  func encode(
    _ command: MTLCommandBuffer, gpu: UpscaleMetal, source: MTLTexture,
    pass: MTLRenderPassDescriptor, extent: SIMD2<Float>, uv: [SIMD2<Float>]
  ) throws {
    func t(_ id: Int) -> MTLTexture { id == 0 ? source : slots[id - 1] }
    for step in plan.passes {
      guard let pipeline = gpu.states[step.kernel],
        let encoder = command.makeComputeCommandEncoder()
      else { throw UpscaleMetal.Problem.unavailable }
      encoder.setComputePipelineState(pipeline)
      for (i, s) in step.inputs.enumerated() { encoder.setTexture(t(s), index: i) }
      let out = t(step.dst)
      encoder.setTexture(out, index: step.inputs.count)
      let x = min(16, pipeline.threadExecutionWidth)
      let y = min(8, pipeline.maxTotalThreadsPerThreadgroup / max(1, x))
      encoder.dispatchThreadgroups(
        .init(width: (out.width + x - 1) / x, height: (out.height + y - 1) / y, depth: 1),
        threadsPerThreadgroup: .init(width: x, height: y, depth: 1))
      encoder.endEncoding()
    }
    guard let renderer = command.makeRenderCommandEncoder(descriptor: pass) else {
      throw UpscaleMetal.Problem.unavailable
    }
    var e = extent
    renderer.setRenderPipelineState(gpu.present)
    renderer.setVertexBytes(&e, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    uv.withUnsafeBufferPointer { points in
      renderer.setVertexBytes(
        points.baseAddress!, length: points.count * MemoryLayout<SIMD2<Float>>.stride, index: 1)
    }
    renderer.setFragmentTexture(t(plan.final), index: 0)
    renderer.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    renderer.endEncoding()
  }
}
