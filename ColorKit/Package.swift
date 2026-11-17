// swift-tools-version: 5.10
import PackageDescription

let package = Package(name: "ColorKit", products: [
  .library(name: "MaterialColorUtilities", targets: ["MaterialColorUtilities"]),
], targets: [.target(name: "MaterialColorUtilities")])
