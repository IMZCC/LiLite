@main enum NativePagingCheck {
  static func main() {
    var state = NativePagingSelection()
    state.update(count: 2, page: 0, moving: false)
    state.applied()
    // Progress/metadata changes while following the finger cannot change the selected page.
    for _ in 0..<120 { state.update(count: 2, page: 0, moving: true) }
    precondition(state.selected == 0)
    precondition(state.settle(at: 1) == 1)
    // An old parent render can arrive before SwiftUI acknowledges the queued commit.
    state.update(count: 2, page: 0, moving: false)
    precondition(state.requested == 1 && state.canPublish(1))
    state.applied()
    state.update(count: 2, page: 1, moving: false)
    precondition(state.settle(at: 1) == nil)

    // A tab/deep-link change during deceleration wins over the old gesture's destination.
    state.update(count: 3, page: 1, moving: false)
    state.applied()
    state.update(count: 3, page: 2, moving: true)
    precondition(state.settle(at: 0) == nil && state.requested == 2)
    state.applied()
    precondition(state.selected == 2 && state.settle(at: 2) == nil)

    // Removing comments/playlist while moving clamps safely to the remaining page.
    state.update(count: 1, page: 2, moving: true)
    precondition(state.settle(at: 2) == nil)
    state.applied()
    precondition(state.count == 1 && state.selected == 0)

    // A new drag can reverse the first swipe before its asynchronous binding commit runs.
    state = NativePagingSelection()
    state.update(count: 2, page: 0, moving: false)
    state.applied()
    precondition(state.settle(at: 1) == 1)
    precondition(state.settle(at: 0) == nil && !state.canPublish(1))
    precondition(state.settle(at: 1) == 1 && state.canPublish(1))
    state.update(count: 3, page: 2, moving: true)
    precondition(!state.canPublish(1) && state.settle(at: 1) == nil)

    // Starting on comments and cancelling a swipe must not notify or jump to intro.
    state = NativePagingSelection()
    state.update(count: 2, page: 1, moving: false)
    state.applied()
    precondition(state.selected == 1 && state.settle(at: 1) == nil)
    state.update(count: 2, page: 0, moving: false)
    state.applied()
    precondition(state.settle(at: 1) == 1)
    state.update(count: 0, page: -1, moving: false)
    state.applied()
    precondition(state.count == 0 && state.selected == 0 && !state.canPublish(1))
    print("Native paging: 120 in-motion refreshes, delayed binding acknowledgement, cancelled/reversed swipes, external selection and page removal passed")
  }
}
