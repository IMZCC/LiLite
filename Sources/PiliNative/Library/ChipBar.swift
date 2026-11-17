import SwiftUI

/// Horizontally scrolling capsule tabs, the same control the home feed uses for its channels.
struct ChipBar<Item: Hashable>: View {
  let items: [Item]
  @Binding var selection: Item
  let title: (Item) -> String
  var reselect: (() -> Void)? = nil
  @Namespace private var space
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 4) {
          ForEach(items, id: \.self) { item in
            let current = item == selection
            Button {
              TouchFeedback.light()
              if current {
                reselect?()
              } else {
                withAnimation(.snappy(duration: 0.25)) { selection = item }
              }
            } label: {
              Text(title(item))
                .font(.subheadline.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background {
                  if current {
                    Capsule().fill(Color(uiColor: .tertiarySystemFill))
                      .matchedGeometryEffect(id: "chip", in: space)
                  }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).accessibilityAddTraits(current ? .isSelected : []).id(item)
          }
        }.padding(.horizontal, 16)
      }
      .scrollClipDisabled()
      .onChange(of: selection, initial: true) { _, value in
        withAnimation(.snappy) { proxy.scrollTo(value, anchor: .center) }
      }
    }
  }
}

/// Compact single-line chip row for filter groups (the original client's index filters).
struct FilterChips<Item: Hashable>: View {
  let items: [Item]
  @Binding var selection: Item
  let title: (Item) -> String
  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(items, id: \.self) { item in
          let current = item == selection
          Button {
            TouchFeedback.light()
            withAnimation(.snappy(duration: 0.2)) { selection = item }
          } label: {
            Text(title(item)).font(.footnote.weight(current ? .semibold : .regular))
              .foregroundStyle(current ? Color.accentColor : Color.secondary)
              .padding(.horizontal, 11).padding(.vertical, 5)
              .background(current ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
              .contentShape(Capsule())
          }.buttonStyle(.plain).accessibilityAddTraits(current ? .isSelected : [])
        }
      }.padding(.horizontal, 12)
    }.scrollClipDisabled()
  }
}
