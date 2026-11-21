import SwiftUI

// The parts every page of the fullscreen 更多 panel is drawn with, after the reference player's
// panel: white text on the frosted ground, a section's name small and dim over its choices,
// choices as words in capsules (the current one lit in the accent), rows 46 pt tall with a dim
// symbol, and hairlines between sections. No page in the panel uses the system's grouped form.

/// A page of the panel. The first page has no title, as the reference player's; the pages it
/// opens have the panel's own back-and-title row.
struct TheaterPanelScroll<Content: View>: View {
  let title: String
  var header = true
  @ViewBuilder let content: () -> Content
  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 0) { content() }
        .padding(.top, header ? 0 : 8).padding(.bottom, 14)
    }
    .foregroundStyle(.white)
    .modifier(TheaterPanelPage(title: header ? title : nil))
  }
}

/// Every page of the panel on the panel's own ground. The system bar stays hidden on all of them:
/// a page's back-and-title row is part of the page and slides in with it, so nothing appears or
/// vanishes at the top when a page is pushed. Pages from elsewhere in the app (comments, the
/// bullet list) get the same row.
struct TheaterPanelPage: ViewModifier {
  let title: String?
  func body(content: Content) -> some View {
    content
      // The stack is UIKit's and hands its pages the window's safe area, which in landscape is as
      // wide on the side without the island; the panel keeps clear of the island itself.
      .ignoresSafeArea(.container, edges: .horizontal)
      .scrollContentBackground(.hidden)
      .toolbar(.hidden, for: .navigationBar)
      .safeAreaInset(edge: .top, spacing: 0) {
        if let title { TheaterPanelHeader(title: title) }
      }
      // A hidden bar turns off the stack's edge swipe: a page past the first goes back by its own.
      .background { LeadingEdgeNavigation(fullWidth: true).frame(width: 0, height: 0) }
      .piliClearNavigationBackground()
  }
}

/// ‹ and the page's name.
struct TheaterPanelHeader: View {
  let title: String
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    HStack(spacing: 0) {
      Button {
        TouchFeedback.light()
        dismiss()
      } label: {
        Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
          .frame(width: 44, height: 44).contentShape(Rectangle())
      }
      .buttonStyle(PlayerPressStyle())
      .accessibilityLabel("返回")
      Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
        .accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
    }
    .foregroundStyle(.white)
    .padding(.leading, 4).padding(.trailing, 16)
    .frame(height: 46)
  }
}

struct TheaterPanelDivider: View {
  var body: some View {
    Rectangle().fill(.white.opacity(0.09)).frame(height: 1).padding(.horizontal, 16)
  }
}

/// A section: its name, small and dim, over its contents.
struct TheaterPanelSection<Content: View>: View {
  let title: String?
  @ViewBuilder let content: () -> Content
  init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let title {
        Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.55))
      }
      content()
    }
    .padding(.horizontal, 16).padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A word in a capsule, lit in the accent while it is chosen.
struct TheaterPanelChip: View {
  let name: String
  let on: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Text(name)
        .font(.system(size: 14, weight: on ? .semibold : .regular)).monospacedDigit()
        .foregroundStyle(on ? Color.accentColor : .white)
        .lineLimit(1)
        .padding(.horizontal, 13).frame(minWidth: 46, minHeight: 32)
        .background(on ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.08), in: Capsule())
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.15), value: on)
    }
    .buttonStyle(PlayerPressStyle())
    .accessibilityLabel(name)
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

