import SwiftUI

/// Keep neighboring pages available while the user's pan is in progress without relying on
/// UIPageViewController's non-configurable recognition distance.
struct ThresholdPager<Page: View>: View {
  let count: Int
  @Binding var page: Int
  var indicators = false
  var allows: (CGFloat) -> Bool = { _ in true }
  @ViewBuilder let content: (Int) -> Page
  @AppStorage(InterfaceInteraction.horizontal) private var threshold = 24.0
  @Environment(\.accessibilityReduceMotion) private var reduced
  @State private var accepted: Bool?
  @State private var offset: CGFloat = 0
  @GestureState private var touched = false
  private func move(_ delta: Int) {
    let target = min(max(0, page + delta), max(0, count - 1))
    withAnimation(reduced ? nil : .easeOut(duration: 0.2)) {
      page = target
      offset = 0
    }
    accepted = nil
  }
  var body: some View {
    GeometryReader { g in
      let w = g.size.width
      ZStack {
        if count > 0 {
          ForEach(max(0, page - 1)..<max(max(0, page - 1), min(count, page + 2)), id: \.self) { i in
            content(i).frame(width: w, height: g.size.height)
              .offset(x: CGFloat(i - page) * w + offset)
              .allowsHitTesting(i == page).accessibilityHidden(i != page)
          }
        }
      }.frame(width: w, height: g.size.height).clipped().contentShape(Rectangle())
        .simultaneousGesture(
          DragGesture(minimumDistance: max(1, min(12, threshold)), coordinateSpace: .local)
            .updating($touched) { _, state, _ in state = true }
            .onChanged { v in
              let x = v.translation.width
              let y = v.translation.height
              guard count > 1 else { return }
              if accepted == nil {
                if abs(y) > max(6, threshold) && abs(y) >= abs(x) {
                  accepted = false
                } else if InterfaceInteraction.horizontalDrag(x: x, y: y, threshold: threshold) {
                  accepted = allows(x)
                }
              }
              if accepted == true {
                let edge = (x > 0 && page == 0) || (x < 0 && page == count - 1)
                offset = edge ? x * 0.14 : x
              }
            }.onEnded { v in
              let x = v.translation.width
              let enough =
                abs(x) >= min(120, w * 0.27)
                || (x * v.predictedEndTranslation.width > 0
                  && abs(v.predictedEndTranslation.width) >= w * 0.37)
              if accepted == true && enough && allows(x) { move(x < 0 ? 1 : -1) } else { move(0) }
            }
        )
        .onChange(of: touched) { _, down in
          if !down {
            Task { @MainActor in
              await Task.yield()
              if !touched && accepted != nil { move(0) }
            }
          }
        }
        .overlay(alignment: .bottom) {
          if indicators && count > 1 {
            HStack {
              Button {
                move(-1)
              } label: {
                Image(systemName: "chevron.left")
              }.disabled(page == 0).accessibilityLabel("上一张")
              Text("\(page + 1)/\(count)").monospacedDigit()
              Button {
                move(1)
              } label: {
                Image(systemName: "chevron.right")
              }.disabled(page + 1 >= count).accessibilityLabel("下一张")
            }.font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4)
              .background(.regularMaterial, in: Capsule()).padding(6)
          }
        }.accessibilityAction(named: "上一页") { move(-1) }.accessibilityAction(named: "下一页") {
          move(1)
        }
    }.onChange(of: count, initial: true) { _, n in
      let valid = max(0, min(page, n - 1))
      if page != valid {
        page = valid
        offset = 0
        accepted = nil
      }
    }
  }
}
@MainActor final class GalleryPagingEdges: ObservableObject {
  weak var scroll: UIScrollView?
  func allows(_ dx: CGFloat) -> Bool {
    guard let s = scroll, s.window != nil else { return true }
    guard !s.isZooming, s.pinchGestureRecognizer?.numberOfTouches ?? 0 < 2 else { return false }
    let left = -s.adjustedContentInset.left
    let right = max(left, s.contentSize.width + s.adjustedContentInset.right - s.bounds.width)
    return dx > 0 ? s.contentOffset.x <= left + 2 : s.contentOffset.x >= right - 2
  }
}

private struct SectionSwipe: ViewModifier {
  let enabled: Bool, action: (Int) -> Void
  @AppStorage(InterfaceInteraction.horizontal) private var threshold = 24.0
  func body(content: Content) -> some View {
    content.simultaneousGesture(
      DragGesture(minimumDistance: max(1, min(12, threshold))).onEnded { v in
        guard enabled,
          InterfaceInteraction.horizontalDrag(
            x: v.translation.width, y: v.translation.height, threshold: threshold)
        else { return }
        action(v.translation.width < 0 ? 1 : -1)
      })
  }
}
extension View {
  func piliSectionSwipe(enabled: Bool = true, action: @escaping (Int) -> Void) -> some View {
    modifier(SectionSwipe(enabled: enabled, action: action))
  }
}
