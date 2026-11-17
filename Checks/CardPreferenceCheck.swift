import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum CardPreferenceCheck {
  static func run() async throws {
    let recommend = CardPreferenceMutation.feed(
      kind: "av", id: 45, group: "feedback", reason: 9, undo: false)
    let cancel = CardPreferenceMutation.feed(
      kind: "av", id: 45, group: "dislike", reason: 11, undo: true)
    let normal = CardPreferenceMutation.archive(id: 45, undo: false)
    let undo = CardPreferenceMutation.archive(id: 45, undo: true)
    precondition(
      recommend.role == .recommend && cancel.role == .recommend && normal.role == .main
        && undo.role == .main)
    var attempted = 0
    for identity in [("other", "local-test"), ("test", "")] {
      do {
        try await normal.sendOnce(expected: "test", actor: identity.0, token: identity.1) { _ in
          attempted += 1
          throw URLError(.timedOut)
        }
        preconditionFailure()
      } catch {}
    }
    precondition(attempted == 0)
    for mutation in [recommend, normal] {
      let before = attempted
      do {
        try await mutation.sendOnce(expected: "test", actor: "test", token: "local-test") { _ in
          attempted += 1
          throw URLError(.timedOut)
        }
        preconditionFailure()
      } catch {}
      precondition(attempted == before + 1)
    }
    for (mutation, code) in [(recommend, "0"), (cancel, "0"), (normal, "-400"), (undo, "0")] {
      let prev = attempted
      do {
        try await mutation.sendOnce(expected: "test", actor: "test", token: "local & test", timestamp: 1_700_000_000) { r in
          attempted += 1
          let u = r.url!
          precondition(
            !r.httpShouldHandleCookies && u.host == "app.bilibili.com" && u.scheme == "https")
          let query = URLComponents(url: u, resolvingAgainstBaseURL: false)!
          precondition(r.value(forHTTPHeaderField: "Cookie") == nil && r.value(forHTTPHeaderField: "Authorization") == nil)
          let fields: [String: String]
          if case .feed(_, _, let g, let reason, let inverse) = mutation {
            fields = Dictionary(
              uniqueKeysWithValues: (query.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            precondition(
              r.httpMethod == "GET" && fields["access_key"] == "local & test"
                && fields["id"] == "45")
            precondition(fields[g == "feedback" ? "feedback_id" : "reason_id"] == String(reason))
            precondition(fields["build"] == "1" && fields["mobi_app"] == "android" && fields["platform"] == nil)
            precondition(u.path == (inverse ? "/x/feed/dislike/cancel" : "/x/feed/dislike"))
          } else if case .archive(_, let inverse) = mutation {
            var form = URLComponents()
            form.percentEncodedQuery = String(decoding: r.httpBody!, as: UTF8.self)
            fields = Dictionary(
              uniqueKeysWithValues: (form.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            precondition(
              r.httpMethod == "POST" && query.queryItems == nil && u.path == "/x/v2/view/dislike")
            precondition(
              fields["aid"] == "45" && fields["dislike"] == (inverse ? "1" : "0")
                && fields["access_key"] == "local & test")
          } else { preconditionFailure() }
          // Expected digests are generated independently in discovery_readback.py from the
          // pinned Dart Constants and urllib's exact encodeComponent safe set.
          let key = u.path + ":" + (fields["feedback_id"] ?? fields["reason_id"] ?? fields["dislike"] ?? "")
          precondition(fields["ts"] == "1700000000" && fields["sign"] == CardPreferenceSignatureFixture.expected[key])
          return (
            Data("{\"code\":\(code),\"message\":\"fixture\"}".utf8),
            HTTPURLResponse(url: u, statusCode: 200, httpVersion: nil, headerFields: nil)!
          )
        }
        precondition(code == "0")
      } catch { precondition(code != "0") }
      precondition(attempted == prev + 1)
    }
    struct Row: Identifiable { let id: Int }
    let item = Row(id: 2)
    var list = [Row(id: 1), Row(id: 3)]
    CardPreferenceMutation.restore(item, at: 1, to: &list)
    CardPreferenceMutation.restore(item, at: 0, to: &list)
    precondition(list.map(\.id) == [1, 2, 3])
    var short = [Row]()
    CardPreferenceMutation.restore(item, at: 400, to: &short)
    precondition(short.map(\.id) == [2])
    print(
      "Offline preferences: exact public AppSign on feed/archive/undo, correct roles, zero sends on identity/token mismatch, one send per timeout/rejected ack, restore in order without duplicates"
    )
  }
}
