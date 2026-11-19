import SwiftUI

/// Text tabs with a short bar under the selected one, like the original client's TabBar and the
/// official app's space and moment tabs. `fill` spreads a few tabs across the width; otherwise
/// they scroll from the leading edge. With a pager's `motion` the bar follows the swipe and the
/// highlight moves to the nearer tab, as in the original's TabBarView.
struct UnderlineTabBar<Item: Hashable>: View {
  let items: [Item]
  @Binding var selection: Item
  let title: (Item) -> String
  var fill = true
  var reselect: (() -> Void)? = nil
  var motion: PagerIndicatorMotion? = nil
  @Namespace private var line
  @State private var centers: [Item: CGFloat] = [:]

  var body: some View {
    Group {
      if fill {
        HStack(spacing: 0) {
          ForEach(items, id: \.self) { tab($0).frame(maxWidth: .infinity) }
        }
        .coordinateSpace(.named("underline.tabs"))
        .overlay(alignment: .bottomLeading) { follower }
      } else {
        ScrollViewReader { proxy in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
              ForEach(items, id: \.self) { tab($0).id($0) }
            }
            .padding(.horizontal, 6)
            .coordinateSpace(.named("underline.tabs"))
            .overlay(alignment: .bottomLeading) { follower }
          }
          .onChange(of: selection) { _, value in
            withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(value, anchor: .center) }
          }
        }
      }
    }
    .frame(height: 44)
  }

  @ViewBuilder private var follower: some View {
    if let motion { FollowingUnderline(items: items, centers: centers, motion: motion) }
  }

  private func isActive(_ item: Item) -> Bool {
    if let motion, items.indices.contains(motion.nearestIndex) { return items[motion.nearestIndex] == item }
    return item == selection
  }

  private func tab(_ item: Item) -> some View {
    let active = isActive(item)
    return Button {
      if item == selection {
        reselect?()
      } else {
        TouchFeedback.light()
        withAnimation(.snappy(duration: 0.25)) { selection = item }
      }
    } label: {
      VStack(spacing: 5) {
        Spacer(minLength: 0)
        Text(title(item))
          .font(.subheadline.weight(active ? .semibold : .regular))
          .foregroundStyle(active ? Color.accentColor : Color.primary)
          .lineLimit(1)
        ZStack {
          if motion == nil && active {
            Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "line", in: line)
          }
        }.frame(width: 18, height: 3)
      }
      .padding(.horizontal, 12)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("underline.tabs")).midX } action: {
        if centers[item] != $0 { centers[item] = $0 }
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(item == selection ? .isSelected : [])
  }
}

/// The bar under the tabs, placed between the two tabs the pager sits between. Only this view
/// reads the pager position on every frame.
private struct FollowingUnderline<Item: Hashable>: View {
  let items: [Item]
  let centers: [Item: CGFloat]
  let motion: PagerIndicatorMotion
  var body: some View {
    let p = min(max(0, motion.progress), CGFloat(max(0, items.count - 1)))
    let i = Int(p.rounded(.down))
    let f = p - CGFloat(i)
    if items.indices.contains(i), let a = centers[items[i]] {
      let b = items.indices.contains(i + 1) ? centers[items[i + 1]] ?? a : a
      Capsule().fill(Color.accentColor)
        .frame(width: 18, height: 3)
        .offset(x: a + (b - a) * f - 9)
        .allowsHitTesting(false)
    }
  }
}
