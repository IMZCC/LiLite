import SwiftUI
import UIKit

/// Keep the media and its UI alive while UIKit is deciding whether an interactive pop commits.
@MainActor private final class VideoPageDeparture {
  weak var navigation: UINavigationController?
  private var generation = 0

  func appeared() { generation &+= 1 }

  func leave(_ action: @escaping () -> Void) {
    generation &+= 1
    let ticket = generation
    let finish = {
      DispatchQueue.main.async {
        guard self.generation == ticket else { return }
        action()
      }
    }
    if let transition = navigation?.transitionCoordinator {
      if transition.animate(alongsideTransition: nil, completion: { context in
        if !context.isCancelled { finish() }
      }) { return }
      if transition.isCancelled { return }
    }
    finish()
  }
}

private struct VideoPageNavigation: ViewModifier {
  let stopOnDisappear: Bool
  let leave: () -> Void
  @State private var departure = VideoPageDeparture()
  func body(content: Content) -> some View {
    content.background {
      LeadingEdgeNavigation { departure.navigation = $0 }.frame(width: 0, height: 0)
    }
      .onAppear { departure.appeared() }
      .onDisappear { if stopOnDisappear { departure.leave(leave) } }
  }
}

extension View {
  func videoPageNavigation(stopOnDisappear: Bool, leave: @escaping () -> Void) -> some View {
    modifier(VideoPageNavigation(stopOnDisappear: stopOnDisappear, leave: leave))
  }
}
