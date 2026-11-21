import SwiftUI
import UIKit

/// Keep the media and its UI alive while UIKit is deciding whether an interactive pop commits.
@MainActor private final class VideoPageDeparture {
  weak var navigation: UINavigationController?
  weak var page: UIViewController?
  private var generation = 0
  /// Still the top page, with something presented over it (a picture viewer from the comments,
  /// a share sheet): the page has not been left, and the video keeps playing under the cover.
  private var covered: Bool {
    guard let page, let navigation, navigation.topViewController === page else { return false }
    return navigation.view.window?.rootViewController?.presentedViewController != nil
  }

  func appeared() { generation &+= 1 }

  func leave(_ action: @escaping () -> Void) {
    generation &+= 1
    let ticket = generation
    let finish = {
      DispatchQueue.main.async {
        guard self.generation == ticket, !self.covered else { return }
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
      // Back from anywhere on the page but the player, whose sideways drags seek.
      LeadingEdgeNavigation(fullWidth: true) {
        departure.navigation = $0
        departure.page = $0.topViewController
      }.frame(width: 0, height: 0)
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
