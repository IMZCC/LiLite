"""Exercise the shipping device activation request and state actor using synthetic inputs only."""
import base64
import json
from pathlib import Path
import subprocess
import tempfile

native = Path(__file__).resolve().parents[1]
src = native / "Sources/PiliNative"
fixture = r'''
import Foundation
import FoundationNetworking

typealias Snapshot = DeviceActivation.Snapshot
let fixturePayload = DeviceActivation.Payload(platform: "iOS 27.1; iPhone Fixture", entropy: Data(0..<36))
let good = DeviceActivation.Response(data: Data(#"{"code":0}"#.utf8), status: 200, cookies: [])
let bad = DeviceActivation.Response(data: Data(#"{"code":-412,"message":"fixture rejection"}"#.utf8), status: 200, cookies: [])
func snapshot(_ owner: String? = "100", device: String = "fixture-device", cookie: String = "SESSDATA=fixture-session; bili_jct=fixture-csrf", credential: String = "fixture-session|fixture-csrf|fixture-token", routing: String = "main:100", generation: UInt64 = 1) -> Snapshot {
  .init(owner: owner, device: device, cookie: cookie, credential: credential, routing: routing, generation: generation)
}
actor Store {
  var value: Snapshot
  var commits = 0
  init(_ value: Snapshot) { self.value = value }
  func current(_ ignored: Snapshot) -> Snapshot { value }
  func replace(_ next: Snapshot) { value = next }
  func commit(_ bound: Snapshot, _ response: DeviceActivation.Response, rotate: Snapshot? = nil) throws -> Snapshot {
    guard bound.matches(value) else { throw CancellationError() }
    commits += 1
    if let rotate { value = rotate }
    return value
  }
}
actor Wire {
  private var release: CheckedContinuation<Void, Never>?
  private var waiting = false
  var calls = 0
  var cancelled = false
  func send(_ request: URLRequest, pause: Bool = false) async throws -> DeviceActivation.Response {
    calls += 1
    if pause {
      await withCheckedContinuation { release = $0; waiting = true }
    }
    do { try Task.checkCancellation() } catch { cancelled = true; throw error }
    return good
  }
  func untilWaiting() async { while !waiting { await Task.yield() } }
  func resume() { release?.resume(); release = nil }
}
@main enum ActivationCheck {
  static func rejected(_ operation: () async throws -> Void) async throws {
    do { try await operation() } catch { return }
    preconditionFailure("a rejected or stale activation was accepted")
  }
  static func run(_ client: DeviceActivationClient, _ bound: Snapshot, _ store: Store,
    send: @escaping @Sendable (URLRequest) async throws -> DeviceActivation.Response = { _ in good },
    rotate: Snapshot? = nil) async throws -> Bool {
    try await client.activate(bound, payload: { fixturePayload }, current: { await store.current($0) },
      send: send, commit: { try await store.commit($0, $1, rotate: rotate) })
  }
  static func main() async throws {
    let bound = snapshot()
    let request = try DeviceActivation.request(fixturePayload, snapshot: bound)
    precondition(request.httpMethod == "POST" && !request.httpShouldHandleCookies)
    precondition(request.value(forHTTPHeaderField: "Cookie") == bound.cookie)
    precondition(request.value(forHTTPHeaderField: "buvid") == bound.device)
    precondition(request.value(forHTTPHeaderField: "x-bili-mid") == "100")
    precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
    let guest = try DeviceActivation.request(fixturePayload, snapshot: snapshot(nil, cookie: "buvid3=fixture-guest", credential: "guest", routing: "main:guest"))
    precondition(guest.value(forHTTPHeaderField: "x-bili-mid") == nil && guest.value(forHTTPHeaderField: "Cookie") == "buvid3=fixture-guest")
    let record: [String: String] = ["url": request.url!.absoluteString,
      "body": String(decoding: request.httpBody!, as: UTF8.self),
      "type": request.value(forHTTPHeaderField: "Content-Type")!,
      "agent": request.value(forHTTPHeaderField: "User-Agent")!]
    print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))

    let client = DeviceActivationClient(), store = Store(bound), wire = Wire()
    let first = try await run(client, bound, store, send: { try await wire.send($0) })
    let duplicate = try await run(client, bound, store, send: { try await wire.send($0) })
    let count = await wire.calls
    precondition(first && !duplicate && count == 1)

    // A rejected HTTP/protocol response cannot mark the identity complete; a later refresh retries.
    for response in [bad, DeviceActivation.Response(data: good.data, status: 503, cookies: []),
      DeviceActivation.Response(data: Data("not-json".utf8), status: 200, cookies: [])] {
      let retry = DeviceActivationClient(), retryStore = Store(bound)
      try await rejected { _ = try await run(retry, bound, retryStore, send: { _ in response }) }
      let completed = try await run(retry, bound, retryStore)
      precondition(completed)
    }
    // The HTTP cookie interceptor may legitimately rotate credentials and increment the store revision.
    let rotated = snapshot(cookie: "SESSDATA=new-session; bili_jct=new-csrf", credential: "new-session|new-csrf|fixture-token", generation: 12)
    let rotating = DeviceActivationClient(), rotatingStore = Store(bound)
    let rotatedSuccess = try await run(rotating, bound, rotatingStore, rotate: rotated)
    let rotatedDuplicate = try await run(rotating, rotated, rotatingStore)
    precondition(rotatedSuccess && !rotatedDuplicate)
    let revisionOnly = snapshot(generation: 500)
    let revisionClient = DeviceActivationClient(), revisionStore = Store(revisionOnly)
    let revisionSuccess = try await run(revisionClient, bound, revisionStore)
    precondition(revisionSuccess)

    // Account, token, device and routing edits are checked before send and again before commit.
    for changed in [snapshot("200"), snapshot(device: "changed-device"),
      snapshot(credential: "changed-token"), snapshot(routing: "main:200")] {
      let stale = DeviceActivationClient(), before = Store(changed), untouched = Wire()
      try await rejected { _ = try await run(stale, bound, before, send: { try await untouched.send($0) }) }
      let preflightCalls = await untouched.calls; precondition(preflightCalls == 0)
      let after = Store(bound)
      try await rejected {
        _ = try await run(stale, bound, after, send: { _ in await after.replace(changed); return good })
      }
      let commits = await after.commits; precondition(commits == 0)
    }
    // Concurrent account refreshes coalesce the same activation into one actual request.
    let concurrent = DeviceActivationClient(), concurrentStore = Store(bound), blocked = Wire()
    let a = Task { try await run(concurrent, bound, concurrentStore, send: { try await blocked.send($0, pause: true) }) }
    await blocked.untilWaiting()
    let b = Task { try await run(concurrent, bound, concurrentStore, send: { try await blocked.send($0, pause: true) }) }
    for _ in 0..<50 { await Task.yield() }
    await blocked.resume()
    let results = [try await a.value, try await b.value]
    let concurrentCalls = await blocked.calls
    precondition(results.filter { $0 }.count == 1 && concurrentCalls == 1)
    // Explicit cancellation and removal from the active role set discard late replies without a commit.
    for remove in [false, true] {
      let cancelled = DeviceActivationClient(), cancelledStore = Store(bound), delayed = Wire()
      let task = Task { try await run(cancelled, bound, cancelledStore, send: { try await delayed.send($0, pause: true) }) }
      await delayed.untilWaiting()
      if remove { await cancelled.retain([]) } else { task.cancel() }
      await delayed.resume()
      try await rejected { _ = try await task.value }
      let commits = await cancelledStore.commits
      precondition(commits == 0)
      let retried = try await run(cancelled, bound, cancelledStore)
      precondition(retried)
    }
    // A role edit may start a replacement with the same credentials while the obsolete request is still pending.
    let replacement = DeviceActivationClient(), replacementStore = Store(bound), oldWire = Wire()
    let old = Task { try await run(replacement, bound, replacementStore, send: { try await oldWire.send($0, pause: true) }) }
    await oldWire.untilWaiting()
    let newBound = snapshot(routing: "main:100;recommend:100")
    await replacementStore.replace(newBound)
    let newResult = try await run(replacement, newBound, replacementStore)
    await oldWire.resume()
    try await rejected { _ = try await old.value }
    let stillComplete = try await run(replacement, newBound, replacementStore)
    precondition(newResult && !stillComplete)
    print("Device activation production request/state actor: PASS")
  }
}
'''
with tempfile.TemporaryDirectory(prefix="pili-activation-") as temporary:
    temporary = Path(temporary)
    driver = temporary / "ActivationCheck.swift"
    driver.write_text(fixture)
    binary = temporary / "activation"
    subprocess.run(["swiftc", str(src / "Network/ServiceError.swift"),
        str(src / "Account/MobileDeviceID.swift"), str(src / "Network/DeviceActivation.swift"),
        str(driver), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary)], check=True, text=True, capture_output=True, timeout=30)
    record = json.loads(result.stdout.splitlines()[0])
    assert record["url"] == "https://api.bilibili.com/x/internal/gaia-gateway/ExClimbWuzhi"
    assert record["type"] == "application/json; charset=utf-8"
    assert record["agent"] == "PiliPlus Native (iOS 27.1; iPhone Fixture)"
    body = json.loads(record["body"])
    assert set(body) == {"payload"} and isinstance(body["payload"], str)
    payload = json.loads(body["payload"])
    png = bytes(range(32)) + b"\0\0\0\0IEND" + bytes(range(32, 36))
    assert payload == {"3064": 1, "39c8": "333.1387.fp.risk", "3c43": {
        "adca": "iOS 27.1; iPhone Fixture", "bfe9": base64.b64encode(png).decode()[-50:]}}
    print(result.stdout.splitlines()[-1])
    print("Independent activation payload serialization oracle: PASS")

