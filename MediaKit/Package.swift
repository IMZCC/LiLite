// swift-tools-version: 5.10

import Foundation

import PackageDescription

// build.sh merges the static FFmpeg / dav1d / libass / HarfBuzz / FriBidi / FreeType / mpv /
// libplacebo builds into Vendor/PiliMediaVendor.xcframework (iphoneos + iphonesimulator slices),
// and stages their headers once in Vendor/include (both slices are arm64 builds of one recipe).
let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
  "Vendor")
let vendorHeaders: [CSetting] = [.unsafeFlags(["-I" + vendor.appendingPathComponent("include").path])]
let package = Package(
  name: "PiliMedia", platforms: [.iOS(.v17)],
  products: [
    .library(name: "CLiveRemux", targets: ["CLiveRemux"]),
    .library(name: "CMPV", targets: ["CMPV"])
  ],
  targets: [
    .binaryTarget(name: "PiliMediaVendor", path: "Vendor/PiliMediaVendor.xcframework"),
    .target(name: "CMPV", dependencies: ["CLiveRemux"], publicHeadersPath: "include",
      cSettings: vendorHeaders,
      linkerSettings: [
        .linkedFramework("OpenGLES"), .linkedFramework("QuartzCore"),
        .linkedFramework("AVFoundation"), .linkedFramework("Security"),
      ]),
    .target(
      name: "CLiveRemux", dependencies: ["PiliMediaVendor"], publicHeadersPath: "include",
      cSettings: vendorHeaders,
      linkerSettings: [
        .linkedLibrary("iconv",.when(platforms:[.iOS])),.linkedLibrary("c++",.when(platforms:[.iOS])),.linkedLibrary("z"),
        .linkedFramework("CoreText",.when(platforms:[.iOS])),
        .linkedFramework("MediaToolbox", .when(platforms: [.iOS])),
        .linkedFramework("AudioToolbox", .when(platforms: [.iOS])),
        .linkedFramework("VideoToolbox", .when(platforms: [.iOS])),
        .linkedFramework("CoreVideo", .when(platforms: [.iOS])),
        .linkedFramework("CoreMedia", .when(platforms: [.iOS])),
        .linkedFramework("CoreFoundation", .when(platforms: [.iOS])),
        .linkedLibrary("m"),
      ])
  ])
