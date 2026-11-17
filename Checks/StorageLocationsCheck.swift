import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

@main enum StorageLocationsCheck {
  static func rejects(_ f: () throws -> Void) {
    do {
      try f()
      preconditionFailure("unexpected success")
    } catch {}
  }
  static func digest(_ url: URL) throws -> String {
    try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }
  static func main() throws {
    let fm = FileManager.default
    let temp = fm.temporaryDirectory.appendingPathComponent(
      "pili-storage-fixture-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: temp) }
    let documents = temp.appendingPathComponent("chosen", isDirectory: true)
    try fm.createDirectory(at: documents, withIntermediateDirectories: false)
    let a = temp.appendingPathComponent("original")
    let b = temp.appendingPathComponent("audio")
    let payload = Data((0..<(2 * (1 << 20) + 53)).map { UInt8(truncatingIfNeeded: $0) })
    try payload.write(to: a)
    try Data("audio fixture".utf8).write(to: b)
    let picture = FolderExport.File(source: a, stem: "../sample", ext: "png")
    let visitor = documents.appendingPathComponent("sample.png")
    try Data("existing".utf8).write(to: visitor)
    try FolderExport.write([picture], into: documents, group: nil)
    let unchanged = try Data(contentsOf: visitor)
    let exported = try Data(contentsOf: documents.appendingPathComponent("sample (2).png"))
    precondition(unchanged == Data("existing".utf8) && exported == payload)
    let pair = [
      FolderExport.File(source: b, stem: "p", ext: "jpg"),
      FolderExport.File(source: a, stem: "p", ext: "mov"),
    ]
    try FolderExport.write(pair, into: documents, group: "实况")
    let names = try fm.contentsOfDirectory(atPath: documents.appendingPathComponent("实况").path)
    precondition(Set(names) == ["p.jpg", "p.mov"])
    rejects {
      try FolderExport.write(
        [picture, .init(source: temp.appendingPathComponent("absent"), stem: "b", ext: "gif")],
        into: documents, group: "incomplete")
    }
    precondition(!fm.fileExists(atPath: documents.appendingPathComponent("incomplete").path))
    let id = UUID()
    let tok = "BV1fK4y1t7hj-196018899:" + UUID().uuidString
    let root = try OfflinePackage.folder(documents, id: id, create: true)!
    let assets = ["video": a, "audio": b]
    let receipt = try OfflinePackage.describe(tok, files: assets, hash: digest)
    let pkg = try OfflinePackage.package(root, tok)
    rejects { _ = try OfflinePackage.package(root, "../\(tok)") }
    try OfflinePackage.publish(assets, receipt: receipt, root: root, hash: digest)
    try OfflinePackage.publish(assets, receipt: receipt, root: root, hash: digest)
    let v = try OfflinePackage.verified(
      pkg, token: tok, components: Array(assets.keys), hash: digest)
    precondition(v == receipt && fm.fileExists(atPath: a.path))
    let outsider = pkg.appendingPathComponent("user.txt")
    try Data([2]).write(to: outsider)
    rejects {
      try OfflinePackage.remove(pkg, token: tok, components: Array(assets.keys), hash: digest)
    }
    let known = try OfflinePackage.bytesOnDisk(
      root: root, token: tok, components: Array(assets.keys), canonical: true)
    precondition(known == receipt.parts.values.reduce(Int64(0)) { $0 + $1.bytes })
    precondition(fm.fileExists(atPath: outsider.path))
    try fm.removeItem(at: outsider)
    let au = pkg.appendingPathComponent("audio.m4a")
    let real = try Data(contentsOf: au)
    try Data(repeating: 0, count: real.count).write(to: au)
    rejects { try OfflinePackage.publish(assets, receipt: receipt, root: root, hash: digest) }
    rejects {
      try OfflinePackage.remove(pkg, token: tok, components: Array(assets.keys), hash: digest)
    }
    try real.write(to: au)
    let retire = root.appendingPathComponent(
      ".pili-removing-" + pkg.lastPathComponent, isDirectory: true)
    try fm.moveItem(at: pkg, to: retire)
    try fm.removeItem(at: retire.appendingPathComponent("audio.m4a"))
    try OfflinePackage.remove(pkg, token: tok, components: Array(assets.keys), hash: digest)
    precondition(!fm.fileExists(atPath: retire.path))
    let work = OfflinePackage.work(pkg)
    try fm.createDirectory(at: work, withIntermediateDirectories: false)
    try JSONEncoder().encode(receipt).write(to: work.appendingPathComponent("work.json"))
    try Data("partial".utf8).write(to: work.appendingPathComponent("video.mp4"))
    let staged = try OfflinePackage.bytesOnDisk(
      root: root, token: tok, components: Array(assets.keys), canonical: false)
    precondition(staged == 7)
    try OfflinePackage.publish(assets, receipt: receipt, root: root, hash: digest)
    precondition(!fm.fileExists(atPath: work.path) && fm.fileExists(atPath: pkg.path))
    try OfflinePackage.remove(pkg, token: tok, components: Array(assets.keys), hash: digest)
    let enc = temp.appendingPathComponent("bound.pilicache")
    let enc2 = temp.appendingPathComponent("bound2.pilicache")
    let clear = temp.appendingPathComponent("opened")
    let key = SymmetricKey(size: .bits256)
    let ctx = Data("owner|generation|video".utf8)
    try OfflineSealedTrack.seal(a, to: enc, key: key, context: ctx)
    try OfflineSealedTrack.seal(a, to: enc2, key: key, context: ctx)
    let hash = try OfflineSealedTrack.open(enc, to: clear, key: key, context: ctx)
    let decoded = try Data(contentsOf: clear)
    let left = try Data(contentsOf: enc)
    let right = try Data(contentsOf: enc2)
    let plainHash = try digest(a)
    precondition(
      hash == plainHash && decoded == payload && left != right
        && left.range(of: payload.prefix(128)) == nil)
    rejects {
      _ = try OfflineSealedTrack.open(enc, to: nil, key: key, context: Data("another owner".utf8))
    }
    rejects {
      _ = try OfflineSealedTrack.open(enc, to: nil, key: SymmetricKey(size: .bits256), context: ctx)
    }
    let damaged = temp.appendingPathComponent("damaged")
    var bytes = left
    bytes[bytes.count - 1] ^= 1
    try bytes.write(to: damaged)
    rejects { _ = try OfflineSealedTrack.open(damaged, to: nil, key: key, context: ctx) }
    try left.dropLast(33).write(to: damaged)
    rejects { _ = try OfflineSealedTrack.open(damaged, to: nil, key: key, context: ctx) }
    let block = (1 << 20) + 28
    let offset = 9 + 8 + 16
    let swapped =
      Data(left.prefix(offset)) + Data(left[(offset + block)..<(offset + 2 * block)])
      + Data(left[offset..<(offset + block)]) + Data(left.dropFirst(offset + 2 * block))
    try swapped.write(to: damaged)
    rejects { _ = try OfflineSealedTrack.open(damaged, to: nil, key: key, context: ctx) }
    // Restart between committing a new location and disposing the old one.
    let old = temp.appendingPathComponent("old-media"), authority = temp.appendingPathComponent("new-media")
    try Data("only good copy".utf8).write(to: old)
    try fm.copyItem(at: old, to: authority)
    let proof = try OfflinePackage.describe("BV1ab411c7dD-1:original", files:["movie":old], hash:digest).parts.mapValues(\.hash)
    func finishRetirement() throws {
      let current = try OfflinePackage.describe("BV1ab411c7dD-1:original", files:["movie":authority], hash:digest)
      try OfflinePackage.requireAuthority(current.parts.mapValues(\.hash), proof:proof, components:["movie"])
      try fm.removeItem(at:old)
    }
    try fm.removeItem(at:authority)
    rejects { try finishRetirement() }; precondition(fm.fileExists(atPath:old.path))
    try Data("bad replacement".utf8).write(to:authority)
    rejects { try finishRetirement() }; precondition(fm.fileExists(atPath:old.path))
    try Data(contentsOf:old).write(to:authority)
    try finishRetirement(); precondition(!fm.fileExists(atPath:old.path) && fm.fileExists(atPath:authority.path))
    let legacyToken = "BV1ab411c7dD-2~u42:" + UUID().uuidString
    let legacy0 = temp.appendingPathComponent("legacy0.sealed"), legacy1 = temp.appendingPathComponent("legacy1.sealed")
    let context0 = Data((legacyToken + "|part-0000").utf8), context1 = Data((legacyToken + "|part-0001").utf8)
    try OfflineSealedTrack.seal(a, to: legacy0, key: key, context: context0)
    try OfflineSealedTrack.seal(b, to: legacy1, key: key, context: context1)
    let parts = ["bound-part-0000": legacy0, "bound-part-0001": legacy1]
    let legacyReceipt = try OfflinePackage.describe(legacyToken, files: parts, hash: digest)
    try OfflinePackage.publish(parts, receipt: legacyReceipt, root: root, hash: digest)
    let legacyPackage = try OfflinePackage.package(root, legacyToken)
    let checked = try OfflinePackage.verified(legacyPackage, token: legacyToken, components: Array(parts.keys), hash: digest)
    precondition(checked == legacyReceipt)
    let sealed = legacyPackage.appendingPathComponent(try OfflinePackage.name("bound-part-0000"))
    let mediaHash = try OfflineSealedTrack.open(sealed, to: nil, key: key, context: context0)
    precondition(mediaHash == plainHash)
    rejects { _ = try OfflineSealedTrack.open(sealed, to: nil, key: key, context: context1) }
    rejects { _ = try OfflinePackage.name("bound-part-0256") }
    rejects { _ = try OfflinePackage.name("../part-0000") }
    try OfflinePackage.remove(legacyPackage, token: legacyToken, components: Array(parts.keys), hash: digest)
    print(
      "Storage: no-clobber exports, grouped pairs, transaction replay, foreign/changed files, interrupted copy/deletion, 3 authenticated chunks, wrong owner/key, tamper, truncation and reordering passed"
    )
  }
}