/// One choice among words.
struct TheaterPanelChoices<ID: Hashable>: View {
  let options: [(ID, String)]
  let selected: ID?
  var disabled = false
  let pick: (ID) -> Void
  var body: some View {
    WrappingActions(spacing: 8, rowSpacing: 8) {
      ForEach(options.indices, id: \.self) { i in
        let option = options[i]
        TheaterPanelChip(name: option.1, on: option.0 == selected) {
          guard option.0 != selected else { return }
          TouchFeedback.light()
          pick(option.0)
        }
      }
    }
    .disabled(disabled)
    .opacity(disabled ? 0.5 : 1)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Words that switch on and off on their own.
struct TheaterPanelFlags: View {
  let options: [(String, Binding<Bool>)]
  var body: some View {
    WrappingActions(spacing: 8, rowSpacing: 8) {
      ForEach(options.indices, id: \.self) { i in
        let option = options[i]
        TheaterPanelChip(name: option.0, on: option.1.wrappedValue) {
          TouchFeedback.light()
          option.1.wrappedValue.toggle()
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A named slider with its value at the right. A slider with a few steps ticks at each.
struct TheaterPanelSlider: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double = 0.01
  let text: (Double) -> String
  var body: some View {
    let ticks = step > 0 && (range.upperBound - range.lowerBound) / step <= 40
    VStack(spacing: 4) {
      HStack {
        Text(title).font(.system(size: 14))
        Spacer(minLength: 8)
        Text(text(value)).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white.opacity(0.6))
          .contentTransition(.numericText())
      }
      Slider(value: $value, in: range, step: step).tint(.accentColor)
        .accessibilityLabel(title).accessibilityValue(text(value))
    }
    .padding(.horizontal, 16).padding(.vertical, 6)
    .sensoryFeedback(.selection, trigger: ticks ? value : 0)
  }
}

/// A row: symbol, name, value and, for a page, a chevron.
struct TheaterPanelRow: View {
  var symbol: String? = nil
  let title: String
  var value: String? = nil
  var chevron = true
  var body: some View {
    HStack(spacing: 12) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.white.opacity(0.8)).frame(width: 22)
      }
      Text(title).font(.system(size: 14)).foregroundStyle(.white)
      Spacer(minLength: 8)
      if let value {
        Text(value).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
      }
      if chevron {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
      }
    }
    .lineLimit(1)
    .padding(.horizontal, 16).frame(minHeight: 46)
    .contentShape(Rectangle())
  }
}
/// A row that does something when tapped.
struct TheaterPanelAction: View {
  var symbol: String? = nil
  let title: String
  var value: String? = nil
  var chevron = false
  let action: () -> Void
  var body: some View {
    Button(action: action) { TheaterPanelRow(symbol: symbol, title: title, value: value, chevron: chevron) }
      .buttonStyle(TheaterPanelRowStyle())
  }
}
struct TheaterPanelSwitch: View {
  var symbol: String? = nil
  let title: String
  let on: Binding<Bool>
  var body: some View {
    Toggle(isOn: Binding(get: { on.wrappedValue }, set: { TouchFeedback.light(); on.wrappedValue = $0 })) {
      HStack(spacing: 12) {
        if let symbol {
          Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.white.opacity(0.8)).frame(width: 22)
        }
        Text(title).font(.system(size: 14)).foregroundStyle(.white)
      }
    }
    .tint(.accentColor)
    .padding(.horizontal, 16).frame(minHeight: 46)
  }
}
/// One of a list of choices that need a line of explanation each; the chosen one is ticked.
struct TheaterPanelPick: View {
  let title: String
  var detail: String? = nil
  let on: Bool
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.system(size: 14, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? Color.accentColor : .white)
          if let detail {
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 8)
        if on {
          Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 46)
      .contentShape(Rectangle())
    }
    .buttonStyle(TheaterPanelRowStyle())
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}
/// A name and its value, for reading.
struct TheaterPanelValue: View {
  let title: String
  let value: String
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
      Spacer(minLength: 8)
      Text(value).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
        .multilineTextAlignment(.trailing).textSelection(.enabled)
    }
    .padding(.horizontal, 16).padding(.vertical, 7)
  }
}
/// A small explanation under a section.
struct TheaterPanelNote: View {
  let text: String
  var warning = false
  init(_ text: String, warning: Bool = false) {
    self.text = text
    self.warning = warning
  }
  var body: some View {
    Text(text).font(.system(size: 12))
      .foregroundStyle(warning ? Color.red.opacity(0.9) : .white.opacity(0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 10)
  }
}
/// Rows light up under the finger instead of shrinking.
struct TheaterPanelRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0))
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
