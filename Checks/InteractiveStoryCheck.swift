import Foundation
#if !canImport(Combine)
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
#endif

@MainActor final class StorySink: StoryOutput {
  var pending: Task<Void,Never>?, options: [StoryNode.Choice] = [], error: String?
  var chapters: [Int] = []
  var beginCount = 0
  func beginStory(_ cid: Int64, wait: Task<Void,Never>?) { beginCount += 1; pending = wait; options = []; error = nil }
  func story(_ cid: Int64, choices: [StoryNode.Choice], action: @escaping (StoryNode.Choice) -> Void) { options = choices }
  func storyFailed(_ cid: Int64, message: String, retry: @escaping () -> Void) { error = message }
  func storyChapters(_ values: [VideoPositions.Chapter], bvid: String, cid: Int64) { chapters = values.map(\.from) }
}

@main enum InteractiveStoryCheck {
  @MainActor static func main() async throws {
    func decoded<T:Decodable>(_ type:T.Type,_ json:String)throws->T{try JSONDecoder().decode(type,from:Data(json.utf8))}
    let root = try decoded(StoryNode.self,#"{"edges":{"questions":[{"choices":[{"id":8,"cid":456,"option":"A"},{"id":8,"cid":700},{"id":9,"cid":0},{"id":null}]},{"choices":[{"id":10,"cid":401}]}]}}"#)
    let end = try decoded(StoryNode.self,#"{"title":"终点","edges":{"questions":[]}}"#)
    let pos = try decoded(VideoPositions.self,#"{"view_points":[{"from":3}],"interaction":{"graph_version":16}}"#)
    let session = InteractiveStory(), output = StorySink()
    typealias S = InteractiveStory.Subject
    let entry = S(bvid:"BVx",cid:123,owner:"A"), branch = S(bvid:"BVx",cid:456,owner:"A")
    var requests:[(Int64?,String)] = [], navigated:[Int64] = []
    let source = StoryReader(positions:{_,_,_ in pos},edge:{_,version,key,owner in
      precondition(version == 16); requests.append((key,owner)); return key == nil ? root : end
    })
    func open(_ s:S) async {
      await session.open(s,root:123,interactive:true,reader:source,model:output){navigated.append($0)}
    }
    await open(entry)
    precondition(output.pending != nil && output.options.map(\.id) == [8] && output.chapters == [3])
    session.choose(.init(id:8,cid:999,option:nil)){navigated.append($0)}
    precondition(navigated.isEmpty)
    session.choose(output.options[0]){navigated.append($0)}
    await open(branch)
    precondition(requests.last?.0 == 8 && session.canRestart && output.options.isEmpty)
    session.restart { navigated.append($0) }; await open(entry)
    precondition(navigated == [456,123] && requests.last?.0 == nil)
    session.choose(output.options[0]){_ in}
    await open(S(bvid:"BVx",cid:456,owner:"B"))
    precondition(requests.last?.0 == nil && requests.last?.1=="B" && !session.canRestart)
    var release:CheckedContinuation<Void,Never>?
    let slow = StoryReader(positions:{_,_,_ in pos},edge:{_,_,_,_ in await withCheckedContinuation { release=$0 }; return end})
    let old = Task { await session.open(branch,root:123,interactive:true,reader:slow,model:output){_ in} }
    while release == nil { await Task.yield() }
    await open(entry)
    release?.resume(); await old.value
    precondition(output.options.map(\.id) == [8])
    let denied = StoryReader(positions:{_,_,_ in pos},edge:{_,_,_,_ in throw ServiceError("无权访问")})
    await session.open(entry,root:123,interactive:true,reader:denied,model:output){_ in}
    precondition(output.options.isEmpty && output.error == "无权访问")
    print("Interactive graph: first question, actual CID/edge, terminal branch, restart, identity change and stale responses passed")
  }
}
