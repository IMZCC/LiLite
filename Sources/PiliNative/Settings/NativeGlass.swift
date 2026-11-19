import SwiftUI

enum NativeGlass {
  /// Liquid Glass exists from iOS 26. Earlier systems (down to the iOS 17 deployment target) get
  /// the system materials instead; iOS 26 and later keep the same code path as before.
  static var available: Bool {
    if #available(iOS 26, *) { return true }
    return false
  }
  /// Corner radius for content cards (thumbnails, panels) in the iOS 26+ design language.
  static let cardRadius: CGFloat = 18
  /// Corner radius for large grouped surfaces such as sheets' inner panels.
  static let panelRadius: CGFloat = 26
  /// Corner radius for small thumbnails and chips.
  static let thumbRadius: CGFloat = 10
}

/// Use the system optical material on the controls layer, keeping media and reading surfaces plain.
private struct NativeGlassSurface<S: Shape>: ViewModifier {
  let shape: S
  let interactive: Bool
  let tint: Color?
  let fallback: AnyShapeStyle
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @ViewBuilder func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(.background, in: shape)
    } else if #available(iOS 26, *) {
      content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
    } else if let tint {
      content.background(tint, in: shape)
    } else {
      content.background(fallback, in: shape)
    }
  }
}

extension View {
  func piliGlass<S: Shape>(
    in shape: S, interactive: Bool = false, tint: Color? = nil,
    fallback: AnyShapeStyle = AnyShapeStyle(.regularMaterial)
  ) -> some View {
    modifier(NativeGlassSurface(shape: shape, interactive: interactive, tint: tint, fallback: fallback))
  }
  /// `.buttonStyle(.glass)` / `.glassProminent` on iOS 26+, bordered styles before.
  @ViewBuilder func piliGlassButton(prominent: Bool = false) -> some View {
    if #available(iOS 26, *) {
      if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
    } else {
      if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
  }
  /// The scroll edge effect only exists from iOS 26.
  @ViewBuilder func piliScrollEdgeEffectHidden(_ hidden: Bool = true, for edges: Edge.Set = .all) -> some View {
    if #available(iOS 26, *) { scrollEdgeEffectHidden(hidden, for: edges) } else { self }
  }
}

/// A glass panel concentric with the display's corners (iOS 26), or a rounded material panel.
struct ConcentricGlassPanel: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content.glassEffect(
        .regular, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(20)), isUniform: true))
    } else {
      content.piliGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
  }
}

struct PiliGlassGroup<Content: View>: View {
  var spacing: CGFloat = 8
  @ViewBuilder var content: () -> Content
  var body: some View {
    if #available(iOS 26, *) { GlassEffectContainer(spacing: spacing, content: content) } else { content() }
  }
}

/// Standard navigation/toolbars already adopt Liquid Glass. Do not replace their system material.
struct NativeNavigationBackground: ViewModifier {
  let black: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if black {
      content.toolbarBackground(.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    } else {
      content
    }
  }
}
