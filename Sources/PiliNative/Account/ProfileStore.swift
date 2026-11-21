import Foundation
import SwiftUI

struct ProfileStatistics: Decodable {
  let following: Int?, follower: Int?, dynamic_count: Int?
}

/// Owns data independently of the tab's SwiftUI lifetime, with separate entries for each account.
@MainActor final class ProfileStore: ObservableObject {
  static let shared = ProfileStore()
  @Published private(set) var profiles: [String: AccountProfile] = [:]
  @Published private(set) var statistics: [String: ProfileStatistics] = [:]
  @Published private(set) var issues: [String: String] = [:]
  private var requested: [String: Date] = [:]
  private var flights: [String: (id: UUID, task: Task<Void, Never>)] = [:]
  private struct ShelfKey: Hashable { let uid: String, field: MineSection }
  private var shelves: [ShelfKey: ProfileShelfState] = [:]
  private var active: String?, historyOwner: String?

  func shelf(_ field: MineSection, uid: String) -> ProfileShelfState {
    let key = ShelfKey(uid: uid, field: field)
    if let existing = shelves[key] { return existing }
    let value = ProfileShelfState(field: field, uid: uid)
    shelves[key] = value
    return value
  }

  /// Called before publishing account changes, including when the profile tab is not mounted.
  func activate(_ state: AccountJar.State) {
    let available = Set(state.accounts.map(\.id))
    for uid in Set(profiles.keys).union(statistics.keys).union(flights.keys).union(requested.keys)
      where !available.contains(uid) {
      invalidate(uid)
      profiles[uid] = nil; statistics[uid] = nil; issues[uid] = nil
    }
    for key in Array(shelves.keys) where !available.contains(key.uid) {
      shelves.removeValue(forKey: key)?.invalidate()
    }
    let nextHistory = state.owner(.history)
    if active != state.active {
      if let active { invalidate(active) }
      if let uid = state.active { invalidate(uid) }
      // History may belong to a different account, but switching the main account still refreshes it.
      for shelf in shelves.values { shelf.invalidate() }
    } else if historyOwner != nextHistory {
      for (key, shelf) in shelves where key.field == .history { shelf.invalidate() }
    }
    active = state.active; historyOwner = nextHistory
  }

  private func invalidate(_ uid: String) {
    flights.removeValue(forKey: uid)?.task.cancel()
    requested[uid] = nil
  }

  func refresh(_ uid: String, force: Bool = false) async {
    if force { invalidate(uid) }
    if let flight = flights[uid] { await flight.task.value; return }
    if let last = requested[uid], Date().timeIntervalSince(last) < 60 { return }
    requested[uid] = Date()
    let id = UUID()
    let task = Task {
      async let person: Void = loadProfile(uid, id: id)
      async let stat: Void = loadStatistics(uid, id: id)
      _ = await (person, stat)
      if flights[uid]?.id == id { flights[uid] = nil }
    }
    flights[uid] = (id, task)
    await task.value
  }

  private func loadProfile(_ uid: String, id: UUID) async {
    do {
      let value = try await BiliAPI.shared.profile(expectedAccount: uid)
      guard !Task.isCancelled, flights[uid]?.id == id, String(value.mid) == uid else { return }
      profiles[uid] = value
      issues[uid] = nil
    } catch {
      if !Task.isCancelled, flights[uid]?.id == id { issues[uid] = error.localizedDescription }
    }
  }

  private func loadStatistics(_ uid: String, id: UUID) async {
    do {
      let value = try await BiliAPI.shared.read(
        "/x/web-interface/nav/stat", [:], expectedAccount: uid, as: ProfileStatistics.self)
      guard !Task.isCancelled, flights[uid]?.id == id else { return }
      statistics[uid] = value
    } catch { /* Retain the last statistics when a background refresh fails. */ }
  }

  func refreshAll(uid: String?, history: String?, fields: [MineSection]) async {
    await withTaskGroup(of: Void.self) { group in
      if let uid { group.addTask { await self.refresh(uid, force: true) } }
      for field in fields {
        if let owner = field == .history ? history : uid {
          let model = shelf(field, uid: owner)
          group.addTask { await model.refresh(force: true) }
        }
      }
    }
  }
}

@MainActor final class ProfileShelfState: ObservableObject {
  let field: MineSection, uid: String
  @Published private(set) var rows: [ProfileShelfItem] = []
  @Published private(set) var total: Int?
  @Published private(set) var cursor: String?
  @Published private(set) var ready = false
  @Published private(set) var loading = false
  @Published private(set) var issue: String?
  private var requested: Date?
  private var failedReset = false
  private typealias Flight = (id: UUID, reset: Bool, task: Task<Void, Never>)
  private var flight: Flight?
  private var waiters = Set<UUID>()
  init(field: MineSection, uid: String) { self.field = field; self.uid = uid }

  func invalidate() {
    flight?.task.cancel(); flight = nil
    waiters.removeAll()
    requested = nil
    loading = false
  }

  func refresh(force: Bool = false) async {
    guard !Task.isCancelled else { return }
    if force { invalidate() }
    if let flight { await wait(for: flight); return }
    if let requested, Date().timeIntervalSince(requested) < 60 { return }
    requested = Date()
    await load(reset: true)
  }

  func loadMore() async {
    guard !Task.isCancelled else { return }
    if let flight {
      await wait(for: flight)
      // After a first-page refresh, the cursor may have changed under a visible pagination row.
      if flight.reset, !Task.isCancelled { await loadMore() }
      return
    }
    guard ready, cursor != nil, issue == nil else { return }
    await load(reset: false)
  }

  func retry() async {
    if !failedReset, ready, cursor != nil { issue = nil; await loadMore() }
    else { await refresh(force: true) }
  }

  private func load(reset: Bool) async {
    let id = UUID(), next = reset ? nil : cursor
    let previous = reset ? [] : rows
    loading = true; issue = nil
    let task = Task {
      defer {
        if flight?.id == id { flight = nil; waiters.removeAll(); loading = false }
      }
      do {
        // Network decoding and mapping run on BiliAPI's actor, not the UI actor.
        let page = try await BiliAPI.shared.profileShelf(field, uid: uid, cursor: next)
        try Task.checkCancellation()
        let merge = Task.detached(priority: .utility) {
          var seen = Set(previous.map(\.id))
          let added = page.items.filter { !Task.isCancelled && seen.insert($0.id).inserted }
          return (previous + added, added.isEmpty ? nil : page.next)
        }
        let merged = await withTaskCancellationHandler { await merge.value } onCancel: { merge.cancel() }
        guard !Task.isCancelled, flight?.id == id else { return }
        rows = merged.0; cursor = merged.1
        if reset || page.reportedTotal != nil { total = page.reportedTotal }
        ready = true
        failedReset = false
      } catch {
        if !Task.isCancelled, flight?.id == id {
          failedReset = reset
          issue = error.localizedDescription
        }
      }
    }
    let request: Flight = (id, reset, task)
    flight = request
    await wait(for: request)
  }

  private func wait(for request: Flight) async {
    let waiter = UUID()
    waiters.insert(waiter)
    await withTaskCancellationHandler {
      await request.task.value
    } onCancel: {
      Task { @MainActor in
        guard self.flight?.id == request.id else { return }
        self.waiters.remove(waiter)
        if self.waiters.isEmpty { self.invalidate() }
      }
    }
  }
}
