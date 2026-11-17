import SwiftUI
import UIKit

struct VideoPageAppearance: ViewModifier {
  @AppStorage("detail.dark") private var dark = false
  @Environment(\.colorScheme) private var inherited
  func body(content: Content) -> some View {
    content.background { if dark { Color.black.ignoresSafeArea() } }
      .environment(\.colorScheme, dark ? .dark : inherited)
      .toolbarColorScheme(dark ? .dark : nil, for: .navigationBar)
  }
}
@MainActor private enum BatteryLease {
  static var holders = Set<UUID>(), wasEnabled = false
  static func begin(_ id: UUID) {
    if holders.isEmpty { wasEnabled = UIDevice.current.isBatteryMonitoringEnabled }
    holders.insert(id)
    UIDevice.current.isBatteryMonitoringEnabled = true
  }
  static func end(_ id: UUID) {
    guard holders.remove(id) != nil, holders.isEmpty else { return }
    UIDevice.current.isBatteryMonitoringEnabled = wasEnabled
  }
}
struct PlayerBattery: View {
  @State private var token = UUID()
  @State private var level: Int?
  @State private var charging = false
  var body: some View {
    ZStack {
      if let level {
        Label(
          String(level) + "%",
          systemImage: charging
            ? "battery.100percent.bolt"
            : level < 15
              ? "battery.0percent"
              : level < 38
                ? "battery.25percent"
                : level < 63
                  ? "battery.50percent" : level < 88 ? "battery.75percent" : "battery.100percent"
        ).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1).accessibilityLabel(
          "电量 " + String(level) + "%")
      } else {
        Color.clear.frame(width: 0, height: 0)
      }
    }
    .onAppear {
      BatteryLease.begin(token)
      read()
    }.onDisappear { BatteryLease.end(token) }
    .onReceive(
      NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
    ) { _ in read() }
    .onReceive(
      NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)
    ) { _ in read() }
  }
  private func read() {
    let device = UIDevice.current
    let raw = device.batteryLevel
    level = raw >= 0 && raw <= 1 ? Int((raw * 100).rounded()) : nil
    charging = device.batteryState == .charging || device.batteryState == .full
  }
}