integration = r'''
import Foundation
import FoundationNetworking

// The secure store, first-use identity probe and transport are injected leaves. The production
// cookie model, activation context, runtime service, request parser and state actors are unchanged.
actor AccountJar {
  static let shared = AccountJar()
  struct Identity { let id: String }
  struct State {
    var accounts = [Identity(id: "100"), Identity(id: "200")]
    var active: String? = nil
    var effectiveRoutes = AccountRoutes()
    func owner(_ use: AccountUse) -> String? { effectiveRoutes.owner(use, main: active, available: Set(accounts.map(\.id))) }
  }
  private var state = State(active: "100"), generation: UInt64 = 0
  private var legacy = [
    "100": ["DedeUserID": "100", "SESSDATA": "fixture-session-100", "bili_jct": "fixture-csrf-100", "buvid3": "fixture-web-device-100"],
    "200": ["DedeUserID": "200", "SESSDATA": "fixture-session-200", "bili_jct": "fixture-csrf-200", "buvid3": "fixture-web-device-200"],
    "guest": ["buvid3": "fixture-guest-fallback"],
  ]
  private var stored: [String: [WebCookieValue]] = [:]
  private var tokens = ["100": "fixture-token-100", "200": "fixture-token-200"]
  private var devices = ["100": "fixture-mobile-device-100", "200": "fixture-mobile-device-200", "guest": "fixture-mobile-guest"]
  private(set) var merges: [String: Int] = [:]
  func presentedState() throws -> State { state }
  func packStamp() throws -> (generation: UInt64, active: String?, ids: Set<String>) { (generation, state.active, Set(state.accounts.map(\.id))) }
  func webSession(_ use: AccountUse) async throws -> WebSessionSnapshot { try webSnapshot(owner: state.owner(use)) }
  func webSnapshot(owner: String?) throws -> WebSessionSnapshot {
    let key = owner ?? "guest"
    guard let cookies = legacy[key], let device = devices[key] else { throw CancellationError() }
    return .init(owner: owner, legacyCookies: cookies, storedCookies: stored[key] ?? [], token: owner.flatMap { tokens[$0] },
      device: device, active: state.active, routes: state.effectiveRoutes)
  }
  func mergeResponseCookies(_ cookies: [HTTPCookie], from url: URL, bound: WebSessionSnapshot, use: AccountUse? = nil) async throws -> WebSessionSnapshot? {
    try Task.checkCancellation()
    let live = try webSnapshot(owner: bound.owner)
    guard bound.sameIdentity(as: live) else { return nil }
    let update = try WebCookieJar.update(legacy: live.legacyCookies, stored: live.storedCookies, cookies: cookies, from: url, owner: bound.owner)
    let key = bound.owner ?? "guest"
    legacy[key] = update.legacy; stored[key] = update.stored; generation &+= 1
    merges[key, default: 0] += 1
    return try webSnapshot(owner: bound.owner)
  }
  func activate(_ owner: String?) { state.active = owner; generation &+= 1 }
  func select(_ owner: String?) throws { activate(owner) }
  func forget(_ owner: String) throws { state.accounts.removeAll { $0.id == owner }; if state.active == owner { state.active = nil }; generation &+= 1 }
  func recommend(_ owner: String) { state.effectiveRoutes.set(.recommend, choice: owner); generation &+= 1 }
  func token(_ value: String, owner: String = "100") { tokens[owner] = value; generation &+= 1 }
  func auxiliary(_ value: String) { legacy["100"]!["bili_ticket"] = value; generation &+= 1 }
}
actor ServiceWire {
  struct Call { let path: String, owner: String?, cookie: String? }
  private(set) var calls: [Call] = []
  private var block: String?, continuation: CheckedContinuation<Void, Never>?
  private var waiting = false
  private var rejectGuest = false
  private var rotate = false
  func pause(_ key: String) { block = key; waiting = false }
  func failingGuest(_ value: Bool) { rejectGuest = value }
  func rotating() { rotate = true }
  func untilWaiting() async { while !waiting { await Task.yield() } }
  func resume() { continuation?.resume(); continuation = nil }
  func send(_ request: URLRequest) async throws -> DeviceActivation.Response {
    let path = request.url!.path, owner = request.value(forHTTPHeaderField: "x-bili-mid")
    let key = path == DeviceActivation.path ? owner! : "guest"
    calls.append(.init(path: path, owner: owner, cookie: request.value(forHTTPHeaderField: "Cookie")))
    if key == "guest" {
      precondition(request.httpMethod == "GET" && owner == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
      precondition(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "buvid") == nil)
    } else {
      precondition(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "buvid") == "fixture-mobile-device-" + key)
      precondition(request.value(forHTTPHeaderField: "Cookie")?.contains("DedeUserID=" + key) == true)
      precondition(request.value(forHTTPHeaderField: "Cookie")?.contains("fixture-session-" + (key == "100" ? "200" : "100")) == false)
    }
    if block == key {
      block = nil
      await withCheckedContinuation { continuation = $0; waiting = true }
    }
    // Deliberately ignore cancellation here: production state/Jar guards must reject late replies.
    if key == "guest" {
      return .init(data: Data((rejectGuest ? #"{"code":-412}"# : #"{"code":0,"data":{"b_3":"fixture-server-guest-3","b_4":"fixture-server-guest-4"}}"#).utf8), status: 200, cookies: [], url: request.url)
    }
    let cookies: [HTTPCookie] = rotate && key == "100" ? [HTTPCookie(properties: [.name: "SESSDATA", .value: "fixture-rotated-session-100", .domain: ".bilibili.com", .path: "/", .secure: "TRUE"])!] : []
    return .init(data: Data(#"{"code":0}"#.utf8), status: 200, cookies: cookies, url: request.url)
  }
  func count(_ owner: String) -> Int { calls.filter { owner == "guest" ? $0.path == DeviceActivation.fingerURL.path : $0.owner == owner }.count }
}
@main enum ServiceCheck {
  static func service(_ jar: AccountJar, _ wire: ServiceWire) -> DeviceActivationService {
    .init(jar: jar, send: { try await wire.send($0) }, payload: {
      .init(platform: "iOS 27.1; iPhone Fixture", entropy: Data(0..<36))
    })
  }
  static func main() async throws {
    let seed = DeviceActivation.Response(data: Data(#"{"code":0,"data":{"b_3":"fixture-b3","b_4":"fixture-b4"}}"#.utf8), status: 200, cookies: [])
    let seedCookies = try DeviceActivation.fingerCookies(seed, now: Date(timeIntervalSince1970: 1_700_000_000))
    precondition(Dictionary(uniqueKeysWithValues: seedCookies.map { ($0.name, $0.value) }) == ["buvid3": "fixture-b3", "buvid4": "fixture-b4", "b_nut": "1700000000"])
    // Distinct role accounts get exactly one named activation each; the anonymous SPI has no account headers.
    let jar = AccountJar(), wire = ServiceWire(), app = service(jar, wire)
    await jar.recommend("200")
    await app.refresh(); await app.refresh()
    let counts = [await wire.count("100"), await wire.count("200"), await wire.count("guest")]
    precondition(counts == [1, 1, 1])
    let guest = try await jar.webSnapshot(owner: nil), first = try await jar.webSnapshot(owner: "100")
    precondition(guest.cookies["buvid3"] == "fixture-server-guest-3" && guest.cookies["SESSDATA"] == nil)
    precondition(first.cookies["buvid3"] == "fixture-web-device-100")
    let issues = await app.issues; precondition(issues.isEmpty)
    // Fingerprints bind the cookies sent to this URI, including a narrower-path device cookie.
    let scoped = WebCookieValue(name: "buvid3", value: "fixture-scoped-device", domain: "api.bilibili.com", path: "/x/internal", hostOnly: true, secure: true, expires: nil)
    let scopedWeb = WebSessionSnapshot(owner: first.owner, legacyCookies: first.legacyCookies, storedCookies: [scoped], token: first.token, device: first.device, active: first.active, routes: first.routes)
    let baseContext = try DeviceActivationContext(web: first, generation: 1)
    let scopedContext = try DeviceActivationContext(web: scopedWeb, generation: 1)
    precondition(!baseContext.snapshot.matches(scopedContext.snapshot) && scopedContext.snapshot.cookie.contains("buvid3=fixture-scoped-device"))
    let ticket = WebCookieValue(name: "bili_ticket", value: "fixture-scoped-ticket", domain: "api.bilibili.com", path: "/x/internal", hostOnly: true, secure: true, expires: nil)
    let ticketWeb = WebSessionSnapshot(owner: first.owner, legacyCookies: first.legacyCookies, storedCookies: [ticket], token: first.token, device: first.device, active: first.active, routes: first.routes)
    let ticketContext = try DeviceActivationContext(web: ticketWeb, generation: 99)
    precondition(baseContext.snapshot.matches(ticketContext.snapshot))
    // Failed guest initialization keeps its local fallback and does not block an authenticated account.
    let retryJar = AccountJar(), retryWire = ServiceWire(), retry = service(retryJar, retryWire)
    await retryWire.failingGuest(true); await retry.refresh()
    let fallback = try await retryJar.webSnapshot(owner: nil), failedIssues = await retry.issues
    let unaffected = await retryWire.count("100")
    precondition(fallback.cookies["buvid3"] == "fixture-guest-fallback" && failedIssues["guest"] != nil && unaffected == 1)
    await retryWire.failingGuest(false); await retry.refresh()
    let recovered = try await retryJar.webSnapshot(owner: nil), recoveredIssues = await retry.issues
    let retryCalls = await retryWire.count("guest")
    precondition(recovered.cookies["buvid3"] == "fixture-server-guest-3" && recoveredIssues.isEmpty && retryCalls == 2)
    // A legitimate Set-Cookie rotation must complete the new credential binding, not repeatedly activate.
    let rotateJar = AccountJar(), rotateWire = ServiceWire(), rotating = service(rotateJar, rotateWire)
    await rotateWire.rotating(); await rotating.refresh(); await rotating.refresh()
    let rotated = try await rotateJar.webSnapshot(owner: "100"), rotateCalls = await rotateWire.count("100")
    precondition(rotated.cookies["SESSDATA"] == "fixture-rotated-session-100" && rotateCalls == 1)
    // Auxiliary cookie updates advance generation without invalidating the captured account/device.
    let auxJar = AccountJar(), auxWire = ServiceWire(), aux = service(auxJar, auxWire)
    await auxWire.pause("100")
    let auxTask = Task { await aux.refresh() }; await auxWire.untilWaiting()
    await auxJar.auxiliary("fixture-new-ticket"); await auxWire.resume(); await auxTask.value; await aux.refresh()
    let auxCalls = await auxWire.count("100"), auxState = try await auxJar.webSnapshot(owner: "100")
    precondition(auxCalls == 1 && auxState.cookies["bili_ticket"] == "fixture-new-ticket")
    // The same UID with a replacement token must be initialized again; a late old response cannot complete it.
    let tokenJar = AccountJar(), tokenWire = ServiceWire(), tokenService = service(tokenJar, tokenWire)
    await tokenWire.pause("100")
    let tokenTask = Task { await tokenService.refresh() }; await tokenWire.untilWaiting()
    await tokenJar.token("fixture-replacement-token"); await tokenWire.resume(); await tokenTask.value
    let preTokenMerges = await tokenJar.merges["100", default: 0]; precondition(preTokenMerges == 0)
    await tokenService.refresh(); let tokenCalls = await tokenWire.count("100"); precondition(tokenCalls == 2)
    // Removing an in-flight role owner cancels it. Re-selecting later must still send its real activation.
    let switchJar = AccountJar(), switchWire = ServiceWire(), switching = service(switchJar, switchWire)
    await switchWire.pause("100")
    let old = Task { await switching.refresh() }; await switchWire.untilWaiting()
    await switchJar.activate("200"); await switching.refresh(); await switchWire.resume(); await old.value
    let switchedMerges = await switchJar.merges["100", default: 0]; precondition(switchedMerges == 0)
    await switchJar.activate("100"); await switching.refresh()
    let switchCounts = [await switchWire.count("100"), await switchWire.count("200")]
    precondition(switchCounts == [2, 1])
    // Guest SPI replies captured under an old main/route configuration cannot overwrite the guest jar.
    let guestJar = AccountJar(), guestWire = ServiceWire(), guestService = service(guestJar, guestWire)
    await guestWire.pause("guest")
    let oldGuest = Task { await guestService.refresh() }; await guestWire.untilWaiting()
    await guestJar.activate("200"); await guestWire.resume(); await oldGuest.value
    let staleGuest = try await guestJar.webSnapshot(owner: nil)
    precondition(staleGuest.cookies["buvid3"] == "fixture-guest-fallback")
    await guestService.refresh()
    let newGuest = try await guestJar.webSnapshot(owner: nil), guestCalls = await guestWire.count("guest")
    precondition(newGuest.cookies["buvid3"] == "fixture-server-guest-3" && guestCalls == 2)
    print("Production activation context/service with synthetic Jar and transport leaves: PASS")
  }
}
'''
with tempfile.TemporaryDirectory(prefix="pili-activation-service-") as temporary:
    temporary = Path(temporary)
    driver = temporary / "ActivationServiceCheck.swift"
    driver.write_text(integration)
    binary = temporary / "service"
    subprocess.run(["swiftc", str(src / "Network/ServiceError.swift"),
        str(src / "Account/MobileDeviceID.swift"), str(src / "Account/AccountRole.swift"),
        str(src / "Account/AccountServices.swift"), str(src / "Account/WebSessionCookies.swift"), str(src / "Network/ResponseCookieOrigin.swift"),
        str(src / "Network/DeviceActivation.swift"), str(src / "Account/DeviceActivationContext.swift"),
        str(driver), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)

context_source = (src / "Account/Accounts.swift").read_text()
context_source = "@MainActor final class AccountContext" + context_source.split("@MainActor final class AccountContext", 1)[1]
# Delay the network activation and record which identity the profile UI receives from the shipping refresh.
context_source = context_source.replace("DeviceActivationService.shared.refresh()", "ContextActivation.shared.refresh()")
context_driver = integration.split("@main enum ServiceCheck", 1)[0] + r'''
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value; init(wrappedValue: Value) { self.wrappedValue = wrappedValue } }
@MainActor final class ProfileStore {
  static let shared = ProfileStore()
  private(set) var scopes = [String?]()
  func activate(_ state: AccountJar.State) { scopes.append(state.active) }
}
@MainActor final class AccountBulletRules {
  static let shared = AccountBulletRules()
  func changedAccount() {}
  func forget(_ id: String) {}
}
actor Downloads { static let shared = Downloads(); func suspendOtherOwners(_ owner: String) {} }
actor ContextActivation {
  static let shared = ContextActivation()
  private var started = 0, pending: [Int: CheckedContinuation<Void, Never>] = [:]
  func refresh() async { started += 1; let id = started; await withCheckedContinuation { pending[id] = $0 } }
  func until(_ count: Int) async { while started < count { await Task.yield() } }
  func release(_ id: Int) { pending.removeValue(forKey: id)?.resume() }
}
''' + context_source + r'''
@main enum ContextCheck {
  @MainActor static func main() async throws {
    let context = AccountContext()
    let first = Task { await context.refresh() }
    await ContextActivation.shared.until(1)
    await first.value
    precondition(context.state.active == "100" && ProfileStore.shared.scopes == ["100"])
    // Account changes are local and immediate, even if older network activations finish later.
    await AccountJar.shared.activate(nil)
    let old = Task { await context.refresh() }; await ContextActivation.shared.until(2)
    await AccountJar.shared.activate("200")
    let current = Task { await context.refresh() }; await ContextActivation.shared.until(3)
    await old.value; await current.value
    precondition(context.state.active == "200" && ProfileStore.shared.scopes == ["100",nil,"200"])
    await ContextActivation.shared.release(3); await ContextActivation.shared.release(2)
    await ContextActivation.shared.release(1)
    // A refresh cancelled before it can publish must leave the visible profile untouched.
    await AccountJar.shared.activate("100")
    let cancelled = Task { @MainActor in await context.refresh() }
    cancelled.cancel(); await cancelled.value
    precondition(context.state.active == "200" && ProfileStore.shared.scopes == ["100",nil,"200"])
    print("Shipping AccountContext: immediate local profile, overlapping activations, cancellation before publication: PASS")
  }
}
'''
with tempfile.TemporaryDirectory(prefix="pili-activation-context-") as temporary:
    temporary = Path(temporary)
    driver = temporary / "ContextCheck.swift"
    driver.write_text(context_driver)
    binary = temporary / "context"
    subprocess.run(["swiftc", str(src / "Network/ServiceError.swift"),
        str(src / "Account/MobileDeviceID.swift"), str(src / "Account/AccountRole.swift"),
        str(src / "Account/AccountServices.swift"), str(src / "Account/WebSessionCookies.swift"), str(src / "Network/ResponseCookieOrigin.swift"),
        str(src / "Network/DeviceActivation.swift"), str(src / "Account/DeviceActivationContext.swift"),
        str(driver), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
