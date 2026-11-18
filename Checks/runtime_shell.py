"""Execute production image request ownership and scroll observation with synthetic platform leaves."""
from pathlib import Path
import subprocess
import tempfile
import textwrap

native = Path(__file__).resolve().parents[1]
source = native / "Sources/PiliNative"

artwork = (source / "Library/RemoteArtwork.swift").read_text().split("struct RemoteArtwork", 1)[0]
artwork = artwork.replace("import ImageIO\n", "").replace("import SwiftUI\n", "import FoundationNetworking\n")
artwork = artwork.replace('static let key = "images.cacheBytes"', 'static let key = "Pili.Artwork.Runtime.Fixture"')
start = artwork.index("    let folder = FileManager")
end = artwork.index("    if limit == 0", start)
artwork = artwork[:start] + "    let value = URLCache(memoryCapacity: min(16 * Self.mib, limit), diskCapacity: limit, diskPath: nil)\n" + artwork[end:]
start = artwork.index("  private static func decode(")
artwork = artwork[:start] + '''  private static func decode(_ url: URL, session: URLSession, pixels: Int, maximum: Int) async throws -> Decoded {
    let result = try await ImageProbe.shared.render(url, pixels: pixels, maximum: maximum)
    return Decoded(image: result.image, cost: pixels * pixels * 4, cacheable: result.cacheable)
  }
}
'''

