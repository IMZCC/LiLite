import Foundation

/// Cache by bytes, so imports, resets and writes outside the settings UI invalidate it too.
/// Decode outside the lock: a background settings read must never make the UI wait for decoding.
final class DecodedSettingCache<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var entry: (Data, Value)?

  func value(for data: Data, decode: (Data) -> Value) -> Value {
    lock.lock()
    if let entry, entry.0 == data {
      lock.unlock()
      return entry.1
    }
    lock.unlock()
    let value = decode(data)
    lock.lock()
    entry = (data, value)
    lock.unlock()
    return value
  }
}
