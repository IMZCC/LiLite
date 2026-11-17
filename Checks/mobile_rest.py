"""Exercise the shipping app REST signer and session binding with synthetic account/network leaves."""
import ast
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import parse_qsl, quote, urlsplit

native = Path(__file__).resolve().parents[1]
src = native / "Sources/PiliNative"
# Reuse only the existing host CryptoKit leaf adapter; importing the passport script would execute it.
tree = ast.parse((native / "Checks/mobile_passport.py").read_text())
leaf = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "fixture" for target in node.targets))
leaf = leaf.split("enum MobileRSA {", 1)[0]
fixture = r'''
import Foundation
import FoundationNetworking

enum AccountCredentials { case mobile }
struct Identity { let id: String, mobileToken: String?, archiveDevice: String? }
enum MobileDeviceID {
  static func valid(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 } }
  static func use(_ value: String?) -> String { value ?? "fixture-guest-device" }
}
actor AccountJar {
  static let shared = AccountJar()
  struct State {
    var accounts: [Identity], active: String?, effectiveRoutes: AccountRoutes
    func owner(_ use: AccountUse) -> String? { effectiveRoutes.owner(use, main: active, available: Set(accounts.map(\.id))) }
  }
  private var state = State(accounts: [], active: nil, effectiveRoutes: .init())
  func configure(_ state: State) { self.state = state }
  func presentedState() throws -> State { state }
  func current(_ use: AccountUse, credentials: AccountCredentials) async throws -> Identity? {
    state.accounts.first { $0.id == state.owner(use) }
  }
}
actor Sent {
  var count = 0
  func send(_ request: URLRequest) -> (Data, URLResponse) {
    count += 1
    precondition(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
    return (Data("fixture".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
  }
}
@main enum RESTCheck {
  static func rejected(_ operation: () async throws -> Void) async throws {
    do { try await operation() } catch is ServiceError { return }
    preconditionFailure("changed app account was accepted")
  }
  static func main() async throws {
    let first = Identity(id: "100", mobileToken: "fixture-token-100", archiveDevice: "fixture-device-100")
    let second = Identity(id: "200", mobileToken: "fixture-token-200", archiveDevice: "fixture-device-200")
    var routes = AccountRoutes(); routes.set(.recommend, choice: "100")
    var state = AccountJar.State(accounts: [first, second], active: "200", effectiveRoutes: routes)
    await AccountJar.shared.configure(state)
    let bound = try await AccountJar.shared.mobileRESTSession(.role(.recommend))
    precondition(bound.owner == "100" && bound.token == first.mobileToken && bound.device == first.archiveDevice)
    let paths = ["/x/v2/feed/index", "/x/v2/space/comic", "/x/v2/space/article", "/x/v2/space/likearc",
      "/x/v2/search/recommend", "/x/topic/web/details/top", "/x/topic/pub/search"]
    var records = [[String: String]]()
    var request: URLRequest!
    for path in paths {
      var fields = path == paths[0] ? MobileFeed.fields(page: 2) : ["keyword": "中文 +/!~*'()", "vmid": "123"]
      fields["access_key"] = "wrong-token"; fields["sign"] = "stale-sign"
      let result = try MobileREST.request(path: path, fields: fields, session: bound, timestamp: 1_700_000_000)
      records.append(["url": result.url!.absoluteString, "device": result.value(forHTTPHeaderField: "buvid")!, "owner": result.value(forHTTPHeaderField: "x-bili-mid")!])
      precondition(result.value(forHTTPHeaderField: "User-Agent") == MobileClientSigning.userAgent && !result.httpShouldHandleCookies)
      request = result
    }
    let sent = Sent()
    _ = try await MobileREST.transfer(request, session: bound, current: { try await AccountJar.shared.mobileRESTSession(.role(.recommend)) }, via: { await sent.send($0) })
    let initialCount = await sent.count; precondition(initialCount == 1)
    for changed in [
      MobileREST.Session(owner: "200", token: bound.token, device: bound.device, routing: bound.routing),
      MobileREST.Session(owner: bound.owner, token: "rotated-token", device: bound.device, routing: bound.routing),
      MobileREST.Session(owner: bound.owner, token: bound.token, device: "new-device", routing: bound.routing),
      MobileREST.Session(owner: bound.owner, token: bound.token, device: bound.device, routing: "2:$main")
    ] {
      try await rejected { _ = try await MobileREST.transfer(request, session: bound, current: { changed }, via: { await sent.send($0) }) }
    }
    let rejectedCount = await sent.count; precondition(rejectedCount == 1)
    // A role edit resolving to the same UID must still invalidate a bound request.
    routes.set(.recommend, choice: AccountRoutes.follow); state.active = "100"; state.effectiveRoutes = routes
    await AccountJar.shared.configure(state)
    try await rejected { _ = try await MobileREST.transfer(request, session: bound, current: { try await AccountJar.shared.mobileRESTSession(.role(.recommend)) }, via: { await sent.send($0) }) }
    // A token replaced while the response is in flight cannot yield data under the old binding.
    state.effectiveRoutes.set(.recommend, choice: "100"); await AccountJar.shared.configure(state)
    var rotated = state
    rotated.accounts[0] = Identity(id: "100", mobileToken: "replacement-token", archiveDevice: first.archiveDevice)
    try await rejected {
      _ = try await MobileREST.transfer(request, session: bound, current: { try await AccountJar.shared.mobileRESTSession(.role(.recommend)) }, via: {
        let response = await sent.send($0); await AccountJar.shared.configure(rotated); return response
      })
    }
    let returnedCount = await sent.count; precondition(returnedCount == 2)
    state.accounts[0] = Identity(id: "100", mobileToken: nil, archiveDevice: first.archiveDevice)
    await AccountJar.shared.configure(state)
    let cookieOnly = try await AccountJar.shared.mobileRESTSession(.role(.recommend))
    let anonymous = try MobileREST.request(path: paths[0], fields: MobileFeed.fields(page: 1), session: cookieOnly, timestamp: 1_700_000_000)
    records.append(["url": anonymous.url!.absoluteString, "device": cookieOnly.device, "owner": cookieOnly.owner ?? ""])
    var contaminated = anonymous
    contaminated.setValue("fixture=not-for-app", forHTTPHeaderField: "Cookie")
    contaminated.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
    let clean = try MobileREST.decorated(contaminated, session: cookieOnly)
    precondition(clean.value(forHTTPHeaderField: "Cookie") == nil && clean.value(forHTTPHeaderField: "Authorization") == nil)
    routes.set(.recommend, choice: AccountRoutes.guest); state.effectiveRoutes = routes; await AccountJar.shared.configure(state)
    let guest = try await AccountJar.shared.mobileRESTSession(.role(.recommend))
    precondition(guest.owner == nil && guest.token == nil && guest.device == "fixture-guest-device")
    records.append(["url": try MobileREST.request(path: paths[0], fields: MobileFeed.fields(page: 1), session: guest, timestamp: 1_700_000_000).url!.absoluteString, "device": guest.device, "owner": ""])
    try JSONSerialization.data(withJSONObject: records).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("App REST: real signer and token/device/role binding, same-UID role edit, stale-token response rejection, cookie-only and guest branches passed")
  }
}
'''

