import Observation
import SwiftUI

/// The space owns this reference, but only the tab bar reads its changing values.
@MainActor @Observable final class CreatorSectionMotion {
  private(set) var progress: CGFloat = 0
  private(set) var nearestIndex = 0

  func update(_ value: CGFloat) {
    guard progress != value else { return }
    progress = value
    let nearest = Int(value.rounded())
    if nearestIndex != nearest { nearestIndex = nearest }
  }
}

struct CreatorSectionBar: View {
  let tabs: [CreatorSpaceRecord.Tab]
  let selected: String
  let motion: CreatorSectionMotion
  let select: (String) -> Void
  @State private var frames: [String: CGRect] = [:]

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        let nearIndex = motion.nearestIndex
        let near = tabs.indices.contains(nearIndex) ? tabs[nearIndex].param : selected
        ForEach(tabs) { tab in
          let active = selected == tab.param
          Button {
            TouchFeedback.light()
            select(tab.param)
          } label: {
            Text(tab.title ?? CreatorSection(param: tab.param)?.label ?? "")
              .font(.subheadline.weight(near == tab.param ? .semibold : .regular))
              .foregroundStyle(near == tab.param ? Color.primary : Color.secondary)
              .padding(.horizontal, 16).padding(.vertical, 8)
              .contentShape(Capsule())
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("sections")) } action: {
                if frames[tab.param] != $0 { frames[tab.param] = $0 }
              }
          }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
        }
      }
      .background(alignment: .topLeading) {
        CreatorSectionIndicator(tabs: tabs, motion: motion, frames: frames)
      }
      .coordinateSpace(.named("sections"))
      .padding(.horizontal, 16)
    }
    .scrollClipDisabled()
    .padding(.bottom, 6)
  }
}

/// Only this small view observes the fractional offset on every scrolling frame.
private struct CreatorSectionIndicator: View {
  let tabs: [CreatorSpaceRecord.Tab]
  let motion: CreatorSectionMotion
  let frames: [String: CGRect]

  var body: some View {
    let p = min(max(0, motion.progress), CGFloat(max(0, tabs.count - 1)))
    let i = Int(p.rounded(.down))
    let f = p - CGFloat(i)
    if tabs.indices.contains(i), let a = frames[tabs[i].param] {
      let b = tabs.indices.contains(i + 1) ? frames[tabs[i + 1].param] ?? a : a
      Capsule().fill(Color(uiColor: .tertiarySystemFill))
        .frame(width: a.width + (b.width - a.width) * f, height: a.height)
        .offset(x: a.minX + (b.minX - a.minX) * f, y: a.minY)
        .allowsHitTesting(false)
    }
  }
}
