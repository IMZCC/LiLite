import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

// Use the owning window's bounds, including when an iPad app changes its window size.
private struct PlayerWindowLayout: UIViewRepresentable {
  var report: (Bool) -> Void
  final class Marker: UIView {
    var report: ((Bool) -> Void)?
    private var last: Bool?
    override func layoutSubviews() {
      super.layoutSubviews()
      measure()
    }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      measure()
    }
    func measure() {
      guard let size = window?.bounds.size, size.width > 0, size.height > 0 else { return }
      let value = size.width > size.height
      if last != value {
        last = value
        DispatchQueue.main.async { [weak self] in self?.report?(value) }
      }
    }
  }
  func makeUIView(context: Context) -> Marker {
    let v = Marker()
    v.isUserInteractionEnabled = false
    v.report = report
    return v
  }
  func updateUIView(_ view: Marker, context: Context) {
    view.report = report
    view.measure()
  }
}

struct PlayerHeaderStatus: View {
  let fullscreen: Bool
  @AppStorage("layout.horizontal") private var horizontal =
    UIDevice.current.userInterfaceIdiom == .pad
  @AppStorage("theater.battery") private var battery = true
  @State private var landscape = false
  var body: some View {
    HStack(spacing: 8) {
      if landscape && (fullscreen || !horizontal) {
        TimelineView(
          .periodic(
            from: Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 / 60) * 60),
            by: 60)
        ) { tick in
          let clock = Calendar.current.dateComponents([.hour, .minute], from: tick.date)
          Text(String(format: "%02d:%02d", clock.hour ?? 0, clock.minute ?? 0))
            .monospacedDigit().font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        if battery { PlayerBattery() }
      }
    }
    .padding(.horizontal, 6)
    .background(PlayerWindowLayout { landscape = $0 })
  }
}

private struct RouteVolumeSlider: UIViewRepresentable {
  func makeUIView(context: Context) -> MPVolumeView {
    let v = MPVolumeView()
    v.showsRouteButton = false
    v.showsVolumeSlider = true
    return v
  }
  func updateUIView(_ v: MPVolumeView, context: Context) {}
}
struct PlayerRouteVolume: View {
  @State private var open = false
  var body: some View {
    Button {
      open = true
    } label: {
      Image(systemName: "speaker.wave.2").font(.caption.bold()).foregroundStyle(.white).padding(7)
        .background(.black.opacity(0.65), in: Circle())
    }
    .accessibilityLabel("系统音量")
    .popover(isPresented: $open) {
      VStack(alignment: .leading, spacing: 10) {
        Text("系统音量").font(.headline)
        RouteVolumeSlider().frame(width: 205, height: 32)
      }
      .padding().presentationCompactAdaptation(.popover)
    }
  }
}
