import SwiftUI

/// A comment thread opened inside the video detail. As in the original client it slides up as a
/// panel over the tabs and lists under the player (never over the video), titled "评论详情" or
/// "对话列表", and closes with its button or a swipe to the right.
struct ReplyPanelItem: Identifiable {
  let id: UUID
  let title: String
  let content: AnyView
  init(title: String, content: AnyView) {
    id = UUID()
    self.title = title
    self.content = content
  }
}

/// Opens a panel in the video detail that hosts it; returns false when no live host is on screen
/// (the comments then open as a page, as everywhere else).
struct ReplyPanelPresenter {
  let push: @MainActor (_ title: String, _ content: AnyView) -> Bool
}
private struct ReplyPanelPresenterKey: EnvironmentKey {
  static let defaultValue: ReplyPanelPresenter? = nil
}
extension EnvironmentValues {
  var replyPanelPresenter: ReplyPanelPresenter? {
    get { self[ReplyPanelPresenterKey.self] }
    set { self[ReplyPanelPresenterKey.self] = newValue }
  }
}

struct ReplyPanelStack: View {
  @Binding var items: [ReplyPanelItem]
  var body: some View {
    ZStack {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        ReplyPanelChrome(title: item.title) {
          close(item.id)
        } content: {
          item.content
        }
        .zIndex(Double(index))
        .transition(.move(edge: .bottom))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .allowsHitTesting(!items.isEmpty)
    .animation(.smooth(duration: 0.3), value: items.map(\.id))
  }
  private func close(_ id: UUID) {
    items.removeAll { $0.id == id }
  }
}

private struct ReplyPanelChrome<Content: View>: View {
  let title: String
  let close: () -> Void
  @ViewBuilder let content: () -> Content
  @State private var drag: CGFloat = 0
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(title).font(.subheadline)
        Spacer()
        Button {
          TouchFeedback.light()
          close()
        } label: {
          Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel("关闭")
      }
      .padding(.leading, 14).padding(.trailing, 2).frame(height: 45)
      Divider().opacity(0.5)
      content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(uiColor: .systemBackground))
    .offset(x: drag)
    // Swipe right to close, like the original's sliding page.
    .simultaneousGesture(
      DragGesture(minimumDistance: 18)
        .onChanged { g in
          let w = g.translation.width
          guard w > 0, abs(w) > abs(g.translation.height) * 1.4 else { return }
          drag = w
        }
        .onEnded { g in
          let far = drag > 110 || (drag > 30 && g.predictedEndTranslation.width > 260)
          if far {
            withAnimation(.smooth(duration: 0.22)) { drag = 600 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { close() }
          } else {
            withAnimation(.smooth(duration: 0.25)) { drag = 0 }
          }
        })
  }
}

/// Places the panels from the player's lower edge down, following the paused player as it
/// folds (only this view observes the fold, so scrolling doesn't re-render the page).
struct FoldAwareReplyPanels: View {
  let fold: PanelFold
  let active: Bool
  let playerHeight: CGFloat
  @Binding var items: [ReplyPanelItem]
  var body: some View {
    ReplyPanelStack(items: $items)
      .padding(.top, playerHeight - fold.progress(active) * fold.limit)
  }
}
