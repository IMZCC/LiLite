import Foundation
import XCTest

@testable import PiliArchive

final class AccountArchiveTests: XCTestCase {
  private func fixture(_ mid: String = "42", roles: [Int] = [0, 1]) -> ArchiveAccount {
    ArchiveAccount(
      cookies: ["DedeUserID": mid, "SESSDATA": "sample-only", "bili_jct": "sample-only"],
      accessKey: "synthetic-access", refresh: "synthetic-refresh", buvid: nil, type: roles,
      label: "测试")
  }
  func testSyntheticAccountRoundTripAndRoleConflicts() throws {
    let two = ["42": fixture(), "84": fixture("84", roles: [2, 3])]
    let data = try JSONEncoder().encode(two)
    let parsed = try ArchiveAccount.decode(data)
    XCTAssertEqual(parsed["42"]?.refresh, "synthetic-refresh")
    XCTAssertEqual(parsed["84"]?.type, [2, 3])
    XCTAssertThrowsError(try ArchiveAccount.decode(JSONEncoder().encode(["84": fixture()])))
    XCTAssertThrowsError(
      try ArchiveAccount.decode(
        JSONEncoder().encode(["42": fixture(), "84": fixture("84", roles: [0])])))
  }
  func testPortableOwnershipAndRoleIntentCannotGrantDifferentUID() throws {
    let accounts = ["42": fixture(), "84": fixture("84", roles: [2])]
    let routes = ["0": "42", "1": "$main", "2": "84", "3": ""]
    try ArchiveAccount.validateRoles(routes, accounts: accounts)
    try ArchiveAccount.validateRoles(["0": "", "1": "$main", "2": "$main", "3": ""], accounts: [:])
    for k in ["0", "1", "2", "3"] {
      var forged = routes
      forged[k] = k == "2" ? "42" : "84"
      XCTAssertThrowsError(try ArchiveAccount.validateRoles(forged, accounts: accounts))
    }
    let d = try PortableArchive.make(
      ["account.json": JSONEncoder().encode(accounts), "reply.json": Data("[]".utf8)],
      platform: "phone", versionName: "fixture", versionCode: 20, replyOwner: "42", routes: routes)
    let parsed = try PortableArchive(read: d)
    XCTAssertEqual(parsed.replyOwner, "42")
    XCTAssertEqual(parsed.accountRoutes, routes)
    XCTAssertEqual(parsed.sourceBuild, 20)
    XCTAssertEqual(parsed.sourceApp, "PiliPlus")
  }
  #if os(Linux)
    func testExportReadableByStandardZipfile() throws {
      let data = try PortableArchive.make(
        ["search.json": Data("[\"测试\"]".utf8)], platform: "phone", versionName: "unit")
      let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try data.write(to: path)
      defer { try? FileManager.default.removeItem(at: path) }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [
        "-c",
        "import json,sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); assert z.testzip() is None and json.loads(z.read('search.json'))==['测试'] and json.loads(z.read('meta.json'))['formatVersion']==65536",
        path.path,
      ]
      try process.run()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0)
    }
  #endif
}
