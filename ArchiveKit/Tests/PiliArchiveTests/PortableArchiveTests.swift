import Foundation
import XCTest

@testable import PiliArchive

final class PortableArchiveTests: XCTestCase {
  func testReadIndependentFlutterLayout() throws {
    let file = try XCTUnwrap(
      Bundle.module.url(forResource: "upstream-layout", withExtension: "zip"))
    let parsed = try PortableArchive(read: Data(contentsOf: file))
    XCTAssertEqual(parsed.platform, "pad")
    XCTAssertEqual(parsed.version, 65536)
    XCTAssertEqual(Set(parsed.parts.keys), ["setting.json", "blacklist.json", "search.json"])
    XCTAssertEqual(
      try JSONDecoder().decode([String].self, from: XCTUnwrap(parsed.parts["search.json"])),
      ["原生应用", "Swift"])
    XCTAssertEqual(
      try JSONDecoder().decode([Int].self, from: XCTUnwrap(parsed.parts["blacklist.json"])), [42])
  }
  func testRoundTripEmptyAndNonemptyMembers() throws {
    let items = [
      "search.json": Data("[]".utf8), "customFont.otf": Data([0, 1, 2]),
      "account.json": Data("{}".utf8),
    ]
    let d = try PortableArchive.make(items, platform: "phone", versionName: "test")
    XCTAssertEqual(try PortableArchive(read: d).parts, items)
    XCTAssertThrowsError(
      try PortableArchive.make(["wrong.json": Data()], platform: "phone", versionName: ""))
  }
  func testRejectIncompleteManifest() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "missing-section", withExtension: "zip"))
    XCTAssertThrowsError(try PortableArchive(read: Data(contentsOf: url)))
  }
}