with tempfile.TemporaryDirectory(prefix="pili-mobile-rest-") as temp:
    work = Path(temp)
    feed = (src / "Library/MobileFeed.swift").read_text()
    feed = "import Foundation\nstruct MobileFeed {\n" + feed[feed.index("  static func fields(page: Int)"):]
    session = (src / "Network/MobileRESTSession.swift").read_text().split("extension BiliAPI {", 1)[0]
    signing = (src / "Account/MobileClientSigning.swift").read_text().replace("import CryptoKit", "")
    files = []
    for name, text in (("leaf.swift", leaf), ("fixture.swift", fixture), ("feed.swift", feed), ("session.swift", session), ("signing.swift", signing)):
        path = work / name; path.write_text(text); files.append(str(path))
    files += [str(src / name) for name in ("Network/ServiceError.swift", "Network/MobileREST.swift", "Account/AccountRole.swift", "Account/AccountServices.swift")]
    subprocess.run(["swiftc", *files, "-o", str(work / "check")], check=True)
    subprocess.run([str(work / "check"), str(work / "requests.json")], check=True)
    for index, row in enumerate(json.loads((work / "requests.json").read_text())):
        parts = urlsplit(row["url"])
        fields = dict(parse_qsl(parts.query, keep_blank_values=True))
        signature = fields.pop("sign")
        canonical = "&".join(quote(key, safe="-_.!~*'()") + "=" + quote(value, safe="-_.!~*'()") for key, value in sorted(fields.items()))
        expected = hashlib.md5((canonical + "b5475a8825547a4fc26c7d518eaaa02e").encode()).hexdigest()
        assert signature == expected and fields["appkey"] == "dfca71928277209b"
        assert fields.get("access_key") == ("fixture-token-100" if index < 7 else None)
        if parts.path == "/x/v2/feed/index":
            assert fields["mobi_app"] == "android_i" and fields["build"] == "8430300" and fields["platform"] == "android"
            assert json.loads(fields["statistics"])["version"] == "8.43.0"
        else:
            assert fields["keyword"] == "中文 +/!~*'()" and fields["vmid"] == "123"
    print("Independent Python oracle: all app requests match fixed AppSign, original mobile feed persona and optional bound access_key")
