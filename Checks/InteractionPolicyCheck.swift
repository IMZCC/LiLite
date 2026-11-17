import Foundation

@main enum InteractionPolicyCheck {
  static func main() {
    for eager in [false, true] {
      for auto in [false, true] {
        for manual in [false, true] {
          for queue in [false, true] {
            let mode = PlaybackEntryPolicy.mode(
              preinitialize: eager, autoplay: auto, manual: manual, continuation: queue)
            precondition(
              mode == (auto || manual || queue ? .play : eager ? .preparePaused : .cover))
          }
        }
      }
    }
    let old = PlaybackEntryID(source: "BV1example", cid: 34, owner: "81")
    precondition(
      old != .init(source: old.source, cid: 34, owner: "72")
        && old != .init(source: old.source, cid: 35, owner: "81"))
    var memory = SceneResumeMemory<String>()
    memory.capture(item: "A", rate: 1.5, wanted: true)
    precondition(memory.restore(current: "A", eligible: true, paused: true) == nil)  // notification shade alone
    precondition(memory.enter(current: "A", eligible: true))
    precondition(memory.restore(current: "A", eligible: true, paused: true) == 1.5)
    precondition(memory.restore(current: "A", eligible: true, paused: false) == nil)  // already running in PiP
    precondition(memory.restore(current: "B", eligible: true, paused: true) == nil)  // queue changed
    precondition(memory.restore(current: "A", eligible: false, paused: true) == nil)  // background listening or competing player
    memory.capture(item: "A", rate: 1, wanted: false)
    precondition(!memory.enter(current: "A", eligible: true))
    memory.capture(item: "A", rate: 1, wanted: true)
    precondition(
      !memory.enter(current: "A", eligible: false)
        && memory.restore(current: "A", eligible: true, paused: true) == nil)
    memory.capture(item: "A", rate: 1, wanted: true)
    _ = memory.enter(current: "A", eligible: true)
    memory = .init()
    precondition(memory.restore(current: "A", eligible: true, paused: true) == nil)  // remote pause/interruption/sleep timer
    precondition(InterfaceInteraction.horizontalDrag(x: 25, y: 8, threshold: 24))
    precondition(!InterfaceInteraction.horizontalDrag(x: 25, y: 9, threshold: 24))
    precondition(!InterfaceInteraction.horizontalDrag(x: 23, y: 0, threshold: 24))
    precondition(InterfaceInteraction.horizontalDrag(x: -68, y: 1, threshold: 60))
    precondition(!InterfaceInteraction.horizontalDrag(x: 60, y: 1, threshold: 60))
    precondition(
      InterfaceInteraction.refreshThreshold(20) == 69
        && InterfaceInteraction.refreshThreshold(100) == 149)
    precondition(
      InterfaceInteraction.refreshThreshold(-100) == 59
        && InterfaceInteraction.refreshThreshold(.nan) == 69)
    precondition(
      InterfaceInteraction.interfaceScale(0.5) == 0.5 && InterfaceInteraction.interfaceScale(9) == 2
        && InterfaceInteraction.interfaceScale(.infinity) == 1)
    print(
      "PASS: 16 playback entry combinations, paused/active/PiP/audio/item/intent restore, horizontal angle and slop, refresh distance and scale bounds"
    )
  }
}
