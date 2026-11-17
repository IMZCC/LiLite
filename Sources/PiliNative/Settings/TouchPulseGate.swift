struct TouchPulseGate {
  private var fired = false
  mutating func claim(enabled: Bool) -> Bool {
    guard enabled && !fired else { return false }
    fired = true
    return true
  }
  mutating func nextTurn() { fired = false }
}
