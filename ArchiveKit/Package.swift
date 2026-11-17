// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "PiliArchive", platforms: [.iOS(.v17), .macOS(.v13)],
  products: [.library(name: "PiliArchive", targets: ["PiliArchive"])],
  dependencies: [
    .package(
      url: "https://github.com/weichsel/ZIPFoundation.git",
      revision: "22787ffb59de99e5dc1fbfe80b19c97a904ad48d")
  ],
  targets: [
    .target(
      name: "PiliArchive", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")]
    ),
    .testTarget(
      name: "PiliArchiveTests", dependencies: ["PiliArchive"], resources: [.process("Fixtures")]),
  ]
)
