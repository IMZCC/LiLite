import SwiftUI

/// A pushed page that is built only when it is shown. `NavigationLink` runs its destination
/// closure as soon as the link is created, so every card in a feed used to construct (and copy
/// on each update) the whole detail page it might open, parsing its link on the way.
struct DeferredPage<Content: View>: View {
  let make: () -> Content
  init(@ViewBuilder _ make: @escaping () -> Content) { self.make = make }
  var body: some View { make() }
}

/// An action passed down the environment. SwiftUI cannot compare closures, so a closure in the
/// environment counts as changed on every pass and re-renders every view that reads it (every
/// comment, every moment card). This compares by a token its owner keeps in `@State`.
struct StableAction<Input>: Equatable {
  let token: UUID
  let run: @MainActor (Input) -> Void
  init(_ token: UUID, _ run: @escaping @MainActor (Input) -> Void) {
    self.token = token
    self.run = run
  }
  @MainActor func callAsFunction(_ input: Input) { run(input) }
  nonisolated static func == (a: Self, b: Self) -> Bool { a.token == b.token }
}

/// Re-renders its content only when `key` changes (use with `.equatable()`). For heavy children
/// whose inputs include closures, which never compare equal, while what they show depends on a
/// few plain values: without it every render of the page rebuilt them too. The environment
/// still reaches the content as usual.
struct StableContent<Key: Equatable, Content: View>: View, Equatable {
  let key: Key
  @ViewBuilder let content: () -> Content
  nonisolated static func == (a: Self, b: Self) -> Bool { a.key == b.key }
  var body: some View { content() }
}

/// `NavigationLink { destination } label: { label }` whose destination is built on push.
struct LazyLink<Destination: View, Label: View>: View {
  let destination: () -> Destination
  let label: Label
  init(@ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: () -> Label) {
    self.destination = destination
    self.label = label()
  }
  var body: some View {
    NavigationLink { DeferredPage(destination) } label: { label }
  }
}
