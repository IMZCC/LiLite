import SwiftUI

struct CreatorSectionBar: View {
  let tabs: [CreatorSpaceRecord.Tab]
  let selected: String
  let motion: PagerIndicatorMotion
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
        PagerIndicator(choices: tabs.map(\.param), motion: motion, frames: frames)
      }
      .coordinateSpace(.named("sections"))
      .padding(.horizontal, 16)
    }
    .scrollClipDisabled()
    .padding(.bottom, 6)
  }
}