image_fixture = r'''
final class UIImage: NSObject, @unchecked Sendable { let serial: Int; init(_ n:Int){serial=n} }
struct APIProxy: Equatable { static func current()->Self{Self()};func apply(to:URLSessionConfiguration){} }
final class APIRedirectPolicy:NSObject,URLSessionTaskDelegate,@unchecked Sendable { init(publicArtwork:Bool){} }
actor ImageProbe {
  static let shared=ImageProbe()
  var calls:[String:Int]=[:], serial=0, delay:UInt64=30_000_000, cooperative=true, cacheable=true
  func configure(delay:UInt64=30_000_000,cooperative:Bool=true,cacheable:Bool=true){self.delay=delay;self.cooperative=cooperative;self.cacheable=cacheable}
  func count(_ url:URL)->Int{calls[url.absoluteString] ?? 0}
  func render(_ url:URL,pixels:Int,maximum:Int)async throws->(image:UIImage,cacheable:Bool){
    precondition(!Thread.isMainThread,"image decoding reached the main thread")
    calls[url.absoluteString,default:0]+=1;serial+=1
    let state=(serial,delay,cooperative,cacheable)
    if state.2 {try await Task.sleep(nanoseconds:state.1)} else {try? await Task.sleep(nanoseconds:state.1)}
    return(UIImage(state.0),state.3)
  }
}
@main enum ImageOwnershipCheck {
  static func wait(_ url:URL,count:Int)async throws{
    for _ in 0..<100 {if await ImageProbe.shared.count(url)>=count{return};try await Task.sleep(nanoseconds:2_000_000)}
    preconditionFailure("synthetic decoder did not start")
  }
  static func main()async throws {
    let store=ArtworkStore.shared,probe=ImageProbe.shared
    UserDefaults.standard.set(64*ArtworkStore.mib,forKey:ArtworkStore.key)
    defer{UserDefaults.standard.removeObject(forKey:ArtworkStore.key)}
    let cover=URL(string:"https://i0.hdslb.com/runtime-cover.jpg")!
    async let first=store.image(cover,pixels:192)
    async let second=store.image(cover,pixels:192)
    let pair=try await(first,second);precondition(pair.0 === pair.1)
    let firstCount=await probe.count(cover);precondition(firstCount==1)
    let reused=try await store.image(cover,pixels:192);precondition(reused === pair.0)
    let bigger=try await store.image(cover,pixels:768);precondition(bigger !== reused)
    let stricter=try await store.image(cover,pixels:192,maximum:1024*1024);precondition(stricter !== reused)
    let decodedUsage=await store.usage();precondition(decodedUsage.memory>=2*192*192*4+768*768*4)
    // One cell disappearing cannot cancel a shared request needed by another visible cell.
    let shared=URL(string:"https://i0.hdslb.com/runtime-shared.jpg")!
    await probe.configure(delay:90_000_000)
    let kept=Task{try await store.image(shared,pixels:384)}
    let cancelled=Task{try await store.image(shared,pixels:384)}
    try await wait(shared,count:1);try await Task.sleep(nanoseconds:5_000_000);cancelled.cancel()
    let visible=try await kept.value
    do{_ = try await cancelled.value;preconditionFailure("cancelled consumer received an image")}catch is CancellationError{}
    let later=try await store.image(shared,pixels:384),sharedCount=await probe.count(shared)
    precondition(later === visible && sharedCount==1)
    // Cancel all consumers, then replace the request before the old decoder cooperates.
    let replaced=URL(string:"https://i0.hdslb.com/runtime-replaced.jpg")!
    await probe.configure(delay:90_000_000,cooperative:false)
    let old=Task{try await store.image(replaced,pixels:384)}
    try await wait(replaced,count:1);old.cancel()
    try await Task.sleep(nanoseconds:5_000_000)
    await probe.configure(delay:15_000_000)
    let replacement=try await store.image(replaced,pixels:384)
    do{_ = try await old.value;preconditionFailure("obsolete decoder published after cancellation")}catch is CancellationError{}
    let afterOld=try await store.image(replaced,pixels:384),replacementCount=await probe.count(replaced)
    precondition(afterOld === replacement && replacementCount==2)
    // Cache clearing also fences a late noncooperative decoder without poisoning a replacement.
    let cleared=URL(string:"https://i0.hdslb.com/runtime-cleared.jpg")!
    await probe.configure(delay:90_000_000,cooperative:false)
    let beforeClear=Task{try await store.image(cleared,pixels:384)}
    try await wait(cleared,count:1);await store.clear();await probe.configure(delay:15_000_000)
    let afterClear=try await store.image(cleared,pixels:384)
    do{_ = try await beforeClear.value;preconditionFailure("clear accepted old work")}catch is CancellationError{}
    let clearHit=try await store.image(cleared,pixels:384);precondition(clearHit === afterClear)
    // Signed/private responses and the user's zero-cache preference do not acquire decoded storage.
    let signed=URL(string:"https://i0.hdslb.com/runtime-private.jpg?token=fixture")!
    let signedA=try await store.image(signed,pixels:192),signedB=try await store.image(signed,pixels:192)
    precondition(signedA !== signedB)
    let noStore=URL(string:"https://i0.hdslb.com/runtime-no-store.jpg")!
    await probe.configure(cacheable:false)
    let privateA=try await store.image(noStore,pixels:192),privateB=try await store.image(noStore,pixels:192)
    precondition(privateA !== privateB)
    await probe.configure();UserDefaults.standard.set(0,forKey:ArtworkStore.key)
    let noCacheA=try await store.image(cover,pixels:192),noCacheB=try await store.image(cover,pixels:192)
    precondition(noCacheA !== noCacheB)
    let emptyUsage=await store.usage();precondition(emptyUsage.memory==0)
    precondition(ArtworkCacheRules.pixels(width:28,height:28,scale:3)==96)
    precondition(ArtworkCacheRules.pixels(width:64,height:64,scale:3)==192)
    precondition(ArtworkCacheRules.pixels(width:190,height:107,scale:3)==768)
    precondition(ArtworkCacheRules.pixels(width:390,height:219,scale:3)==1536)
    precondition(ArtworkCacheRules.pixels(width:1000,height:1000,scale:3)==2048)
    await store.clear()
    print("Production artwork: shared decode/cache, pixel budgets, separate limits, partial/all cancellation, replacement, clear fencing, signed/no-store/zero-cache isolation passed")
  }
}
'''

shell = (source / "Settings/MainNavShell.swift").read_text()
start = shell.index("@MainActor @Observable private final class NavigationChrome")
end = shell.index("private struct TabRootMarker", start)
chrome = shell[start:end].replace("private final class NavigationChrome", "final class NavigationChrome")
pull_source = (source / "Library/NativePullRefresh.swift").read_text()
start = pull_source.index("  @MainActor @Observable final class PullState")
end = pull_source.index("\n}\nprivate struct PullIndicator", start)
pull = textwrap.dedent(pull_source[start:end])
attachment = (source / "Settings/NavScrollAttachment.swift").read_text()
start = attachment.index("    @objc private func moved(")
end = attachment.index("  func makeUIView", start)
pan_handler = attachment[start:end].replace("@objc private func moved", "func moved")

