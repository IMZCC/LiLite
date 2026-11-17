import Darwin
import UIKit

@MainActor enum SleepAppExit {
  static let checkpoint = Notification.Name("pili.sleep.explicitQuitCheckpoint")
  /// Only called by a due, explicitly armed exit timer, after the write fence seals.
  static func closeScenes(authorized: @escaping () -> Bool, orTerminate quit: @escaping () -> Void = { Darwin.exit(EXIT_SUCCESS) },
    sceneEnd: @escaping (String?) -> Void) {
    let app = UIApplication.shared, sessions = app.openSessions
    guard authorized() else { sceneEnd(nil); return }
    guard app.supportsMultipleScenes, !sessions.isEmpty else { quit(); return }
    // This API dismisses a window, not a process. Ask for every open session on a multiwindow device.
    var finished = false
    func complete(_ message: String?) {
      guard !finished else { return }
      finished = true
      if message != nil, UIDevice.current.userInterfaceIdiom == .phone, authorized() { quit() }
      else { sceneEnd(message) }
    }
    for session in sessions {
      app.requestSceneSessionDestruction(session, options: nil) { error in complete(error.localizedDescription) }
    }
    // On success UIKit has no completion handler. Release the fence for a future fresh window.
    Task { @MainActor in
      let deadline = ProcessInfo.processInfo.systemUptime + 8
      while !finished && !app.openSessions.isDisjoint(with: sessions) && ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(for: .milliseconds(300))
        if UIApplication.shared.applicationState == .active,
          app.connectedScenes.contains(where: { !sessions.contains($0.session) }) { break }
      }
      let closed = app.connectedScenes.allSatisfy { !sessions.contains($0.session) }
      complete(closed ? nil : "未能关闭全部窗口")
    }
  }
}
