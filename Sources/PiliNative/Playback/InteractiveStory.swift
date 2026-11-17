import Foundation
#if canImport(Combine)
import Combine
#endif

struct VideoPositions: Decodable {
  struct Chapter: Decodable, Identifiable {
    let from: Int, to: Int?, content: String?
    var type:Int?=nil,imgUrl:String?=nil
    func end(next:Int?,duration:Double)->Double?{
      if let to,to>from{return Double(to)}
      if let next,next>from{return Double(next)}
      return duration.isFinite && duration>Double(from) ? duration:nil
    }
    var id: String { "\(from):\(content ?? "")" }
  }
  struct Interaction: Decodable { let graph_version: Int64? }
  let view_points: [Chapter]?, interaction: Interaction?
  var chapters:[Chapter]{
    guard let list=view_points,(list.first?.type ?? 2)==2 else{return []}
    return Array(list.prefix(4096)).filter{$0.from>=0 && ($0.type ?? 2)==2}.sorted{$0.from<$1.from}
  }
  private struct Entry:Decodable{let value:Chapter?;init(from d:Decoder)throws{value=try? Chapter(from:d)}}
  enum CodingKeys:String,CodingKey{case view_points,interaction}
  init(from d:Decoder)throws{
    let fields=try d.container(keyedBy:CodingKeys.self)
    view_points=try fields.decodeIfPresent([Entry].self,forKey:.view_points)?.compactMap(\.value)
    interaction=try fields.decodeIfPresent(Interaction.self,forKey:.interaction)
  }
}

struct StoryNode: Decodable {
  struct Edges: Decodable { let questions: [Question]? }
  struct Question: Decodable {
    let title: String?, choices: [Choice]?
    private struct Row: Decodable { let value: Choice?; init(from d: Decoder) { value = try? Choice(from: d) } }
    enum CodingKeys: String, CodingKey { case title, choices }
    init(from d: Decoder) throws {
      let c = try d.container(keyedBy: CodingKeys.self)
      title = try c.decodeIfPresent(String.self, forKey: .title)
      choices = try c.decodeIfPresent([Row].self, forKey: .choices)?.compactMap(\.value)
    }
  }
  struct Choice: Decodable, Identifiable { let id: Int64, cid: Int64?, option: String? }
  let title: String?, edges: Edges?
  var question: Question? { edges?.questions?.first }
  var options: [Choice] {
    var seen = Set<Int64>()
    return (question?.choices ?? []).filter { $0.id > 0 && ($0.cid ?? 0) > 0 && seen.insert($0.id).inserted }
  }
}

struct StoryReader {
  let positions: @MainActor (String, Int64, String) async throws -> VideoPositions
  let edge: @MainActor (String, Int64, Int64?, String) async throws -> StoryNode
}
@MainActor protocol StoryOutput: AnyObject {
  func beginStory(_ cid: Int64, wait: Task<Void,Never>?)
  func story(_ cid: Int64, choices: [StoryNode.Choice], action: @escaping (StoryNode.Choice) -> Void)
  func storyFailed(_ cid: Int64, message: String, retry: @escaping () -> Void)
  func storyChapters(_ chapters: [VideoPositions.Chapter], bvid: String, cid: Int64)
}
@MainActor final class InteractiveStory: ObservableObject {
  struct Subject: Equatable { let bvid: String, cid: Int64, owner: String }
  private var subject: Subject?, rootCID: Int64?, token = UUID()
  private var selection: (Subject, Int64)?
  @Published private(set) var positions: VideoPositions?
  @Published private(set) var node: StoryNode?
  @Published private(set) var error: String?
  @Published private(set) var revision = 0
  var canRestart: Bool { selection != nil && rootCID != nil }
  func retry() { revision &+= 1 }
  func clear() {
    token = UUID(); subject = nil; rootCID = nil; selection = nil
    positions = nil; node = nil; error = nil
  }
  func restart(_ navigate: (Int64) -> Void) {
    guard canRestart, let cid = rootCID else { return }
    selection = nil; node = nil; revision &+= 1; navigate(cid)
  }
  func choose(_ option: StoryNode.Choice, navigate: (Int64) -> Void) {
    guard let key = subject, node?.options.contains(where: { $0.id == option.id && $0.cid == option.cid }) == true,
      let cid = option.cid else { return }
    selection = (Subject(bvid: key.bvid, cid: cid, owner: key.owner), option.id)
    node = nil; revision &+= 1; navigate(cid)
  }
  func open(_ key: Subject, root: Int64?, interactive: Bool, reader: StoryReader, model: any StoryOutput,
    navigate: @escaping (Int64) -> Void) async {
    let stamp = UUID(); token = stamp
    if selection?.0 != key { selection = nil }
    let edge = selection?.1
    subject = key; rootCID = root; node = nil; positions = nil; error = nil
    let request = Task { @MainActor [weak self, weak model] in
      guard let self, let model else { return }
      do {
        let p = try await reader.positions(key.bvid, key.cid, key.owner)
        try Task.checkCancellation()
        guard token == stamp else { return }
        positions = p
        model.storyChapters(p.chapters, bvid: key.bvid, cid: key.cid)
        guard let version = p.interaction?.graph_version, version > 0 else {
          if interactive { throw ServiceError("未能读取互动剧情") }
          return
        }
        let result = try await reader.edge(key.bvid, version, edge, key.owner)
        try Task.checkCancellation()
        guard token == stamp else { return }
        node = result
        model.story(key.cid, choices: result.options) { [weak self] choice in
          self?.choose(choice, navigate: navigate)
        }
      } catch {
        if token == stamp, !Task.isCancelled, interactive || edge != nil {
          self.error = error.localizedDescription
          model.storyFailed(key.cid, message: error.localizedDescription, retry: { [weak self] in self?.retry() })
        }
      }
    }
    model.beginStory(key.cid, wait: interactive || edge != nil ? request : nil)
    await withTaskCancellationHandler(operation: { await request.value }, onCancel: { request.cancel() })
  }
}
