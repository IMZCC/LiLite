import SwiftUI

private struct ActiveCatalogPageKey:EnvironmentKey {static let defaultValue=true}
extension EnvironmentValues {
  var activeCatalogPage:Bool {
    get{self[ActiveCatalogPageKey.self]} set{self[ActiveCatalogPageKey.self]=newValue}
  }
}
private struct CatalogNavigationTitle: ViewModifier {
  let title: String, embedded: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if embedded { content }
    else { content.navigationTitle(title) }
  }
}
extension View {
  func piliCatalogTitle(_ title: String, embedded: Bool) -> some View {
    modifier(CatalogNavigationTitle(title: title, embedded: embedded))
  }
}

/// Keep each visited page's list, scroll position and controls until its owning identity changes.
/// Only the first page carries the edge-swipe probe (see `edgeSwipeBackPriority`).
private struct DeckEdgePriority: ViewModifier {
  let first: Bool, selectedFirst: Bool
  func body(content: Content) -> some View {
    if first { content.edgeSwipeBackPriority(firstPageSelected: selectedFirst) } else { content }
  }
}
struct RetainedDeck<Choice:Hashable,Content:View>:View {
  let choices:[Choice]
  @Binding var selection:Choice
  var swipe=true
  @ViewBuilder let content:(Choice)->Content
  @Environment(\.activeCatalogPage) private var parentActive
  @State private var visited=Set<Choice>()
  @ViewBuilder private func page(_ key:Choice)->some View {
    Group {
      // Neighbours are mounted too, so a swipe reveals a real page instead of a blank one.
      if selection == key || visited.contains(key) || adjacent(key) {
        content(key).environment(\.activeCatalogPage,parentActive && selection==key)
      } else {Color.clear}
    }.accessibilityHidden(selection != key).allowsHitTesting(selection == key)
  }
  private func adjacent(_ key:Choice)->Bool {
    guard swipe, let i=choices.firstIndex(of:selection), let j=choices.firstIndex(of:key) else{return false}
    return abs(i-j)==1
  }
  var body:some View {
    Group {
      if swipe {
        TabView(selection: $selection) {
          ForEach(choices, id: \.self) { choice in
            page(choice).frame(maxWidth: .infinity, maxHeight: .infinity)
              .modifier(DeckEdgePriority(first: choice == choices.first, selectedFirst: selection == choices.first))
              .tag(choice)
          }
        }.tabViewStyle(.page(indexDisplayMode: .never))
      } else {
        ZStack {
          ForEach(choices,id:\.self){choice in page(choice).opacity(choice==selection ? 1:0)}
        }.animation(.easeInOut(duration: 0.2), value: selection)
      }
    }.onChange(of:selection,initial:true){_,v in visited.insert(v)}
      .onChange(of:choices){_,ids in visited.formIntersection(ids)}
  }
}
