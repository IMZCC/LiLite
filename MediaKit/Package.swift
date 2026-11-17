// swift-tools-version: 5.10

import Foundation

import PackageDescription

let vendor = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
  "Vendor")
let package = Package(
  name: "PiliMedia", platforms: [.iOS(.v17)],
  products: [
    .library(name: "CLiveRemux", targets: ["CLiveRemux"]),
    .library(name: "CMPV", targets: ["CMPV"])
  ],
  targets: [
    .target(name: "CMPV", dependencies: ["CLiveRemux"], publicHeadersPath: "include",
      cSettings: [.unsafeFlags(["-I" + vendor.appendingPathComponent("include").path])],
      linkerSettings: [
        .unsafeFlags(["-L" + vendor.appendingPathComponent("lib").path]),
        .linkedLibrary("mpv"), .linkedLibrary("placebo"),
        .linkedFramework("OpenGLES"), .linkedFramework("QuartzCore"),
        .linkedFramework("AVFoundation"), .linkedFramework("Security"),
      ]),
    .target(
      name: "CLiveRemux", publicHeadersPath: "include",
      cSettings: [.unsafeFlags(["-I" + vendor.appendingPathComponent("include").path])],
      linkerSettings: [
        .unsafeFlags(["-L" + vendor.appendingPathComponent("lib").path]),
        .linkedLibrary("avformat"), .linkedLibrary("avfilter"), .linkedLibrary("avcodec"),
        .linkedLibrary("swscale"), .linkedLibrary("swresample"),
        .linkedLibrary("avutil"), .linkedLibrary("dav1d"),
        .linkedLibrary("ass"), .linkedLibrary("harfbuzz"),.linkedLibrary("fribidi"),.linkedLibrary("freetype"),
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