observation_fixture = r'''
import Foundation
import Observation
class UIView {var window:Bool?=true}
final class UIPanGestureRecognizer {
  enum Phase {case began, changed, ended, cancelled}
  var state = Phase.began, movement = CGPoint.zero, speed = CGPoint.zero
  func translation(in view:UIScrollView)->CGPoint {movement}
  func velocity(in view:UIScrollView)->CGPoint {speed}
}
struct StubInset {var top:CGFloat=0}
enum StubEvent {case valueChanged}
final class StubRefresh {var isRefreshing=false;func sendActions(for:StubEvent){}}
class UIScrollView:UIView {
  var contentOffset=CGPoint.zero,adjustedContentInset=StubInset(),refreshControl:StubRefresh?
  let panGestureRecognizer=UIPanGestureRecognizer()
  var isTracking=false,isDragging=false
  func setContentOffset(_ point:CGPoint,animated:Bool){contentOffset=point}
}
struct StubAnimation {static func smooth(duration: Double)->Self {Self()}}
func withAnimation(_ a:StubAnimation?,_ f:()->Void){f()}
enum NavScrollAttachment {static func visible(_ child:UIView,in root:UIView)->Bool{true};static func primaryScroll(in root:UIView)->UIScrollView?{nil}}
enum NativePullRefresh {static func repeatTab(on scroll:UIScrollView)->Bool{false}}
final class ChangeCount:@unchecked Sendable {
  let lock=NSLock();var count=0
  func changed(){lock.lock();count+=1;lock.unlock()}
}
@main enum ScrollObservationCheck {
  @MainActor static func main()async throws {
    let chrome=NavigationChrome(),root=ChangeCount(),strip=ChangeCount(),scroll=UIScrollView()
    chrome.show(.home,UUID());chrome.listen=true
    withObservationTracking{_ = chrome.visible[.home]}onChange:{root.changed()}
    withObservationTracking{_ = chrome.fraction}onChange:{strip.changed()}
    let marker=Marker(), pan=scroll.panGestureRecognizer
    marker.scroll=scroll
    marker.handle={chrome.drag(.home,delta:$0,top:$1,scroll:$2)}
    marker.release={chrome.release(.home,velocity:$0)}
    scroll.contentOffset.y=150
    pan.state = .began; marker.moved(pan)
    pan.state = .changed
    for i in 1...48 {pan.movement.y = -CGFloat(i);marker.moved(pan)}
    precondition(chrome.fraction > 0 && chrome.fraction < 1 && strip.count == 1 && root.count == 0)
    let halfway=chrome.fraction
    for _ in 1...24 {pan.movement.y += 1;marker.moved(pan)}
    precondition(chrome.fraction > halfway && chrome.fraction < 1)
    pan.state = .ended;pan.speed.y=500;marker.moved(pan)
    precondition(chrome.fraction == 1)
    let token=UUID();chrome.show(.mine,token);chrome.leave(.mine,token)
    // Pull progress likewise belongs to the indicator, while refresh remains a single operation.
    let pull=PullState(),working=ChangeCount(),progress=ChangeCount(),actions=ChangeCount()
    withObservationTracking{_ = pull.working}onChange:{working.changed()}
    withObservationTracking{_ = pull.progress}onChange:{progress.changed()}
    for i in 1...40{pull.drag(Double(i),height:20)}
    precondition(working.count==0 && progress.count==1)
    pull.start{actions.changed();try? await Task.sleep(nanoseconds:20_000_000)}
    pull.start{preconditionFailure("duplicate refresh started")}
    try await Task.sleep(nanoseconds:40_000_000)
    precondition(actions.count==1 && !pull.working && working.count==1)
    pull.drag(20,height:20);pull.stop();precondition(pull.progress==0 && !pull.working)
    print("Home search follows drag, reverses before lift and settles on release")
  }
}
'''

with tempfile.TemporaryDirectory(prefix="pili-runtime-shell-") as temporary:
    work = Path(temporary)
    for name, body, inputs in (
        ("Artwork", artwork + "\n" + image_fixture, [source / "Library/ArtworkCacheRules.swift"]),
        ("Observation", observation_fixture + "\n" + chrome + "\n" + pull
         + "\n@MainActor final class Marker { var previous:CGFloat=0; weak var scroll:UIScrollView?; var handle:((CGFloat,Bool,UIScrollView)->Void)?; var release:((CGFloat)->Void)?\n" + pan_handler,
         [source / "Network/ServiceError.swift", source / "Settings/DecodedSettingCache.swift", source / "Settings/NavigationRules.swift", source / "Settings/InteractionPolicy.swift"]),
    ):
        swift = work / (name + ".swift")
        swift.write_text(body)
        binary = work / name
        subprocess.run(["swiftc", "-parse-as-library", "-module-name", "RuntimeShell" + name, *map(str, inputs), str(swift), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
