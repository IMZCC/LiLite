import AVFoundation
import SwiftUI
import Combine

@MainActor final class PictureSession: ObservableObject {
  @Published var mirrorX = false
  @Published var mirrorY = false
  @Published var changedItem: ObjectIdentifier?
  @Published private(set) var inPictureInPicture = false
  // Separate from objectWillChange: only the timeline readout needs an optimistic seek,
  // not the video surface, its comments, or other picture controls.
  private var seeking: (item: ObjectIdentifier, id: UUID, target: Double)?
  let seekChanged = PassthroughSubject<Void, Never>()
  func beginSeek(_ item: AnyObject, to target: Double) -> UUID {
    let id = UUID()
    seeking = (ObjectIdentifier(item), id, target)
    seekChanged.send()
    return id
  }
  func finishSeek(_ id: UUID, for item: AnyObject) {
    guard seeking?.id == id, seeking?.item == ObjectIdentifier(item) else { return }
    seeking = nil
    seekChanged.send()
  }
  func cancelSeek(for item: AnyObject?) {
    guard let item, seeking?.item == ObjectIdentifier(item) else { return }
    seeking = nil
    seekChanged.send()
  }
  func target(for item: AnyObject?) -> Double? {
    guard let item, seeking?.item == ObjectIdentifier(item) else { return nil }
    return seeking?.target
  }
  func seek(_ player: any PlaybackEngine, to target: Double) {
    guard let item = player.playbackItem, target.isFinite else { return }
    let id = beginSeek(item, to: target)
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self, weak item] _ in
      Task { @MainActor in if let item { self?.finishSeek(id, for: item) } }
    }
  }
  func setPictureInPicture(_ active: Bool) {
    if inPictureInPicture != active { inPictureInPicture = active }
  }
  private static var key: UInt8 = 0
  static func shared(_ player: any PlaybackEngine) -> PictureSession {
    if let state = objc_getAssociatedObject(player, &key) as? PictureSession { return state }
    let state = PictureSession()
    objc_setAssociatedObject(player, &key, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return state
  }
}
struct PictureFitMenu: View {
  let player: any PlaybackEngine
  @ObservedObject var session: PictureSession
  @AppStorage("play.gravity") var stored = PictureFit.fit.rawValue
  var body: some View {
    Menu {
      Picker("画面比例", selection: Binding(get: { stored }, set: { value in
        session.changedItem = player.playbackItem.map(ObjectIdentifier.init)
        stored = value
      })) {
        ForEach(PictureFit.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
      }
      Toggle("水平镜像", isOn: $session.mirrorX.withTouchFeedback)
      Toggle("垂直镜像", isOn: $session.mirrorY.withTouchFeedback)
    } label: {
      Image(systemName: "aspectratio").padding(7).foregroundStyle(.white)
        .background(.black.opacity(0.6), in: Circle())
    }.accessibilityLabel("画面比例与镜像")
  }
}
