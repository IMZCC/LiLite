import Foundation
import PiliWire

/// Only value types cross back to the UI; decompression and JSON parsing stay off its actor.
enum LiveChatEvent: Sendable {
  case authenticated
  case popularity(UInt32)
  case update(LiveRoomUpdate)
  case line(LiveLine)
  case paid(SuperChatEvent)
  case ignored
}

enum LiveChatBatch {
  static func decode(_ data: Data, room: Int64) throws -> [LiveChatEvent] {
    try Task.checkCancellation()
    let frames = try LivePackets.decode(data)
    var events = [LiveChatEvent]()
    events.reserveCapacity(frames.count)
    for frame in frames {
      try Task.checkCancellation()
      switch frame {
      case .authenticated: events.append(.authenticated)
      case .popularity(let value): events.append(.popularity(value))
      case .event(let body):
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { continue }
        if let update = LiveRoomUpdate.read(object) {
          events.append(.update(update))
          continue
        }
        let command = (object["cmd"] as? String ?? "").split(separator: ":").first
        if command == "DANMU_MSG", let info = object["info"] as? [Any],
          let line = LiveMessageSource.socket(info, room: room) {
          events.append(.line(line))
        } else if let command, let event = SuperChatEvent.parse(body, command: String(command)) {
          events.append(.paid(event))
        } else {
          events.append(.ignored)
        }
      }
    }
    return events
  }
}
