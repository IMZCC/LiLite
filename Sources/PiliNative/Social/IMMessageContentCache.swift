import Foundation

/// Each message owns its parsed content, so dropping a conversation also releases this cache.
/// DirectMessage.content is immutable; copies can safely share its decoded payload.
final class IMMessageContentCache: @unchecked Sendable {
  private let lock = NSLock()
  private var decoded: [String: Any]?
  private var rendered: (type: Int?, status: Int?, card: IMCardBody)?

  func payload(_ content: String?) -> [String: Any] {
    lock.lock()
    if let decoded { lock.unlock(); return decoded }
    lock.unlock()
    let value = content.flatMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
    } ?? [:]
    lock.lock()
    decoded = value
    lock.unlock()
    return value
  }

  func card(for message: DirectMessage) -> IMCardBody {
    lock.lock()
    if let rendered, rendered.type == message.msg_type, rendered.status == message.msg_status {
      lock.unlock()
      return rendered.card
    }
    lock.unlock()
    let value = IMCardBody(type: message.msg_type, data: payload(message.content),
      fallback: (message.content?.isEmpty == false ? message.content : nil) ?? message.text)
    lock.lock()
    rendered = (message.msg_type, message.msg_status, value)
    lock.unlock()
    return value
  }
}
