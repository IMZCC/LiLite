// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "PiliWire", platforms: [.iOS(.v17), .macOS(.v13)],
  products: [.library(name: "PiliWire", targets: ["PiliWire"])],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-protobuf.git",
      revision: "c6fe6442e6a64250495669325044052e113e990c")
  ],
  targets: [
    .systemLibrary(name: "PiliWireZlib"),
    .systemLibrary(name: "CBrotli"),
    .target(
      name: "PiliWire",
      dependencies: [
        "PiliWireZlib", .target(name: "CBrotli", condition: .when(platforms: [.linux])),
        .product(name: "SwiftProtobuf", package: "swift-protobuf"),
      ]),
    .testTarget(name: "PiliWireTests", dependencies: ["PiliWire"]),
  ]
)
